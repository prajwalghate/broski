import Accelerate
import CoreML
import Foundation

/// Bark 3.0 on the Apple Neural Engine: the Core ML encoder (8 s and 15 s windows) and, on the CPU, the audio frontend
/// and greedy TDT decoding. A line-by-line port of the model's reference, coreml/ane/bark_coreml.py.
@available(macOS 15.0, iOS 18.0, *)
public final class BarkTranscriber: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case missingFile(String), badModel(String), encoder(String)
        public var description: String {
            switch self {
            case .missingFile(let name): return "Bark is missing \(name)"
            case .badModel(let why): return "Bark's model can't be used: \(why)"
            case .encoder(let why): return "Bark's encoder failed: \(why)"
            }
        }
    }

    static let sampleRate = 16_000
    static let hop = 160, nfft = 512, win = 400
    public static let allWindows = [8, 15]
    /// The windows this transcriber uses: longer pieces are cut at pauses to fit the largest.
    let windows: [Int]
    /// 0.25 s of silence before each piece: the setting the published accuracy was measured with.
    static let padSamples = 4_000

    private let frontend: Frontend
    private let decoder: Decoder
    private let encoders: [Int: MLModel]
    private let lock = NSLock()

    /// Loads the model from `directory` (the files in `BarkModel.files`). The encoder is compiled for this Mac the first
    /// time (a minute or two) and the compiled copy is kept in `cache`.
    public static func load(directory: URL, cache: URL? = nil, computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
                            windows: [Int] = allWindows) async throws -> BarkTranscriber {
        let fm = FileManager.default
        for name in ["decoder.npz", "vocab.json", BarkModel.package] where !fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            throw Failure.missingFile(name)
        }
        let compiled = (cache ?? directory).appendingPathComponent("BarkEncoder.mlmodelc", isDirectory: true)
        if !fm.fileExists(atPath: compiled.path) {
            let temporary = try await MLModel.compileModel(at: directory.appendingPathComponent(BarkModel.package))
            try? fm.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: compiled)
            try fm.moveItem(at: temporary, to: compiled)
        }
        var encoders: [Int: MLModel] = [:]
        let windows = allWindows.filter(windows.contains)
        for window in windows {
            let config = MLModelConfiguration()
            config.computeUnits = computeUnits
            config.functionName = "w\(window)"
            encoders[window] = try await MLModel.load(contentsOf: compiled, configuration: config)
        }
        let vocabData = try Data(contentsOf: directory.appendingPathComponent("vocab.json"))
        let decoder = try Decoder(npz: NPZ(url: directory.appendingPathComponent("decoder.npz")), vocab: vocabData)
        return BarkTranscriber(frontend: Frontend(mel: decoder.mel), decoder: decoder, encoders: encoders, windows: windows)
    }

    private init(frontend: Frontend, decoder: Decoder, encoders: [Int: MLModel], windows: [Int]) {
        self.frontend = frontend
        self.decoder = decoder
        self.encoders = encoders
        self.windows = windows
    }

    /// Text for 16 kHz mono audio. Pieces longer than a window are cut at pauses first.
    public func transcribe(samples: [Float]) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let maxSeconds = Double(windows.last!) - Double(Self.padSamples) / Double(Self.sampleRate)
        return try Self.segments(samples, maxSeconds: maxSeconds)
            .map { decoder.text(try piece($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The frontend's features for one piece (with its leading silence), for checking against the reference.
    public func features(for audio: [Float]) -> (values: [Float], frames: Int, valid: Int) {
        let (values, frames, valid) = frontend.features([Float](repeating: 0, count: Self.padSamples) + audio)
        return (values, frames, valid)
    }

    private func piece(_ audio: [Float]) throws -> [Int] {
        let x = [Float](repeating: 0, count: Self.padSamples) + audio
        let (feats, frames, valid) = frontend.features(x)
        guard let window = windows.first(where: { x.count <= $0 * Self.sampleRate }), let encoder = encoders[window] else {
            throw Failure.encoder("a piece of \(x.count) samples is longer than the largest window")
        }
        let T = window * 100 + 1
        let features = try MLMultiArray(shape: [1, NSNumber(value: T), 128], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: T)], dataType: .int32)
        // Zero both, then copy the frames that fit (the frontend's extra frames past T are dropped, as in the reference).
        let featurePointer = features.dataPointer.bindMemory(to: UInt16.self, capacity: T * 128)
        featurePointer.initialize(repeating: 0, count: T * 128)
        let used = min(frames, T)
        feats.withUnsafeBufferPointer { src in
            var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1, width: vImagePixelCount(used * 128), rowBytes: used * 128 * 4)
            var d = vImage_Buffer(data: UnsafeMutableRawPointer(featurePointer), height: 1, width: vImagePixelCount(used * 128), rowBytes: used * 128 * 2)
            _ = vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
        }
        let maskPointer = mask.dataPointer.bindMemory(to: Int32.self, capacity: T)
        for i in 0..<T { maskPointer[i] = i < valid ? 1 : 0 }
        let input = try MLDictionaryFeatureProvider(dictionary: ["features": MLFeatureValue(multiArray: features),
                                                                 "mask": MLFeatureValue(multiArray: mask)])
        guard let encoded = try encoder.prediction(from: input).featureValue(for: "encoded")?.multiArrayValue else {
            throw Failure.encoder("no 'encoded' output")
        }
        let length = min(Self.encodedLength(valid), encoded.shape[1].intValue)
        let enc = try Self.floats(encoded, rows: length, width: 640)
        guard enc.allSatisfy(\.isFinite) else { throw Failure.encoder("non-finite output") }
        return decoder.decode(enc, frames: length)
    }

    /// Three stride-2 convolutions (kernel 3, padding 1).
    static func encodedLength(_ n: Int) -> Int {
        var n = n
        for _ in 0..<3 { n = (n - 1) / 2 + 1 }
        return n
    }

    /// The first `rows` × `width` values of a [1, T', width] array as Float, honouring its strides and type.
    static func floats(_ array: MLMultiArray, rows: Int, width: Int) throws -> [Float] {
        let rowStride = array.strides[1].intValue, colStride = array.strides[2].intValue
        var out = [Float](repeating: 0, count: rows * width)
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for r in 0..<rows { for c in 0..<width { out[r * width + c] = p[r * rowStride + c * colStride] } }
        case .float16:
            let p = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
            var halves = [UInt16](repeating: 0, count: rows * width)
            for r in 0..<rows { for c in 0..<width { halves[r * width + c] = p[r * rowStride + c * colStride] } }
            halves.withUnsafeMutableBytes { src in
                out.withUnsafeMutableBytes { dst in
                    var s = vImage_Buffer(data: src.baseAddress, height: 1, width: vImagePixelCount(rows * width), rowBytes: rows * width * 2)
                    var d = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(rows * width), rowBytes: rows * width * 4)
                    _ = vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
                }
            }
        default:
            let n = rows * width
            for i in 0..<n { out[i] = array[[0, NSNumber(value: i / width), NSNumber(value: i % width)]].floatValue }
        }
        return out
    }

    /// Audio longer than `maxSeconds` is cut at pauses: within each [5 s, max] stretch, in the middle of the quietest
    /// 200 ms (smoothed 10 ms energy), so no word is split.
    static func segments(_ x: [Float], maxSeconds: Double, minSeconds: Double = 5) -> [[Float]] {
        let maxSamples = Int(maxSeconds * Double(sampleRate))
        guard x.count > maxSamples else { return [x] }
        let frame = sampleRate / 100
        let frames = x.count / frame
        var energy = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            vDSP_svesq(Array(x[(f * frame)..<((f + 1) * frame)]), 1, &sum, vDSP_Length(frame))
            energy[f] = sum / Float(frame)
        }
        // A centred 20-frame moving average, like numpy's convolve(mode="same").
        var smooth = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            let lo = max(0, f - 10), hi = min(frames, f + 10)
            smooth[f] = energy[lo..<hi].reduce(0, +) / 20
        }
        var out: [[Float]] = []
        var start = 0
        while x.count - start > maxSamples {
            let lo = (start + Int(minSeconds * Double(sampleRate))) / frame
            let hi = min(frames, (start + maxSamples) / frame)
            guard lo < hi else { break }
            var best = lo
            for f in lo..<hi where smooth[f] < smooth[best] { best = f }
            let cut = best * frame + frame / 2
            out.append(Array(x[start..<cut]))
            start = cut
        }
        out.append(Array(x[start...]))
        return out
    }
}

// MARK: Frontend

/// Preemphasis, centred STFT (Hann 400 in a 512 frame, hop 160), Slaney mel (128), log, per-utterance normalisation.
@available(macOS 15.0, iOS 18.0, *)
struct Frontend {
    let mel: [Float]          // [128 × 257], row-major
    let window: [Float]       // 512, the symmetric 400-point Hann centred
    private let dft: vDSP.DiscreteFourierTransform<Float>

    init(mel: [Float]) {
        self.mel = mel
        var w = [Float](repeating: 0, count: BarkTranscriber.nfft)
        let n = BarkTranscriber.win, offset = (BarkTranscriber.nfft - n) / 2
        for i in 0..<n { w[offset + i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))) }
        window = w
        dft = try! vDSP.DiscreteFourierTransform(count: BarkTranscriber.nfft, direction: .forward, transformType: .complexComplex, ofType: Float.self)
    }

    /// Features [frames × 128] row-major, the frame count, and how many frames hold audio.
    func features(_ x: [Float]) -> ([Float], Int, Int) {
        let L = x.count, nfft = BarkTranscriber.nfft, hop = BarkTranscriber.hop, bins = nfft / 2 + 1
        var emphasized = [Float](repeating: 0, count: L)
        if L > 0 { emphasized[0] = x[0] }
        for i in 1..<max(L, 1) where i < L { emphasized[i] = x[i] - 0.97 * x[i - 1] }
        var padded = [Float](repeating: 0, count: L + nfft)
        padded.replaceSubrange((nfft / 2)..<(nfft / 2 + L), with: emphasized)
        let frames = 1 + (padded.count - nfft) / hop
        var power = [Float](repeating: 0, count: frames * bins)
        var real = [Float](repeating: 0, count: nfft), imag = [Float](repeating: 0, count: nfft)
        var outReal = [Float](repeating: 0, count: nfft), outImag = [Float](repeating: 0, count: nfft)
        for f in 0..<frames {
            let start = f * hop
            vDSP.multiply(padded[start..<(start + nfft)], window, result: &real)
            vDSP.fill(&imag, with: 0)
            dft.transform(inputReal: real, inputImaginary: imag, outputReal: &outReal, outputImaginary: &outImag)
            for k in 0..<bins { power[f * bins + k] = outReal[k] * outReal[k] + outImag[k] * outImag[k] }
        }
        // power [frames × 257] · melᵀ [257 × 128]
        var feats = [Float](repeating: 0, count: frames * 128)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), 128, Int32(bins), 1, power, Int32(bins), mel, Int32(bins), 0, &feats, 128)
        let floor = Float(pow(2.0, -24.0))
        for i in 0..<feats.count { feats[i] = log(feats[i] + floor) }
        let valid = L / hop
        if valid > 0 {
            for m in 0..<128 {
                var mean: Float = 0
                for f in 0..<valid { mean += feats[f * 128 + m] }
                mean /= Float(valid)
                var sq: Float = 0
                for f in 0..<valid { let d = feats[f * 128 + m] - mean; sq += d * d }
                let std = (sq / Float(max(1, valid - 1))).squareRoot()
                for f in 0..<frames { feats[f * 128 + m] = f < valid ? (feats[f * 128 + m] - mean) / (std + 1e-5) : 0 }
            }
        }
        return (feats, frames, valid)
    }
}

// MARK: Decoder

/// Greedy TDT decoding: a 2-layer LSTM prediction network and the joint head (int8 weights × per-row scales).
@available(macOS 15.0, iOS 18.0, *)
final class Decoder {
    let mel: [Float]
    private let embedding: [Float]           // [vocab × H]
    private let lstm: [(wi: [Float], wh: [Float], b: [Float])]
    private let projW: [Float], projB: [Float]
    private let headW: [Float], headB: [Float]
    private let H: Int
    private let vocabSize: Int, blank: Int, durations: [Int], maxSymbols: Int
    private let pieces: [String], special: Set<Int>

    init(npz: NPZ, vocab: Data) throws {
        func weight(_ key: String) throws -> NPZ.Array {
            if let q = npz[key + ".q"], let s = npz[key + ".s"] {
                let cols = q.count / max(1, s.count)
                var values = q.values
                values.withUnsafeMutableBufferPointer { p in
                    for r in 0..<s.count {
                        var scale = s.values[r]
                        vDSP_vsmul(p.baseAddress! + r * cols, 1, &scale, p.baseAddress! + r * cols, 1, vDSP_Length(cols))
                    }
                }
                return NPZ.Array(shape: q.shape, values: values)
            }
            guard let plain = npz[key] else { throw BarkTranscriber.Failure.badModel("decoder.npz has no \(key)") }
            return plain
        }
        let emb = try weight("decoder.embedding.weight")
        embedding = emb.values
        H = emb.shape.last ?? 640
        lstm = try (0..<2).map { i in
            let bi = try weight("decoder.lstm.bias_ih_l\(i)").values, bh = try weight("decoder.lstm.bias_hh_l\(i)").values
            return (try weight("decoder.lstm.weight_ih_l\(i)").values, try weight("decoder.lstm.weight_hh_l\(i)").values, vDSP.add(bi, bh))
        }
        projW = try weight("decoder.decoder_projector.weight").values
        projB = try weight("decoder.decoder_projector.bias").values
        headW = try weight("joint.head.weight").values
        headB = try weight("joint.head.bias").values
        guard let melArray = npz["mel_filters"] else { throw BarkTranscriber.Failure.badModel("decoder.npz has no mel_filters") }
        mel = melArray.values
        guard let json = try JSONSerialization.jsonObject(with: vocab) as? [String: Any],
              let pieces = json["pieces"] as? [String], let vocabSize = json["vocab_size"] as? Int, let blank = json["blank_id"] as? Int,
              let durations = json["durations"] as? [Int], let maxSymbols = json["max_symbols_per_step"] as? Int else {
            throw BarkTranscriber.Failure.badModel("vocab.json is incomplete")
        }
        self.pieces = pieces
        self.vocabSize = vocabSize
        self.blank = blank
        self.durations = durations
        self.maxSymbols = maxSymbols
        special = Set((json["special_ids"] as? [Int]) ?? [])
        guard headB.count == vocabSize + durations.count, projB.count == H else { throw BarkTranscriber.Failure.badModel("unexpected shapes") }
    }

    /// y = W·x + b for a row-major [rows × cols] W.
    private func affine(_ w: [Float], _ x: [Float], _ b: [Float]) -> [Float] {
        var y = b
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(b.count), Int32(x.count), 1, w, Int32(x.count), x, 1, 1, &y, 1)
        return y
    }

    private func step(_ token: Int, _ state: [(h: [Float], c: [Float])]) -> ([Float], [(h: [Float], c: [Float])]) {
        var x = Array(embedding[(token * H)..<((token + 1) * H)])
        var next: [(h: [Float], c: [Float])] = []
        for (layer, (h, c)) in zip(lstm, state) {
            var g = affine(layer.wi, x, layer.b)
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(4 * H), Int32(H), 1, layer.wh, Int32(H), h, 1, 1, &g, 1)
            var newC = [Float](repeating: 0, count: H), newH = [Float](repeating: 0, count: H)
            for j in 0..<H {
                let i = 1 / (1 + exp(-g[j])), f = 1 / (1 + exp(-g[H + j]))
                let gg = tanh(g[2 * H + j]), o = 1 / (1 + exp(-g[3 * H + j]))
                newC[j] = f * c[j] + i * gg
                newH[j] = o * tanh(newC[j])
            }
            next.append((newH, newC))
            x = newH
        }
        return (affine(projW, x, projB), next)
    }

    func decode(_ enc: [Float], frames T: Int) -> [Int] {
        var state = [(h: [Float], c: [Float])](repeating: ([Float](repeating: 0, count: H), [Float](repeating: 0, count: H)), count: 2)
        var (dec, s) = step(blank, state)
        state = s
        var t = 0, symbols = 0
        var out: [Int] = []
        var hidden = [Float](repeating: 0, count: H)
        var logits = [Float](repeating: 0, count: headB.count)
        while t < T {
            for j in 0..<H { hidden[j] = max(enc[t * H + j] + dec[j], 0) }
            logits = headB
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(headB.count), Int32(H), 1, headW, Int32(H), hidden, 1, 1, &logits, 1)
            var token = 0
            for k in 1..<vocabSize where logits[k] > logits[token] { token = k }
            var best = vocabSize
            for k in (vocabSize + 1)..<logits.count where logits[k] > logits[best] { best = k }
            var duration = durations[best - vocabSize]
            if token == blank {
                t += max(duration, 1)
                symbols = 0
            } else {
                out.append(token)
                (dec, s) = step(token, state)
                state = s
                symbols += 1
                if duration == 0 && symbols >= maxSymbols { duration = 1 }
                if duration > 0 { symbols = 0 }
                t += duration
            }
        }
        return out
    }

    func text(_ ids: [Int]) -> String {
        ids.filter { !special.contains($0) && $0 < pieces.count }.map { pieces[$0] }.joined()
            .replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

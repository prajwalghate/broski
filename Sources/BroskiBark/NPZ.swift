import Accelerate
import Compression
import Foundation

/// Reads numpy's .npz (a zip of .npy arrays, deflated, written with zip64 headers) into Float arrays.
/// Only what Bark's decoder.npz needs: little-endian float16, float32 and int8, C order.
struct NPZ {
    struct Array {
        var shape: [Int]
        var values: [Float]
        var count: Int { values.count }
    }

    enum Failure: Error, CustomStringConvertible {
        case notZip, badEntry(String), unsupported(String)
        var description: String {
            switch self {
            case .notZip: return "decoder.npz isn't a zip file"
            case .badEntry(let name): return "decoder.npz: can't read \(name)"
            case .unsupported(let what): return "decoder.npz: unsupported \(what)"
            }
        }
    }

    private(set) var arrays: [String: Array] = [:]

    subscript(name: String) -> Array? { arrays[name] }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        for entry in try Self.entries(data) {
            let raw = try Self.inflate(data, entry)
            let name = entry.name.hasSuffix(".npy") ? String(entry.name.dropLast(4)) : entry.name
            arrays[name] = try Self.parseNPY(raw, name: name)
        }
    }

    // MARK: Zip

    private struct Entry { var name: String; var method: UInt16; var compressed: Int; var size: Int; var offset: Int }

    private static func u16(_ d: Data, _ i: Int) -> Int { Int(d[d.startIndex + i]) | Int(d[d.startIndex + i + 1]) << 8 }
    private static func u32(_ d: Data, _ i: Int) -> Int { u16(d, i) | u16(d, i + 2) << 16 }
    private static func u64(_ d: Data, _ i: Int) -> Int { u32(d, i) | u32(d, i + 4) << 32 }

    private static func entries(_ d: Data) throws -> [Entry] {
        // End of central directory: the last "PK\5\6" within the final 64 KB.
        var eocd = -1
        var i = d.count - 22
        while i >= max(0, d.count - 65_558) {
            if u32(d, i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.notZip }
        var count = u16(d, eocd + 10)
        var directory = u32(d, eocd + 16)
        // Zip64: the real values are in the zip64 end record, found through its locator just before.
        if (count == 0xFFFF || directory == 0xFFFF_FFFF), eocd >= 20, u32(d, eocd - 20) == 0x0706_4b50 {
            let record = u64(d, eocd - 12)
            guard u32(d, record) == 0x0606_4b50 else { throw Failure.notZip }
            count = u64(d, record + 32)
            directory = u64(d, record + 48)
        }
        var out: [Entry] = []
        var p = directory
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x0201_4b50 else { throw Failure.notZip }
            let method = UInt16(u16(d, p + 10))
            var compressed = u32(d, p + 20), size = u32(d, p + 24)
            let nameLength = u16(d, p + 28), extraLength = u16(d, p + 30), commentLength = u16(d, p + 32)
            var offset = u32(d, p + 42)
            let name = String(decoding: d[(d.startIndex + p + 46)..<(d.startIndex + p + 46 + nameLength)], as: UTF8.self)
            // Zip64 extra field: the 64-bit values, in order, for each field that is 0xFFFFFFFF above.
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = u16(d, e), length = u16(d, e + 2)
                if id == 0x0001 {
                    var q = e + 4
                    if size == 0xFFFF_FFFF { size = u64(d, q); q += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = u64(d, q); q += 8 }
                    if offset == 0xFFFF_FFFF { offset = u64(d, q) }
                }
                e += 4 + length
            }
            out.append(Entry(name: name, method: method, compressed: compressed, size: size, offset: offset))
            p = extraEnd + commentLength
        }
        return out
    }

    private static func inflate(_ d: Data, _ entry: Entry) throws -> Data {
        let p = entry.offset
        guard p + 30 <= d.count, u32(d, p) == 0x0403_4b50 else { throw Failure.badEntry(entry.name) }
        let start = p + 30 + u16(d, p + 26) + u16(d, p + 28)
        guard start + entry.compressed <= d.count else { throw Failure.badEntry(entry.name) }
        let source = d[(d.startIndex + start)..<(d.startIndex + start + entry.compressed)]
        switch entry.method {
        case 0:
            return Data(source)
        case 8:
            // Apple's COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what zip stores.
            var out = Data(count: entry.size)
            let written = out.withUnsafeMutableBytes { dst in
                source.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, entry.compressed, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw Failure.badEntry(entry.name) }
            return out
        default:
            throw Failure.unsupported("compression \(entry.method) in \(entry.name)")
        }
    }

    // MARK: .npy

    private static func parseNPY(_ d: Data, name: String) throws -> Array {
        guard d.count > 10, d.prefix(6) == Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]) else { throw Failure.badEntry(name) }
        let major = Int(d[d.startIndex + 6])
        let headerLength = major == 1 ? u16(d, 8) : u32(d, 8)
        let headerStart = major == 1 ? 10 : 12
        let header = String(decoding: d[(d.startIndex + headerStart)..<(d.startIndex + headerStart + headerLength)], as: UTF8.self)
        func field(_ key: String) -> String? {
            guard let range = header.range(of: "'\(key)':\\s*('[^']*'|\\([^)]*\\)|True|False)", options: .regularExpression) else { return nil }
            return String(header[range]).components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        }
        guard let descr = field("descr")?.trimmingCharacters(in: CharacterSet(charactersIn: "'")), let shapeText = field("shape") else {
            throw Failure.badEntry(name)
        }
        if field("fortran_order") == "True" { throw Failure.unsupported("Fortran order in \(name)") }
        let shape = shapeText.trimmingCharacters(in: CharacterSet(charactersIn: "()")).split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let count = shape.reduce(1, *)
        let body = d[(d.startIndex + headerStart + headerLength)...]
        var values = [Float](repeating: 0, count: count)
        switch descr {
        case "<f4":
            guard body.count >= count * 4 else { throw Failure.badEntry(name) }
            _ = values.withUnsafeMutableBytes { body.copyBytes(to: $0, count: count * 4) }
        case "<f2":
            guard body.count >= count * 2 else { throw Failure.badEntry(name) }
            var halves = [UInt16](repeating: 0, count: count)
            _ = halves.withUnsafeMutableBytes { body.copyBytes(to: $0, count: count * 2) }
            // vImage converts half floats on any Mac, Intel included (Swift's Float16 is Apple silicon only).
            halves.withUnsafeMutableBytes { src in
                values.withUnsafeMutableBytes { dst in
                    var s = vImage_Buffer(data: src.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                    var t = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                    _ = vImageConvert_Planar16FtoPlanarF(&s, &t, 0)
                }
            }
        case "|i1", "<i1":
            guard body.count >= count else { throw Failure.badEntry(name) }
            body.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: Int8.self)
                for i in 0..<count { values[i] = Float(bytes[i]) }
            }
        default:
            throw Failure.unsupported("dtype \(descr) in \(name)")
        }
        return Array(shape: shape, values: values)
    }
}

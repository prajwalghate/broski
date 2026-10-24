import BroskiCore
import PhotosUI
import SwiftUI

/// The first thing you see: write, talk, add photos, check where it's going, save.
struct CaptureView: View {
    @ObservedObject var capture: CaptureModel
    @ObservedObject var recorder: Recorder
    @ObservedObject var store: PhoneStore
    @FocusState private var editing: Bool
    @State private var photos: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var holding = false
    @State private var pressStarted: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let session = store.activeSession { sessionBar(session) }
                chips
                editor
                if recorder.isRecording || recorder.finishing { liveCard }
                if let plan = capture.plan, !recorder.isRecording { planLine(plan) }
                if !capture.attachments.isEmpty { attachmentStrip }
                if let problem = recorder.problem ?? store.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .navigationTitle(store.activeSession == nil ? "New note" : "Add to session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if capture.hasContent {
                        Button("Discard", role: .destructive) { confirmDiscard = true }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = false
                        Task { await capture.save() }
                    } label: {
                        if capture.saving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(!capture.hasContent || recorder.isRecording || capture.saving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
            .confirmationDialog("Throw away this note?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { capture.discard() }
            }
            .overlay(alignment: .top) { toastView }
            .onChange(of: photos) { _, picked in load(picked) }
            .onChange(of: capture.focusRequest) { _, _ in editing = true }
            // However the recording ended (background, a call, an error), the press that started it is over: a gesture
            // iOS cancels never calls onEnded, and the next tap would otherwise just "stop" again.
            .onChange(of: recorder.isRecording) { _, on in
                if !on {
                    holding = false
                    pressStarted = nil
                    holdTask?.cancel()
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in capture.addImage(image) }.ignoresSafeArea()
            }
        }
    }

    // MARK: Parts

    private func sessionBar(_ session: Session) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle").foregroundStyle(.red)
            Text("\(session.kind.label): \(session.title)").lineLimit(1)
            Spacer()
            Text("\(session.entries.count) captures").foregroundStyle(.secondary)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.1)))
    }

    private var chips: some View {
        HStack(spacing: 8) {
            Menu {
                Button { capture.destination = nil } label: { Label("Decide from what I write", systemImage: "wand.and.stars") }
                Button { capture.destination = "" } label: { Label("Inbox", systemImage: "tray") }
                if !store.projects.isEmpty {
                    Section("Projects") {
                        ForEach(store.projects, id: \.self) { name in
                            Button { capture.destination = name } label: { Label(name, systemImage: "folder") }
                        }
                    }
                }
            } label: {
                chip(symbol: capture.destination == nil ? "wand.and.stars" : "folder",
                     text: capture.destination.map { $0.isEmpty ? "Inbox" : $0 } ?? "project: auto", tint: Brand.purple)
            }
            Menu {
                Button { capture.kind = nil } label: { Label("Decide from what I write", systemImage: "wand.and.stars") }
                ForEach(NoteKind.allCases, id: \.self) { kind in
                    Button { capture.kind = kind } label: { Label(kind.label, systemImage: kind.symbol) }
                }
            } label: {
                chip(symbol: (capture.kind ?? .note).symbol, text: capture.kind?.label.lowercased() ?? "type: auto",
                     tint: capture.kind?.color ?? .secondary)
            }
            Spacer()
        }
    }

    private func chip(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if capture.text.isEmpty {
                Text(store.activeSession != nil ? "What did you notice?" : "What's on your mind? Say where it goes: “in the strado project, …”")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8).padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $capture.text)
                .focused($editing)
                .scrollContentBackground(.hidden)
        }
        .font(.body)
        .frame(minHeight: 140)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var liveCard: some View {
        HStack(alignment: .top, spacing: 10) {
            if recorder.finishing { ProgressView().controlSize(.small) } else { LevelDot(level: recorder.level) }
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if recorder.finishing {
                        Text("Writing it out…").foregroundStyle(Brand.purple)
                    } else {
                        Text(holding ? "Listening · let go when you're done" : "Listening · take your time, tap the mic when done")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption.weight(.semibold))
                Text(recorder.transcript.isEmpty ? "Go on…" : recorder.transcript)
                    .font(.callout)
                    .foregroundStyle(recorder.transcript.isEmpty ? .secondary : .primary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.red.opacity(0.08)))
    }

    private func planLine(_ plan: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if capture.thinking { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.turn.down.right").foregroundStyle(Brand.purple) }
            Text(plan).lineLimit(2)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(capture.attachments, id: \.self) { url in
                    FileImage(url: url)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            Button { capture.remove(url) } label: {
                                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .accessibilityLabel("Remove photo")
                            .offset(x: 6, y: -6)
                        }
                }
            }
            .padding(.top, 6)
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            PhotosPicker(selection: $photos, maxSelectionCount: 10, matching: .images) {
                barIcon("photo.on.rectangle", "Photos")
            }
            Button { showCamera = true } label: { barIcon("camera", "Camera") }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Spacer()
            micButton
            Spacer()
            Button { capture.paste() } label: { barIcon("doc.on.clipboard", "Paste") }
            Button { editing.toggle() } label: { barIcon(editing ? "keyboard.chevron.compact.down" : "keyboard", "Type") }
        }
        .foregroundStyle(.primary)
    }

    private func barIcon(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.title3)
            Text(label).font(.caption2)
        }
        .frame(width: 54)
    }

    /// Tap: talk until you tap again. Hold: talk, let go to stop.
    private var micButton: some View {
        ZStack {
            Circle()
                .fill(recorder.isRecording ? Color.red : Brand.purple)
                .frame(width: 72, height: 72)
                .shadow(color: (recorder.isRecording ? Color.red : Brand.purple).opacity(0.35), radius: 10, y: 4)
            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
        .scaleEffect(recorder.isRecording ? 1 + CGFloat(recorder.level) * 0.12 : 1)
        .animation(.easeOut(duration: 0.12), value: recorder.level)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressStarted == nil else { return }
                    pressStarted = Date()
                    guard !recorder.isRecording else { return }
                    holdTask = Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        guard !Task.isCancelled, pressStarted != nil else { return }
                        holding = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        await startRecording()
                        // Let go while the mic was still starting (a permission prompt): stop now, keep what was said.
                        if pressStarted == nil, recorder.isRecording { await stopRecording() }
                    }
                }
                .onEnded { _ in
                    holdTask?.cancel()
                    defer { pressStarted = nil }
                    if holding {
                        holding = false
                        Task { await stopRecording() }
                    } else if recorder.isRecording {
                        Task { await stopRecording() }
                    } else {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { await startRecording() }
                    }
                }
        )
        .accessibilityLabel(recorder.isRecording ? "Stop talking" : "Talk")
    }

    @ViewBuilder private var toastView: some View {
        if let toast = capture.toast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if !toast.detail.isEmpty { Text(toast.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
                if let item = toast.undo {
                    Button("Undo") { capture.undo(item) }.font(.subheadline.weight(.semibold))
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 12, y: 4)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                withAnimation { if capture.toast?.id == toast.id { capture.toast = nil } }
            }
        }
    }

    // MARK: Actions

    private func startRecording() async {
        editing = false
        await recorder.start()
    }

    private func stopRecording() async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        capture.addSpoken(await recorder.stop())
    }

    private func load(_ picked: [PhotosPickerItem]) {
        guard !picked.isEmpty else { return }
        Task {
            for item in picked {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                // Decoding and re-encoding a 48 MP photo takes a second or more: not on the main thread.
                let jpeg = await Task.detached { UIImage(data: data)?.resized(maxSide: 2048).jpegData(compressionQuality: 0.85) }.value
                if let jpeg { capture.addImageData(jpeg, ext: "jpg") }
            }
            photos = []
        }
    }
}

struct LevelDot: View {
    var level: Float
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .scaleEffect(1 + CGFloat(level) * 0.8)
            .animation(.easeOut(duration: 0.1), value: level)
            .padding(.top, 4)
    }
}

/// An image file, loaded off the main thread.
struct FileImage: View {
    let url: URL
    /// In pixels: a thumbnail needs far fewer than a full-screen zoom.
    var maxSide: CGFloat = 600
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color(.tertiarySystemFill))
            }
        }
        .task(id: url) {
            let url = url, maxSide = maxSide
            image = await Task.detached { UIImage(contentsOfFile: url.path)?.resized(maxSide: maxSide) }.value
        }
    }
}

/// The camera, for a quick photo of whatever you're looking at.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

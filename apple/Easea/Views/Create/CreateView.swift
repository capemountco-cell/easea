import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import EaseaCore

/// Record in the app (pausing between takes) or import from the library.
struct CreateView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(CutQueue.self) private var queue
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @State private var camera = CameraController()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var batch: BatchDraft?
    @State private var importing = false
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var error: String?

    private let limits: [Double] = [60, 180, 600]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.permissionDenied {
                permissionMessage
            } else {
                CameraPreview(session: camera.session).ignoresSafeArea()
            }
            controls
            if importing {
                ProgressView("Importing…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPicked(items) }
        }
        .sheet(item: $batch) { draft in
            BatchView(draft: draft) { router.tab = .cuts }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems,
                      maxSelectionCount: BatchDraft.maxVideos, matching: .videos)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                Task { await importFiles(urls) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let movies = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) ?? false }
            guard !movies.isEmpty else { return false }
            Task { await importFiles(movies) }
            return true
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil || camera.errorMessage != nil },
                                                            set: { if !$0 { error = nil; camera.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? camera.errorMessage ?? "")
        }
    }

    private var controls: some View {
        VStack {
            HStack(alignment: .top) {
                (Text("Ease").foregroundStyle(.white) + Text("a").foregroundStyle(Theme.brand))
                    .font(.title3.weight(.heavy))
                Spacer()
                #if os(iOS)
                Button { camera.flipCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                }
                .disabled(camera.isRecording)
                #endif
            }
            .padding()

            Spacer()

            if !camera.takes.isEmpty && !camera.isRecording {
                takesTray.padding(.horizontal)
            }

            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let elapsed = camera.elapsed(at: context.date)
                VStack(spacing: 16) {
                    if camera.isRecording || !camera.takes.isEmpty {
                        Text("\(elapsed.clockString) / \(camera.limit.clockString)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    } else {
                        limitPicker
                    }
                    HStack {
                        Color.clear.frame(width: 48, height: 48)
                        Spacer()
                        recordButton(progress: elapsed / camera.limit)
                        Spacer()
                        importButton
                    }
                    .padding(.horizontal, 36)
                }
            }
            .padding(.bottom, 24)
        }
        .foregroundStyle(.white)
    }

    private var limitPicker: some View {
        HStack(spacing: 4) {
            ForEach(limits, id: \.self) { value in
                Button(value < 120 ? "\(Int(value))s" : "\(Int(value / 60))m") { camera.limit = value }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(camera.limit == value ? Theme.brand : .clear, in: Capsule())
                    .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func recordButton(progress: Double) -> some View {
        Button { camera.toggleRecording() } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.35), lineWidth: 5)
                Circle().trim(from: 0, to: min(1, progress)).stroke(Theme.brand, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                RoundedRectangle(cornerRadius: camera.isRecording ? 8 : 34)
                    .fill(camera.isRecording ? Color.red : .white)
                    .frame(width: camera.isRecording ? 30 : 64, height: camera.isRecording ? 30 : 64)
                    .animation(.spring(duration: 0.25), value: camera.isRecording)
            }
            .frame(width: 80, height: 80)
        }
        .buttonStyle(.plain)
        .disabled(camera.permissionDenied || (!camera.isRecording && camera.remaining < 0.5))
        .accessibilityLabel(camera.isRecording ? "Pause recording" : "Record")
    }

    private var importButton: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
            Button("Files…", systemImage: "folder") { showFileImporter = true }
        } label: {
            Image(systemName: "photo.on.rectangle")
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.black)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
    }

    private var takesTray: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(camera.takes.count) take\(camera.takes.count == 1 ? "" : "s")").font(.headline)
                Text("Record again to add more").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button("Discard", role: .destructive) { camera.discardAll() }
                .buttonStyle(.bordered).tint(.white)
            Button("Cut it") { Task { await cutRecording() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.bottom, 8)
    }

    private var permissionMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash").font(.largeTitle)
            Text("Camera and microphone access is off").font(.headline)
            Text("Turn it on in Settings to record, or import videos instead.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(40)
    }

    // MARK: - Actions

    private func cutRecording() async {
        let takes = camera.collectTakes()
        guard !takes.isEmpty else { return }
        do {
            var project = try await store.createProject(media: takes, moveFiles: true)
            project.overlapAudio = settings.defaultOverlapAudio
            store.update(project)
            await Notifications.requestPermission()
            queue.enqueue([project.id])
            router.open(project.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Copies user files (which may be security-scoped) to temporary files we own.
    private func importFiles(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        let copies: [URL] = await Task.detached {
            urls.prefix(BatchDraft.maxVideos).compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
                return (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil
            }
        }.value
        if copies.isEmpty {
            error = "Those files couldn't be opened."
        } else {
            batch = BatchDraft(urls: copies, filesAreTemporary: true)
        }
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        importing = true
        defer { importing = false; pickerItems = [] }
        var urls: [URL] = []
        for item in items {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                urls.append(movie.url)
            }
        }
        if urls.isEmpty {
            error = "Those videos couldn't be imported."
        } else {
            batch = BatchDraft(urls: urls, filesAreTemporary: true)
        }
    }
}

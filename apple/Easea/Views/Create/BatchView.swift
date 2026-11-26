import SwiftUI
import PhotosUI
import EaseaCore

/// Videos chosen for cutting, before they become projects.
struct BatchDraft: Identifiable {
    static let maxVideos = 10
    let id = UUID()
    var urls: [URL]
    /// Temporary copies can be moved into the project; user files must be copied.
    var filesAreTemporary: Bool
}

/// "New batch": review picked videos, choose a folder and options, then cut them all.
struct BatchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store
    @Environment(CutQueue.self) private var queue
    @Environment(AppSettings.self) private var settings

    @State var draft: BatchDraft
    var onSubmit: () -> Void

    @State private var folder: String?
    @State private var overlapAudio = false
    @State private var combine = false
    @State private var morePicks: [PhotosPickerItem] = []
    @State private var previewURL: URL?
    @State private var working = false
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(Array(draft.urls.enumerated()), id: \.element) { index, url in
                            tile(url: url, index: index)
                        }
                        if draft.urls.count < BatchDraft.maxVideos {
                            addMoreTile
                        }
                    }
                    Text("Tap a video to watch it.").font(.caption).foregroundStyle(.secondary)

                    VStack(spacing: 0) {
                        FolderPicker(folder: $folder, existing: store.folders).padding()
                        Divider()
                        Toggle(isOn: $overlapAudio) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text("Overlap audio")
                                    Text("Let each cut's audio bleed into the next.").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "waveform") }
                        }
                        .padding()
                        if draft.urls.count > 1 {
                            Divider()
                            Toggle(isOn: $combine) {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text("Combine into one video")
                                        Text("Treat these as takes of a single video.").font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "rectangle.stack") }
                            }
                            .padding()
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding()
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) {
                Button(action: submit) {
                    if working { ProgressView().tint(.white) } else { Text(buttonTitle) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(draft.urls.isEmpty || working)
                .padding()
                .background(.bar)
            }
            .navigationTitle("New batch")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cleanup(); dismiss() }
                }
            }
            .onChange(of: morePicks) { _, items in
                guard !items.isEmpty else { return }
                Task { await addPicked(items) }
            }
            .sheet(item: Binding(get: { previewURL.map(IdentifiedURL.init) }, set: { previewURL = $0?.url })) { item in
                PreviewPlayer(url: item.url)
            }
            .alert("Couldn't start", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .onAppear { overlapAudio = settings.defaultOverlapAudio }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 600)
        #endif
    }

    private var buttonTitle: String {
        if combine && draft.urls.count > 1 { return "Cut 1 video from \(draft.urls.count) clips" }
        return "Cut \(draft.urls.count) video\(draft.urls.count == 1 ? "" : "s")"
    }

    private func tile(url: URL, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ThumbnailView(url: url)
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button { remove(at: index) } label: {
                        Image(systemName: "xmark").font(.caption.bold())
                            .frame(width: 24, height: 24).background(.white, in: Circle()).foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
                .onTapGesture { previewURL = url }
            Text("Video \(index + 1) of \(draft.urls.count)").font(.caption.weight(.medium))
        }
    }

    private var addMoreTile: some View {
        PhotosPicker(selection: $morePicks, maxSelectionCount: BatchDraft.maxVideos - draft.urls.count, matching: .videos) {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.title2)
                Text("Up to \(BatchDraft.maxVideos - draft.urls.count) more").font(.caption)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(9 / 16, contentMode: .fit)
            .foregroundStyle(Theme.brand)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundStyle(Theme.brand.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    private func remove(at index: Int) {
        let url = draft.urls.remove(at: index)
        if isTemporary(url) { try? FileManager.default.removeItem(at: url) }
    }

    private func addPicked(_ items: [PhotosPickerItem]) async {
        defer { morePicks = [] }
        for item in items where draft.urls.count < BatchDraft.maxVideos {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                draft.urls.append(movie.url)
            }
        }
    }

    /// Only files we created (picker copies) are deleted; the user's own files are untouched.
    private func cleanup() {
        for url in draft.urls where isTemporary(url) { try? FileManager.default.removeItem(at: url) }
    }

    private func isTemporary(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path)
    }

    private func submit() {
        working = true
        Task {
            defer { working = false }
            do {
                var ids: [UUID] = []
                let groups: [[URL]] = combine ? [draft.urls] : draft.urls.map { [$0] }
                for (i, group) in groups.enumerated() {
                    let title = groups.count > 1 ? "\(ProjectStore.defaultTitle()) · \(i + 1)" : nil
                    let move = group.allSatisfy(isTemporary)
                    var project = try await store.createProject(title: title, folder: folder, media: group, moveFiles: move)
                    project.overlapAudio = overlapAudio
                    store.update(project)
                    ids.append(project.id)
                }
                await Notifications.requestPermission()
                queue.enqueue(ids)
                onSubmit()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: URL { url }
}

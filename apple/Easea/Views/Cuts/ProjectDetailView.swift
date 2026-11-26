import SwiftUI
import PhotosUI
import EaseaCore

/// Shows the right screen for a cut's state: waiting, cutting, ready to edit, or failed.
struct ProjectDetailView: View {
    @Environment(ProjectStore.self) private var store
    let id: UUID

    var body: some View {
        if let project = store.project(id) {
            switch project.status {
            case .ready where project.edl != nil:
                EditorView(project: project).id(project.id)
            case .queued, .processing:
                ProcessingView(project: project)
            case .failed(let message):
                DraftView(project: project, failure: message)
            default:
                DraftView(project: project, failure: nil)
            }
        } else {
            ContentUnavailableView("This cut was deleted", systemImage: "trash")
        }
    }
}

/// "You're free to go. We'll tell you when it's ready."
struct ProcessingView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(CutQueue.self) private var queue
    let project: Project

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Cutting").font(.title2.weight(.bold))
                Text("You're free to go. We'll tell you when it's ready.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 24)

            ThumbnailView(url: project.sources.first.map { store.url(for: $0, in: project) })
                .aspectRatio(9 / 16, contentMode: .fit)
                .frame(maxHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.brand, lineWidth: 3))
                .overlay {
                    ZStack {
                        Color.black.opacity(0.25)
                        Text(project.status == .queued ? "Queued" : "\(Int(project.progress * 100))%")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

            Text(project.progressLabel).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("Stop") { queue.cancel(project.id) }
                .buttonStyle(.bordered)
                .padding(.bottom, 24)
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .navigationTitle(project.title)
        .inlineTitle()
        .animation(.default, value: project.progress)
    }
}

/// Not cut yet (or failed): add more footage or start the cut.
struct DraftView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(CutQueue.self) private var queue
    let project: Project
    let failure: String?
    @State private var picks: [PhotosPickerItem] = []
    @State private var adding = false

    var body: some View {
        VStack(spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(project.sources) { source in
                        ThumbnailView(url: store.url(for: source, in: project))
                            .frame(width: 90, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .bottomLeading) {
                                Text(source.duration.clockString).font(.caption2.bold()).foregroundStyle(.white).padding(4)
                            }
                    }
                }
                .padding(.horizontal)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            Text("\(project.sources.count) clip\(project.sources.count == 1 ? "" : "s") · \(project.footageDuration.clockString) of footage")
                .foregroundStyle(.secondary)
            PhotosPicker(selection: $picks, maxSelectionCount: 10, matching: .videos) {
                Label(adding ? "Adding…" : "Add more footage", systemImage: "plus")
            }
            .disabled(adding)
            Spacer()
            Button(failure == nil ? "Cut it" : "Try again") {
                queue.enqueue([project.id])
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding()
        }
        .padding(.top)
        .background(Theme.background)
        .navigationTitle(project.title)
        .inlineTitle()
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            Task {
                adding = true
                defer { adding = false; picks = [] }
                var urls: [URL] = []
                for item in items {
                    if let movie = try? await item.loadTransferable(type: PickedMovie.self) { urls.append(movie.url) }
                }
                try? await store.appendMedia(urls, to: project.id, moveFiles: true)
            }
        }
    }
}

/// "Your cut is ready" — time saved versus editing by hand.
struct CutReadyView: View {
    let project: Project
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Your cut is ready").font(.headline).padding(.top, 24)
            if let report = project.report {
                VStack(spacing: 8) {
                    Text(report.estimatedTimeSaved.clockString)
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("saved vs cutting it yourself").foregroundStyle(.secondary)
                    Text("\(report.footageDuration.clockString) of footage · \(report.trimCount) trims · \(report.finalDuration.clockString) final")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let summary = report.summary {
                        Label(summary, systemImage: "scissors")
                            .font(.footnote)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal)
            }
            Button("Open my edit", action: onContinue)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal)
            Spacer()
        }
        .background(Theme.background)
    }
}

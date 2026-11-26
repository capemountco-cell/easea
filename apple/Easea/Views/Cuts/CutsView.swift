import SwiftUI
import EaseaCore

/// Library of cuts, grouped by folder. Select several finished cuts to save them together.
struct CutsView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(Router.self) private var router
    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var bulkProgress: (done: Int, total: Int)?
    @State private var message: String?

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.cutsPath) {
            Group {
                if store.projects.isEmpty {
                    ContentUnavailableView("No cuts yet", systemImage: "scissors",
                                           description: Text("Record or import a video and Easea will make the first cut for you."))
                } else {
                    list
                }
            }
            .background(Theme.background)
            .navigationTitle("Cuts")
            .navigationDestination(for: UUID.self) { id in
                ProjectDetailView(id: id)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if !store.projects.isEmpty {
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle()
                            selection.removeAll()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { bulkBar }
            }
            .alert("Export", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }

    private struct FolderGroup: Identifiable {
        var name: String
        var projects: [Project]
        var id: String { name }
    }

    /// Unfiled cuts first ("Recent"), then folders alphabetically.
    private var groups: [FolderGroup] {
        let grouped = Dictionary(grouping: store.projects) { $0.folder ?? "" }
        return grouped.keys.sorted { a, b in a.isEmpty ? true : (b.isEmpty ? false : a < b) }
            .map { FolderGroup(name: $0, projects: grouped[$0] ?? []) }
    }

    private var list: some View {
        List {
            ForEach(groups) { group in
                let projects = group.projects
                Section(group.name.isEmpty ? "Recent" : group.name) {
                    ForEach(projects) { project in
                        if selecting {
                            Button { toggle(project) } label: {
                                HStack {
                                    Image(systemName: selection.contains(project.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection.contains(project.id) ? Theme.brand : .secondary)
                                    CutRow(project: project)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink(value: project.id) { CutRow(project: project) }
                        }
                    }
                    .onDelete { offsets in
                        store.delete(Set(offsets.map { projects[$0].id }))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var bulkBar: some View {
        let ready = selection.filter { store.project($0)?.status == .ready }
        return HStack {
            Button(role: .destructive) {
                store.delete(selection)
                selection.removeAll()
            } label: { Image(systemName: "trash") }
            .disabled(selection.isEmpty)
            Spacer()
            if let bulkProgress {
                ProgressView(value: Double(bulkProgress.done), total: Double(bulkProgress.total)) {
                    Text("Saving \(bulkProgress.done + 1) of \(bulkProgress.total)…").font(.caption)
                }
                .frame(maxWidth: 220)
            } else {
                Button("Save \(ready.count) to Photos") { Task { await saveAll(Array(ready)) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(ready.isEmpty)
            }
        }
        .padding()
        .background(.bar)
    }

    private func toggle(_ project: Project) {
        if selection.contains(project.id) { selection.remove(project.id) } else { selection.insert(project.id) }
    }

    /// Exports each selected cut with its captions, text and timeline edits, then saves to Photos.
    private func saveAll(_ ids: [UUID]) async {
        var failures: [String] = []
        for (i, id) in ids.enumerated() {
            bulkProgress = (i, ids.count)
            guard let project = store.project(id) else { continue }
            do {
                let url = try await Exporter.export(project: project, sourceURLs: store.sourceURLs(for: project)) { _ in }
                try await PhotoLibrary.save(videoAt: url)
                try? FileManager.default.removeItem(at: url)
            } catch {
                failures.append("\(project.title): \(error.localizedDescription)")
            }
        }
        bulkProgress = nil
        selecting = false
        selection.removeAll()
        message = failures.isEmpty ? "Saved \(ids.count) video\(ids.count == 1 ? "" : "s") to Photos." : failures.joined(separator: "\n")
    }
}

struct CutRow: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: project.sources.first.map { store.url(for: $0, in: project) })
                .frame(width: 54, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(project.title).font(.headline).lineLimit(1)
                status
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var status: some View {
        switch project.status {
        case .draft:
            Text("\(project.footageDuration.clockString) of footage · not cut yet").font(.caption).foregroundStyle(.secondary)
        case .queued:
            Pill(text: "Waiting", systemImage: "clock")
        case .processing:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: project.progress)
                Text("\(project.progressLabel) · \(Int(project.progress * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            HStack(spacing: 6) {
                Pill(text: (project.edl?.duration ?? 0).clockString, systemImage: "checkmark")
                if let saved = project.report?.estimatedTimeSaved {
                    Text("saved \(saved.clockString)").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed:
            Pill(text: "Failed", systemImage: "exclamationmark.triangle", tint: .red)
        }
    }
}

import Foundation
import AVFoundation
import Observation

/// Saves projects as JSON next to their media in Application Support.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    let rootURL: URL

    init(rootURL: URL? = nil) {
        let base = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Easea/Projects", isDirectory: true)
        self.rootURL = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    var folders: [String] {
        Array(Set(projects.compactMap(\.folder))).sorted()
    }

    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    func directory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func url(for source: SourceMedia, in project: Project) -> URL {
        directory(for: project.id).appendingPathComponent(source.fileName)
    }

    func sourceURLs(for project: Project) -> [URL] {
        project.sources.map { url(for: $0, in: project) }
    }

    /// Creates a project from media files. Files are moved into the project's folder when
    /// they are temporary (recordings, picker copies) and copied otherwise.
    @discardableResult
    func createProject(title: String? = nil, folder: String? = nil, media: [URL], moveFiles: Bool) async throws -> Project {
        var project = Project(title: title ?? Self.defaultTitle(), folder: folder)
        try FileManager.default.createDirectory(at: directory(for: project.id), withIntermediateDirectories: true)
        project.sources = try await importMedia(media, into: project, move: moveFiles)
        projects.insert(project, at: 0)
        save(project) // written immediately so a crash right after import loses nothing
        return project
    }

    /// Adds more footage to an existing session ("add more footage to the same session").
    func appendMedia(_ media: [URL], to id: UUID, moveFiles: Bool) async throws {
        guard var project = project(id) else { return }
        project.sources += try await importMedia(media, into: project, move: moveFiles)
        // New footage invalidates the old cut.
        project.analyses = nil
        project.edl = nil
        project.report = nil
        project.status = .draft
        update(project)
    }

    private func importMedia(_ media: [URL], into project: Project, move: Bool) async throws -> [SourceMedia] {
        var result: [SourceMedia] = []
        for url in media {
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let name = "\(UUID().uuidString).\(ext)"
            let dest = directory(for: project.id).appendingPathComponent(name)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if move {
                try FileManager.default.moveItem(at: url, to: dest)
            } else {
                try FileManager.default.copyItem(at: url, to: dest)
            }
            let duration = try await AVURLAsset(url: dest).load(.duration).seconds
            result.append(SourceMedia(fileName: name, duration: duration.isFinite ? duration : 0))
        }
        return result
    }

    func update(_ project: Project) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i] = project
        scheduleSave(project.id)
    }

    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    /// Coalesces rapid edits (slider drags, typing) into one write.
    private func scheduleSave(_ id: UUID) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let project = self.project(id) else { return }
            self.pendingSaves[id] = nil
            self.save(project)
        }
    }

    /// Updates in memory only; used for frequent progress ticks.
    func updateTransient(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
    }

    func mutate(_ id: UUID, _ change: (inout Project) -> Void) {
        guard var p = project(id) else { return }
        change(&p)
        update(p)
    }

    func delete(_ ids: Set<UUID>) {
        for id in ids {
            pendingSaves[id]?.cancel()
            pendingSaves[id] = nil
            try? FileManager.default.removeItem(at: directory(for: id))
        }
        projects.removeAll { ids.contains($0.id) }
    }

    // MARK: - Persistence

    private func save(_ project: Project) {
        let url = directory(for: project.id).appendingPathComponent("project.json")
        do {
            let data = try JSONEncoder().encode(project)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save project \(project.id): \(error)")
        }
    }

    private func load() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        projects = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("project.json")),
                  var p = try? decoder.decode(Project.self, from: data) else { return nil }
            // A cut that was interrupted by the app quitting needs to be restarted.
            if p.status.isWorking { p.status = .draft }
            return p
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func defaultTitle(date: Date = .now) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

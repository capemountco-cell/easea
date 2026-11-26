import Foundation
import Observation
import EaseaCore
#if os(iOS)
import UIKit
#endif

/// Processes cuts one at a time so the user can queue a batch and walk away.
@MainActor
@Observable
final class CutQueue {
    private let store: ProjectStore
    private let settings: AppSettings
    private var pending: [UUID] = []
    private var worker: Task<Void, Never>?
    private(set) var currentID: UUID?
    /// Projects queued together; one notification fires when the whole batch is ready.
    private var batches: [Set<UUID>] = []
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(store: ProjectStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func enqueue(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids where !pending.contains(id) && currentID != id {
            pending.append(id)
            store.mutate(id) { $0.status = .queued; $0.progress = 0; $0.progressLabel = "Waiting" }
        }
        if ids.count > 1 { batches.append(Set(ids)) }
        startIfNeeded()
    }

    /// Re-runs only the decision step with current settings, reusing transcripts. Instant.
    func recut(_ id: UUID) {
        guard var p = store.project(id), let analyses = p.analyses else { enqueue([id]); return }
        let (edl, report) = AutoCutEngine(options: settings.cutOptions).makeCut(sources: analyses)
        p.edl = edl
        p.report = report
        store.update(p)
    }

    func cancel(_ id: UUID) {
        if currentID == id {
            worker?.cancel()
        }
        pending.removeAll { $0 == id }
        store.mutate(id) { $0.status = .draft; $0.progress = 0 }
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        beginBackgroundTime()
        worker = Task { [weak self] in
            while let self, let next = self.popNext() {
                await self.process(next)
            }
            self?.worker = nil
            self?.currentID = nil
            self?.endBackgroundTime()
        }
    }

    private func popNext() -> UUID? {
        guard !pending.isEmpty else { return nil }
        let id = pending.removeFirst()
        currentID = id
        return id
    }

    private func process(_ id: UUID) async {
        guard let project = store.project(id) else { return }
        store.mutate(id) { $0.status = .processing }
        let pipeline = CutPipeline(options: settings.cutOptions)
        let job = Task.detached(priority: .userInitiated) { [store] () async throws -> CutPipeline.Output in
            let urls = await store.sourceURLs(for: project)
            return try await pipeline.run(
                sourceURLs: urls,
                durations: project.sources.map(\.duration),
                cachedAnalyses: project.analyses
            ) { value, label in
                Task { @MainActor in
                    store.updateTransient(id) { $0.progress = value; $0.progressLabel = label }
                }
            }
        }
        do {
            let output = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
            store.mutate(id) {
                $0.analyses = output.analyses
                $0.edl = output.edl
                $0.report = output.report
                $0.captions = output.captions
                $0.status = .ready
                $0.progress = 1
            }
            await notifyIfDone(id)
        } catch is CancellationError {
            store.mutate(id) { $0.status = .draft; $0.progress = 0 }
        } catch {
            store.mutate(id) { $0.status = .failed(error.localizedDescription) }
            await Notifications.send(title: "Couldn't cut \(project.title)", body: error.localizedDescription, projectID: id)
        }
    }

    private func notifyIfDone(_ id: UUID) async {
        if let index = batches.firstIndex(where: { $0.contains(id) }) {
            let batch = batches[index]
            let done = batch.allSatisfy { store.project($0)?.status == .ready || store.project($0) == nil }
            if done {
                batches.remove(at: index)
                await Notifications.send(title: "Your batch is ready", body: "\(batch.count) videos are cut and waiting for you.", projectID: nil)
            }
            return
        }
        let saved = store.project(id)?.report?.estimatedTimeSaved ?? 0
        await Notifications.send(title: "Your cut is ready",
                                 body: "Tap to open your edit. You saved \(saved.clockString).",
                                 projectID: id)
    }

    // MARK: - Background time

    /// iOS gives a short grace period after the app leaves the foreground. For long batches,
    /// adopt `BGContinuedProcessingTask` (iOS 26) or move processing to a server (see README).
    private func beginBackgroundTime() {
        #if os(iOS)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Cutting") { [weak self] in
            self?.endBackgroundTime()
        }
        #endif
    }

    private func endBackgroundTime() {
        #if os(iOS)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }
}

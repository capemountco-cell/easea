import Foundation
import AVFoundation
import Photos

enum Exporter {
    /// Renders the final video, with captions and text burned in, to a temporary file.
    static func export(project: Project, sourceURLs: [URL], progress: @escaping (Double) -> Void) async throws -> URL {
        let plan = try await VideoRenderer.makePlan(project: project, sourceURLs: sourceURLs)
        VideoRenderer.addTextLayers(to: plan, project: project)

        let preset = presetName(project.exportSettings)
        guard let session = AVAssetExportSession(asset: plan.composition, presetName: preset) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let safeTitle = project.title.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeTitle)-\(UUID().uuidString.prefix(6)).mp4")
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = plan.videoComposition
        session.audioMix = plan.audioMix

        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { ticker.cancel() }

        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }
        if let error = session.error { throw error }
        try Task.checkCancellation()
        progress(1)
        return url
    }

    static func presetName(_ settings: ExportSettings) -> String {
        switch (settings.resolution, settings.hevc) {
        case (.hd720, _): AVAssetExportPreset1280x720
        case (.hd1080, false): AVAssetExportPreset1920x1080
        case (.hd1080, true): AVAssetExportPresetHEVC1920x1080
        case (.uhd4K, false): AVAssetExportPreset3840x2160
        case (.uhd4K, true): AVAssetExportPresetHEVC3840x2160
        }
    }
}

enum PhotoLibrary {
    static func save(videoAt url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "Allow Easea to add to Photos in Settings to save your videos."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }
}

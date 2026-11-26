import Foundation
import EaseaCore

/// Runs the full automatic edit for one project:
/// audio → transcript + loudness per file → retake/filler/silence removal → captions.
struct CutPipeline {
    var options: CutOptions

    struct Output {
        var analyses: [SourceAnalysis]
        var edl: EditDecisionList
        var report: CutReport
        var captions: [Caption]
    }

    func run(sourceURLs: [URL], durations: [Double], cachedAnalyses: [SourceAnalysis]?,
             progress: @escaping (Double, String) -> Void) async throws -> Output {
        var analyses: [SourceAnalysis]
        if let cached = cachedAnalyses, cached.count == sourceURLs.count {
            analyses = cached
        } else {
            analyses = []
            let total = Double(sourceURLs.count)
            for (i, url) in sourceURLs.enumerated() {
                try Task.checkCancellation()
                let base = Double(i) / total
                let share = 1 / total
                let label = sourceURLs.count > 1 ? "Listening to take \(i + 1) of \(sourceURLs.count)" : "Listening to your video"
                progress(base, label)

                let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: audioURL) }
                try await AudioAnalyzer.extractAudio(from: url, to: audioURL)
                progress(base + share * 0.1, label)

                let loudness = try await AudioAnalyzer.loudness(of: audioURL)
                progress(base + share * 0.2, label)

                let words = try await Transcriber().transcribe(audioURL: audioURL, duration: durations[i]) { p in
                    progress(base + share * (0.2 + 0.75 * p), label)
                }
                analyses.append(SourceAnalysis(duration: durations[i], words: words, loudness: loudness))
            }
        }

        progress(0.97, "Making the cut")
        let (edl, report) = AutoCutEngine(options: options).makeCut(sources: analyses)
        let captions = CaptionBuilder.build(sources: analyses)
        progress(1, "Done")
        return Output(analyses: analyses, edl: edl, report: report, captions: captions)
    }
}

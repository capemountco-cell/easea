import Foundation
import EaseaCore

/// Runs the full automatic edit for one project:
/// audio → transcript + loudness per file (on device) → Claude decides what to cut
/// (on-device rules if Claude is off or unreachable) → clips and captions.
struct CutPipeline {
    var options: CutOptions
    /// nil = edit with the on-device rules.
    var claude: ClaudeEditor?

    struct Output {
        var analyses: [SourceAnalysis]
        var edl: EditDecisionList
        var report: CutReport
        var captions: [Caption]
        var plan: CutPlan?
    }

    func run(sourceURLs: [URL], durations: [Double], cachedAnalyses: [SourceAnalysis]?, cachedPlan: CutPlan?,
             progress: @escaping (Double, String) -> Void) async throws -> Output {
        // Transcription takes most of the time when Claude is off; leave room for its request when on.
        let analysisShare = claude == nil ? 0.97 : 0.8
        var analyses: [SourceAnalysis]
        if let cached = cachedAnalyses, cached.count == sourceURLs.count {
            analyses = cached
        } else {
            analyses = []
            let total = Double(sourceURLs.count)
            for (i, url) in sourceURLs.enumerated() {
                try Task.checkCancellation()
                let base = analysisShare * Double(i) / total
                let share = analysisShare / total
                let label = sourceURLs.count > 1 ? "Listening to take \(i + 1) of \(sourceURLs.count)" : "Listening to your video"
                progress(base, label)

                let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: audioURL) }
                try await AudioAnalyzer.extractAudio(from: url, to: audioURL)
                progress(base + share * 0.1, label)

                let loudness = try await AudioAnalyzer.loudness(of: audioURL)
                progress(base + share * 0.2, label)

                let words = try await Transcriber().transcribe(audioURL: audioURL, duration: durations[i]) { p in
                    progress(base + share * (0.2 + 0.8 * p), label)
                }
                analyses.append(SourceAnalysis(duration: durations[i], words: words, loudness: loudness))
            }
        }

        let engine = AutoCutEngine(options: options)
        var plan = cachedPlan
        var claudeError: String?
        let hasSpeech = analyses.contains { !$0.words.isEmpty }
        if plan == nil, let claude, hasSpeech {
            progress(analysisShare, "Editing your cut")
            do {
                plan = try await claude.plan(sources: analyses, options: options)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                claudeError = error.localizedDescription
            }
        }
        try Task.checkCancellation()

        progress(0.98, "Making the cut")
        var edl: EditDecisionList
        var report: CutReport
        if let plan {
            analyses = plan.applyingCorrections(to: analyses)
            (edl, report) = engine.makeCut(sources: analyses, plan: plan)
            report.editor = "Claude"
        } else {
            (edl, report) = engine.makeCut(sources: analyses)
            report.editor = "On-device"
            // Internal only; never shown to users.
            if let claudeError { print("Cloud editor unavailable, used on-device rules: \(claudeError)") }
        }
        let captions = CaptionBuilder.build(sources: analyses)
        progress(1, "Done")
        return Output(analyses: analyses, edl: edl, report: report, captions: captions, plan: plan)
    }
}

import Foundation
import AVFoundation
import Speech
import EaseaCore

enum TranscriberError: LocalizedError {
    case notAuthorized
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Speech recognition is turned off. Turn it on in Settings so Easea can find your best takes."
        case .unavailable: "Speech recognition isn't available for your language on this device."
        case .failed(let m): "Transcription failed: \(m)"
        }
    }
}

/// Word-level, on-device transcription with Apple's Speech framework.
/// Nothing leaves the device, and there's no per-minute cost.
///
/// On iOS 26 / macOS 26 `SpeechAnalyzer` + `SpeechTranscriber` handle long-form audio better;
/// swapping it in only requires returning the same `[Word]` from a new implementation.
final class Transcriber: NSObject, SFSpeechRecognitionTaskDelegate {
    private var continuation: CheckedContinuation<[Word], Error>?
    private var words: [Word] = []
    private var duration: Double = 1
    private var onProgress: ((Double) -> Void)?
    private var task: SFSpeechRecognitionTask?

    static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    func transcribe(audioURL: URL, duration: Double, locale: Locale = .current,
                    progress: @escaping (Double) -> Void) async throws -> [Word] {
        guard await Self.requestAuthorization() else { throw TranscriberError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw TranscriberError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        self.words = []
        self.duration = max(duration, 0.1)
        self.onProgress = progress

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                self.continuation = c
                self.task = recognizer.recognitionTask(with: request, delegate: self)
            }
        } onCancel: { [weak self] in
            self?.task?.cancel()
        }
    }

    // MARK: SFSpeechRecognitionTaskDelegate

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription) {
        if let last = transcription.segments.last {
            onProgress?(min(1, (last.timestamp + last.duration) / duration))
        }
    }

    /// Long recordings arrive as several final results (one per utterance); append the new segments.
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
        let lastEnd = words.last?.end ?? -1
        for segment in result.bestTranscription.segments where segment.timestamp >= lastEnd - 0.05 {
            words += Self.split(segment)
        }
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        defer { continuation = nil; self.task = nil }
        if successfully || !words.isEmpty {
            continuation?.resume(returning: words)
        } else if let error = task.error as NSError? {
            // "No speech detected" is a valid outcome: the loudness fallback takes over.
            if error.domain == "kAFAssistantErrorDomain", error.code == 1110 {
                continuation?.resume(returning: [])
            } else {
                continuation?.resume(throwing: TranscriberError.failed(error.localizedDescription))
            }
        } else {
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Some segments hold several words; spread their time evenly.
    private static func split(_ segment: SFTranscriptionSegment) -> [Word] {
        let parts = segment.substring.split(separator: " ").map(String.init)
        guard parts.count > 1 else {
            return [Word(text: segment.substring, start: segment.timestamp,
                         end: segment.timestamp + segment.duration, confidence: segment.confidence)]
        }
        let step = segment.duration / Double(parts.count)
        return parts.enumerated().map { i, text in
            Word(text: text, start: segment.timestamp + Double(i) * step,
                 end: segment.timestamp + Double(i + 1) * step, confidence: segment.confidence)
        }
    }
}

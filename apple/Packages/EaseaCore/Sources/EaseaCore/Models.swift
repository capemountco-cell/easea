import Foundation

/// One recognized word with timing, in seconds relative to the start of its source file.
public struct Word: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Float

    public init(text: String, start: Double, end: Double, confidence: Float = 1) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    public var duration: Double { end - start }

    /// Lowercased, punctuation-stripped form used for matching takes.
    public var normalized: String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }
}

/// Audio loudness sampled at a fixed frame rate (e.g. one value every 10 ms).
public struct Loudness: Codable, Hashable, Sendable {
    public var frameDuration: Double
    public var decibels: [Float]

    public init(frameDuration: Double, decibels: [Float]) {
        self.frameDuration = frameDuration
        self.decibels = decibels
    }

    public var duration: Double { Double(decibels.count) * frameDuration }

    /// Loudest value inside a time window, or -infinity when the window is empty.
    public func peak(from start: Double, to end: Double) -> Float {
        guard frameDuration > 0, !decibels.isEmpty else { return -.infinity }
        let lo = max(0, Int((start / frameDuration).rounded(.down)))
        let hi = min(decibels.count, Int((end / frameDuration).rounded(.up)))
        guard lo < hi else { return -.infinity }
        return decibels[lo..<hi].max() ?? -.infinity
    }

    public func isSilent(at time: Double, threshold: Float) -> Bool {
        guard frameDuration > 0 else { return true }
        let i = Int(time / frameDuration)
        guard decibels.indices.contains(i) else { return true }
        return decibels[i] < threshold
    }
}

/// Everything the engine needs to know about one recorded or imported file.
public struct SourceAnalysis: Codable, Hashable, Sendable {
    public var duration: Double
    public var words: [Word]
    public var loudness: Loudness?

    public init(duration: Double, words: [Word], loudness: Loudness? = nil) {
        self.duration = duration
        self.words = words
        self.loudness = loudness
    }
}

/// A span of a source file that appears in the final video.
public struct Clip: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var sourceIndex: Int
    public var start: Double
    public var end: Double

    public init(id: UUID = UUID(), sourceIndex: Int, start: Double, end: Double) {
        self.id = id
        self.sourceIndex = sourceIndex
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
}

/// The ordered list of clips that makes up an edit. Order is output order.
public struct EditDecisionList: Codable, Hashable, Sendable {
    public var clips: [Clip]

    public init(clips: [Clip] = []) { self.clips = clips }

    public var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    /// Output-timeline start time of each clip.
    public var clipStartTimes: [Double] {
        var t = 0.0
        return clips.map { clip in defer { t += clip.duration }; return t }
    }

    /// Maps a moment in a source file to the output timeline, if that moment survived the edit.
    public func outputTime(sourceIndex: Int, sourceTime: Double) -> Double? {
        var t = 0.0
        for clip in clips {
            if clip.sourceIndex == sourceIndex, sourceTime >= clip.start, sourceTime <= clip.end {
                return t + (sourceTime - clip.start)
            }
            t += clip.duration
        }
        return nil
    }

    /// Maps an output time back to (clip index, source time).
    public func locate(outputTime: Double) -> (clipIndex: Int, sourceTime: Double)? {
        var t = 0.0
        for (i, clip) in clips.enumerated() {
            if outputTime < t + clip.duration || i == clips.count - 1 {
                return (i, clip.start + min(max(0, outputTime - t), clip.duration))
            }
            t += clip.duration
        }
        return nil
    }
}

/// Summary shown on the "your cut is ready" screen.
public struct CutReport: Codable, Hashable, Sendable {
    public var footageDuration: Double
    public var finalDuration: Double
    public var trimCount: Int
    public var retakesRemoved: Int
    public var fillersRemoved: Int
    /// Rough estimate of how long a person would spend making the same cuts by hand.
    public var estimatedTimeSaved: Double
    /// Tangents and off-script talk removed (only the Claude editor judges these).
    public var ramblingRemoved: Int?
    /// Who made the decisions, e.g. "Claude" or "On-device".
    public var editor: String?
    /// One-sentence explanation of the edit, when the editor gives one.
    public var summary: String?

    public init(footageDuration: Double, finalDuration: Double, trimCount: Int,
                retakesRemoved: Int, fillersRemoved: Int, estimatedTimeSaved: Double,
                ramblingRemoved: Int? = nil, editor: String? = nil, summary: String? = nil) {
        self.footageDuration = footageDuration
        self.finalDuration = finalDuration
        self.trimCount = trimCount
        self.retakesRemoved = retakesRemoved
        self.fillersRemoved = fillersRemoved
        self.estimatedTimeSaved = estimatedTimeSaved
        self.ramblingRemoved = ramblingRemoved
        self.editor = editor
        self.summary = summary
    }
}

public extension Double {
    /// "2:47" style formatting for durations.
    var clockString: String {
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

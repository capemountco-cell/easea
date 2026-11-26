import Foundation

/// A caption anchored to source time, so it stays in sync when clips are trimmed or reordered.
public struct Caption: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var sourceIndex: Int
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: UUID = UUID(), sourceIndex: Int, start: Double, end: Double, text: String) {
        self.id = id
        self.sourceIndex = sourceIndex
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A caption placed on the output timeline.
public struct TimedText: Hashable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
}

public enum CaptionBuilder {
    /// Groups words into short, punchy captions (a few words each, the style used in short-form video).
    public static func build(sources: [SourceAnalysis], maxWords: Int = 4, maxChars: Int = 24, maxGap: Double = 0.5) -> [Caption] {
        var captions: [Caption] = []
        for (i, source) in sources.enumerated() {
            var group: [Word] = []
            func flush() {
                guard let first = group.first, let last = group.last else { return }
                captions.append(Caption(sourceIndex: i, start: first.start, end: last.end,
                                        text: group.map(\.text).joined(separator: " ")))
                group = []
            }
            for word in source.words.sorted(by: { $0.start < $1.start }) {
                if let last = group.last {
                    let chars = group.map(\.text.count).reduce(0, +) + group.count + word.text.count
                    let sentenceEnd = last.text.last.map { ".!?".contains($0) } ?? false
                    if group.count >= maxWords || chars > maxChars || word.start - last.end > maxGap || sentenceEnd {
                        flush()
                    }
                }
                group.append(word)
            }
            flush()
        }
        return captions
    }

    /// Places captions on the output timeline. A caption that spans a cut is split around it;
    /// captions whose speech was cut out disappear.
    public static func layout(_ captions: [Caption], on edl: EditDecisionList) -> [TimedText] {
        var result: [TimedText] = []
        let starts = edl.clipStartTimes
        for (clip, clipStart) in zip(edl.clips, starts) {
            for c in captions where c.sourceIndex == clip.sourceIndex {
                let s = max(c.start, clip.start)
                let e = min(c.end, clip.end)
                // Require most of a short caption to survive, so fragments of cut words don't flash.
                guard e - s >= min(0.15, c.end - c.start) else { continue }
                result.append(TimedText(id: c.id, start: clipStart + s - clip.start,
                                        end: clipStart + e - clip.start, text: c.text))
            }
        }
        return result.sorted { $0.start < $1.start }
    }
}

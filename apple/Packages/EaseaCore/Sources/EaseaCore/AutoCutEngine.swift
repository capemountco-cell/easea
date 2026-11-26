import Foundation

/// Tuning knobs for the automatic first cut.
public struct CutOptions: Codable, Hashable, Sendable {
    /// Audio quieter than this counts as silence.
    public var silenceThreshold: Float = -38
    /// Pauses longer than this get cut down.
    public var maxPause: Double = 0.35
    /// Breathing room kept before and after speech.
    public var padding: Double = 0.08
    /// A gap this long between words starts a new phrase (used for retake detection).
    public var phraseGap: Double = 0.6
    public var removeRetakes = true
    public var removeFillers = true
    /// How many following phrases are searched for a better take.
    public var retakeLookahead = 3
    /// Share of leading words that must match for two phrases to count as takes of the same line.
    public var retakeSimilarity = 0.6
    /// Clips shorter than this are dropped.
    public var minClip: Double = 0.2
    public var fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm"]

    public init() {}
}

/// Turns transcripts and loudness into an edit: keeps the last good take of each line,
/// drops fillers, false starts and dead air.
public struct AutoCutEngine: Sendable {
    public var options: CutOptions

    public init(options: CutOptions = CutOptions()) { self.options = options }

    /// A word tagged with the file it came from.
    struct TaggedWord {
        var source: Int
        var word: Word
    }

    struct Phrase {
        var words: [TaggedWord]
        var tokens: [String] { words.map(\.word.normalized).filter { !$0.isEmpty } }
    }

    public func makeCut(sources: [SourceAnalysis]) -> (EditDecisionList, CutReport) {
        let footage = sources.reduce(0) { $0 + $1.duration }
        var retakes = 0
        var fillers = 0

        // 1. Flatten words across sources in recording order and drop fillers.
        var tagged: [TaggedWord] = []
        for (i, source) in sources.enumerated() {
            for word in source.words.sorted(by: { $0.start < $1.start }) {
                if options.removeFillers, options.fillerWords.contains(word.normalized) {
                    fillers += 1
                    continue
                }
                tagged.append(TaggedWord(source: i, word: word))
            }
        }

        // 2. Group into phrases and remove false starts / retakes.
        var phrases = groupPhrases(tagged)
        if options.removeRetakes {
            let (cleaned, removed) = removeRetakes(from: phrases)
            phrases = cleaned
            retakes = removed
        }

        // 3. Build keep ranges around remaining speech.
        var clips: [Clip] = []
        for (i, source) in sources.enumerated() {
            let words = phrases.flatMap(\.words).filter { $0.source == i }.map(\.word)
            if words.isEmpty {
                // No speech recognized: fall back to loudness so non-verbal clips aren't lost.
                if source.words.isEmpty, let loudness = source.loudness {
                    clips += loudRanges(loudness, duration: source.duration).map {
                        Clip(sourceIndex: i, start: $0.lowerBound, end: $0.upperBound)
                    }
                }
                continue
            }
            let keptStarts = Set(words.map(\.start))
            let removed = source.words.filter { !keptStarts.contains($0.start) }
            clips += speechRanges(words, removed: removed, source: source).map {
                Clip(sourceIndex: i, start: $0.lowerBound, end: $0.upperBound)
            }
        }
        clips = clips.filter { $0.duration >= options.minClip }

        let edl = EditDecisionList(clips: clips)
        let trims = countTrims(clips: clips, sources: sources)
        let report = CutReport(
            footageDuration: footage,
            finalDuration: edl.duration,
            trimCount: trims,
            retakesRemoved: retakes,
            fillersRemoved: fillers,
            estimatedTimeSaved: Self.estimateManualEditTime(footage: footage, trims: trims)
        )
        return (edl, report)
    }

    /// A person scrubs the footage about twice and spends ~20 s finding and making each cut.
    public static func estimateManualEditTime(footage: Double, trims: Int) -> Double {
        footage * 2 + Double(trims) * 20
    }

    // MARK: - Phrases

    func groupPhrases(_ words: [TaggedWord]) -> [Phrase] {
        var phrases: [Phrase] = []
        var current: [TaggedWord] = []
        for w in words {
            if let last = current.last {
                let gap = w.word.start - last.word.end
                let endsSentence = last.word.text.last.map { ".!?".contains($0) } ?? false
                if w.source != last.source || gap > options.phraseGap || endsSentence {
                    phrases.append(Phrase(words: current))
                    current = []
                }
            }
            current.append(w)
        }
        if !current.isEmpty { phrases.append(Phrase(words: current)) }
        return phrases
    }

    func removeRetakes(from input: [Phrase]) -> ([Phrase], Int) {
        var removed = 0
        // Restarts inside a phrase: "so today I'm so today I'm going to show you".
        var phrases = input.map { phrase -> Phrase in
            let (p, n) = removeInPhraseRestarts(phrase)
            removed += n
            return p
        }

        // A phrase followed shortly by another take of the same line is a failed take.
        var keep = Array(repeating: true, count: phrases.count)
        for i in phrases.indices {
            let a = phrases[i].tokens
            guard !a.isEmpty else { keep[i] = false; continue }
            let upper = min(phrases.count, i + 1 + options.retakeLookahead)
            for j in (i + 1)..<max(i + 1, upper) where keep[j] {
                if isRetake(a, of: phrases[j].tokens) {
                    keep[i] = false
                    removed += 1
                    break
                }
            }
        }
        phrases = zip(phrases, keep).filter(\.1).map(\.0)
        return (phrases, removed)
    }

    /// True when `earlier` looks like an attempt at the same line as `later`.
    func isRetake(_ earlier: [String], of later: [String]) -> Bool {
        guard !earlier.isEmpty, !later.isEmpty else { return false }
        // Compare the opening of each take; an abandoned take is usually a prefix of the good one.
        let n = min(8, max(earlier.count, 2))
        let a = Array(earlier.prefix(n))
        let b = Array(later.prefix(n + 2))
        guard a.count >= 2 || (a.count == 1 && b.first == a.first && earlier.count == 1) else { return false }
        let lcs = Self.lcsLength(a, b)
        let ratio = Double(lcs) / Double(a.count)
        // The first word must match too, otherwise two lines that merely share words would collide.
        return ratio >= options.retakeSimilarity && a.first == b.first
    }

    func removeInPhraseRestarts(_ phrase: Phrase) -> (Phrase, Int) {
        var words = phrase.words
        var removed = 0
        var changed = true
        while changed {
            changed = false
            let tokens = words.map(\.word.normalized)
            search: for n in stride(from: 5, through: 3, by: -1) where tokens.count >= n * 2 {
                for a in 0...(tokens.count - n * 2) {
                    let window = Array(tokens[a..<(a + n)])
                    let maxB = min(tokens.count - n, a + n + 6)
                    guard a + n <= maxB else { continue }
                    for b in (a + n)...maxB where Array(tokens[b..<(b + n)]) == window {
                        words.removeSubrange(a..<b)
                        removed += 1
                        changed = true
                        break search
                    }
                }
            }
        }
        return (Phrase(words: words), removed)
    }

    static func lcsLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = Array(repeating: 0, count: b.count + 1)
        for x in a {
            var cur = Array(repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j])
            }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: - Ranges

    /// Keep ranges around `words`. Ranges never reach into, or bridge across, a removed word.
    func speechRanges(_ words: [Word], removed: [Word], source: SourceAnalysis) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var lastWordEnd = -Double.infinity
        let threshold = options.silenceThreshold
        for w in words {
            var start = w.start - options.padding
            var end = w.end + options.padding
            // Recognizers often stretch word boundaries into silence; tighten padding with audio.
            if let loud = source.loudness {
                while start + 0.01 < w.start, loud.isSilent(at: start, threshold: threshold) { start += 0.01 }
                while end - 0.01 > w.end, loud.isSilent(at: end, threshold: threshold) { end -= 0.01 }
            }
            if let prev = removed.last(where: { $0.end <= w.start + 0.001 }) { start = max(start, prev.end) }
            if let next = removed.first(where: { $0.start >= w.end - 0.001 }) { end = min(end, next.start) }
            start = max(0, start)
            end = min(source.duration, end)
            guard end > start else { continue }

            let bridgesRemoved = removed.contains { $0.end > lastWordEnd && $0.start < w.start }
            if let last = ranges.last, start - last.upperBound <= options.maxPause, !bridgesRemoved {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else {
                ranges.append(start...end)
            }
            lastWordEnd = w.end
        }
        return ranges
    }

    func loudRanges(_ loudness: Loudness, duration: Double) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var runStart: Double?
        for (i, db) in loudness.decibels.enumerated() {
            let t = Double(i) * loudness.frameDuration
            if db >= options.silenceThreshold {
                if runStart == nil { runStart = t }
            } else if let s = runStart {
                ranges.append(s...t)
                runStart = nil
            }
        }
        if let s = runStart { ranges.append(s...loudness.duration) }

        var merged: [ClosedRange<Double>] = []
        for r in ranges {
            let padded = max(0, r.lowerBound - options.padding)...min(duration, r.upperBound + options.padding)
            if let last = merged.last, padded.lowerBound - last.upperBound <= options.maxPause {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, padded.upperBound)
            } else {
                merged.append(padded)
            }
        }
        return merged
    }

    /// Number of places footage was removed (gaps between kept clips plus trimmed heads/tails).
    func countTrims(clips: [Clip], sources: [SourceAnalysis]) -> Int {
        var trims = 0
        for (i, source) in sources.enumerated() {
            let mine = clips.filter { $0.sourceIndex == i }
            guard let first = mine.first, let last = mine.last else {
                if source.duration > 0 { trims += 1 }
                continue
            }
            if first.start > 0.05 { trims += 1 }
            if source.duration - last.end > 0.05 { trims += 1 }
            trims += mine.count - 1
        }
        return trims
    }
}

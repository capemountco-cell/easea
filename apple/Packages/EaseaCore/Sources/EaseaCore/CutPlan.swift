import Foundation

/// Identifies one word: its source clip and its position in that clip's word list.
public struct WordRef: Hashable, Codable, Sendable {
    public var source: Int
    public var index: Int

    public init(source: Int, index: Int) {
        self.source = source
        self.index = index
    }
}

/// An edit decided by the Claude editor: which words to remove, plus caption fixes.
/// Word numbers refer to positions in each source's `words` array as sent.
public struct CutPlan: Codable, Hashable, Sendable {
    public struct Cut: Codable, Hashable, Sendable {
        public var source: Int
        public var firstWord: Int
        public var lastWord: Int
        /// retake, false_start, filler, stumble, rambling or off_script.
        public var reason: String

        public init(source: Int, firstWord: Int, lastWord: Int, reason: String) {
            self.source = source
            self.firstWord = firstWord
            self.lastWord = lastWord
            self.reason = reason
        }
    }

    public struct Correction: Codable, Hashable, Sendable {
        public var source: Int
        public var word: Int
        public var text: String

        public init(source: Int, word: Int, text: String) {
            self.source = source
            self.word = word
            self.text = text
        }
    }

    public var cuts: [Cut]
    public var corrections: [Correction]
    public var title: String
    public var summary: String

    public init(cuts: [Cut], corrections: [Correction] = [], title: String = "", summary: String = "") {
        self.cuts = cuts
        self.corrections = corrections
        self.title = title
        self.summary = summary
    }

    /// Fixes misrecognized words (brand names, homophones) so captions read correctly.
    /// Word positions don't change, so the plan's cuts still line up.
    public func applyingCorrections(to sources: [SourceAnalysis]) -> [SourceAnalysis] {
        var result = sources
        for c in corrections where result.indices.contains(c.source) && result[c.source].words.indices.contains(c.word) {
            result[c.source].words[c.word].text = c.text
        }
        return result
    }
}

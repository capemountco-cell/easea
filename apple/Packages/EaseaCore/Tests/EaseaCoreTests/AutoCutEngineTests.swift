import XCTest
@testable import EaseaCore

/// Builds words from a script; each word lasts 0.3 s with 0.1 s between words.
/// A "|" in the script inserts a long pause (new phrase).
private func words(_ script: String, startingAt t0: Double = 0, pause: Double = 1.5) -> [Word] {
    var t = t0
    var result: [Word] = []
    for token in script.split(separator: " ") {
        if token == "|" { t += pause; continue }
        result.append(Word(text: String(token), start: t, end: t + 0.3))
        t += 0.4
    }
    return result
}

final class AutoCutEngineTests: XCTestCase {
    func testKeepsLastTakeOfRepeatedLine() {
        let w = words("hey guys today I | hey guys today I want to show you this | it is great")
        let source = SourceAnalysis(duration: (w.last?.end ?? 0) + 1, words: w)
        let (edl, report) = AutoCutEngine().makeCut(sources: [source])

        let kept = keptText(edl, [source])
        XCTAssertEqual(kept, "hey guys today I want to show you this it is great")
        XCTAssertEqual(report.retakesRemoved, 1)
        XCTAssertLessThan(report.finalDuration, report.footageDuration)
    }

    func testRemovesRestartInsidePhrase() {
        let w = words("so today I'm so today I'm going to show you")
        let source = SourceAnalysis(duration: 6, words: w)
        let (edl, _) = AutoCutEngine().makeCut(sources: [source])
        XCTAssertEqual(keptText(edl, [source]), "so today I'm going to show you")
    }

    func testDropsFillers() {
        let w = words("this um product uh rocks")
        let source = SourceAnalysis(duration: 3, words: w)
        let (edl, report) = AutoCutEngine().makeCut(sources: [source])
        XCTAssertEqual(keptText(edl, [source]), "this product rocks")
        XCTAssertEqual(report.fillersRemoved, 2)
    }

    func testDistinctLinesAreKept() {
        let w = words("first I mix it | then I drink it | it tastes great")
        let source = SourceAnalysis(duration: 10, words: w)
        let (edl, _) = AutoCutEngine().makeCut(sources: [source])
        XCTAssertEqual(keptText(edl, [source]), "first I mix it then I drink it it tastes great")
    }

    func testLongPausesAreCut() {
        let w = words("one two | three four", pause: 3)
        let source = SourceAnalysis(duration: 6, words: w)
        let (edl, report) = AutoCutEngine().makeCut(sources: [source])
        XCTAssertEqual(edl.clips.count, 2)
        XCTAssertLessThan(edl.duration, 2.5)
        XCTAssertGreaterThanOrEqual(report.trimCount, 2)
    }

    func testRetakeAcrossSessionSegments() {
        // User paused recording, then re-did the line in a second segment.
        let a = SourceAnalysis(duration: 3, words: words("check out this new"))
        let b = SourceAnalysis(duration: 4, words: words("check out this new drink mix"))
        let (edl, _) = AutoCutEngine().makeCut(sources: [a, b])
        XCTAssertTrue(edl.clips.allSatisfy { $0.sourceIndex == 1 })
    }

    func testSilentSourceFallsBackToLoudness() {
        var db = [Float](repeating: -60, count: 300)
        for i in 100..<200 { db[i] = -10 }
        let source = SourceAnalysis(duration: 3, words: [], loudness: Loudness(frameDuration: 0.01, decibels: db))
        let (edl, _) = AutoCutEngine().makeCut(sources: [source])
        XCTAssertEqual(edl.clips.count, 1)
        XCTAssertEqual(edl.clips[0].start, 0.92, accuracy: 0.02)
        XCTAssertEqual(edl.clips[0].end, 2.08, accuracy: 0.02)
    }

    func testTimelineEditing() {
        var edl = EditDecisionList(clips: [Clip(sourceIndex: 0, start: 0, end: 4), Clip(sourceIndex: 0, start: 6, end: 8)])
        XCTAssertTrue(edl.split(at: 1))
        XCTAssertEqual(edl.clips.map(\.duration), [1, 3, 2])
        edl.move(clipID: edl.clips[2].id, by: -2)
        XCTAssertEqual(edl.clips.map(\.start), [6, 0, 1])
        edl.delete(clipID: edl.clips[0].id)
        XCTAssertEqual(edl.duration, 4)
        edl.trim(clipID: edl.clips[0].id, start: -1, sourceDuration: 8)
        XCTAssertEqual(edl.clips[0].start, 0)
    }

    func testCaptionsFollowEdit() {
        let w = words("hello there friends | goodbye now")
        let source = SourceAnalysis(duration: 5, words: w)
        let captions = CaptionBuilder.build(sources: [source], maxWords: 3)
        XCTAssertEqual(captions.map(\.text), ["hello there friends", "goodbye now"])

        // Keep only the second phrase: its caption should start at output time ~0.
        let edl = EditDecisionList(clips: [Clip(sourceIndex: 0, start: captions[1].start, end: captions[1].end)])
        let timed = CaptionBuilder.layout(captions, on: edl)
        XCTAssertEqual(timed.count, 1)
        XCTAssertEqual(timed[0].text, "goodbye now")
        XCTAssertEqual(timed[0].start, 0, accuracy: 0.001)
    }

    private func keptText(_ edl: EditDecisionList, _ sources: [SourceAnalysis]) -> String {
        edl.clips.flatMap { clip in
            sources[clip.sourceIndex].words.filter { $0.start >= clip.start - 0.001 && $0.end <= clip.end + 0.001 }.map(\.text)
        }.joined(separator: " ")
    }
}

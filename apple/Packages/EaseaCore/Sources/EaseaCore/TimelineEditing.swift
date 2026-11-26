import Foundation

/// Manual refinements on top of the AI cut: split, trim, delete, reorder.
public extension EditDecisionList {
    /// Splits the clip under `outputTime` into two. Returns false if the split point is too close to an edge.
    @discardableResult
    mutating func split(at outputTime: Double, minPiece: Double = 0.1) -> Bool {
        guard let (index, sourceTime) = locate(outputTime: outputTime) else { return false }
        let clip = clips[index]
        guard sourceTime - clip.start >= minPiece, clip.end - sourceTime >= minPiece else { return false }
        var left = clip
        left.end = sourceTime
        let right = Clip(sourceIndex: clip.sourceIndex, start: sourceTime, end: clip.end)
        clips.replaceSubrange(index...index, with: [left, right])
        return true
    }

    mutating func delete(clipID: UUID) {
        clips.removeAll { $0.id == clipID }
    }

    mutating func move(clipID: UUID, by offset: Int) {
        guard let i = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let j = min(max(0, i + offset), clips.count - 1)
        guard i != j else { return }
        let clip = clips.remove(at: i)
        clips.insert(clip, at: j)
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { clips[$0] }
        var remaining = clips.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let before = source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(remaining.count, destination - before))
        clips = remaining
    }

    /// Adjusts a clip's in/out points, clamped to its source and to a minimum length.
    mutating func trim(clipID: UUID, start: Double? = nil, end: Double? = nil,
                       sourceDuration: Double, minLength: Double = 0.1) {
        guard let i = clips.firstIndex(where: { $0.id == clipID }) else { return }
        var c = clips[i]
        if let start { c.start = min(max(0, start), c.end - minLength) }
        if let end { c.end = max(min(sourceDuration, end), c.start + minLength) }
        clips[i] = c
    }
}

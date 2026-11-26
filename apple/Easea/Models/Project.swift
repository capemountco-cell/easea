import Foundation
import EaseaCore

/// A recorded or imported file belonging to a project. Files live in the project's folder.
struct SourceMedia: Codable, Hashable, Identifiable {
    var id = UUID()
    var fileName: String
    var duration: Double
}

enum CutStatus: Codable, Hashable {
    case draft
    case queued
    case processing
    case ready
    case failed(String)

    var isWorking: Bool { self == .queued || self == .processing }
}

/// sRGB color that can be saved to JSON and used by both SwiftUI and Core Animation.
struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1

    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let yellow = RGBA(r: 1, g: 0.86, b: 0.2)
    static let brand = RGBA(r: 0.29, g: 0.565, b: 0.886)
    static let presets: [RGBA] = [.white, .black, .yellow, .brand, RGBA(r: 1, g: 0.35, b: 0.4)]
}

/// Fonts that ship on both iOS and macOS, so exports look the same everywhere.
enum FontChoice: String, Codable, CaseIterable, Identifiable {
    case heavy = "AvenirNext-Heavy"
    case bold = "AvenirNext-Bold"
    case rounded = "ArialRoundedMTBold"
    case serif = "Georgia-Bold"
    case marker = "MarkerFelt-Wide"
    case mono = "Menlo-Bold"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .heavy: "Heavy"
        case .bold: "Bold"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .marker: "Marker"
        case .mono: "Mono"
        }
    }
}

struct CaptionStyle: Codable, Hashable {
    var font: FontChoice = .heavy
    /// Font size as a fraction of the video width, so it scales with resolution.
    var size: Double = 0.065
    var textColor: RGBA = .white
    var background: RGBA? = RGBA(r: 0, g: 0, b: 0, a: 0.55)
    /// Vertical center of the caption, 0 = top, 1 = bottom.
    var verticalPosition: Double = 0.72
    var uppercase = false
}

/// Free-form styled text placed on the video for a span of the output timeline.
struct TextOverlay: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var font: FontChoice = .heavy
    var size: Double = 0.08
    var color: RGBA = .white
    var background: RGBA? = nil
    /// Normalized center position (0...1).
    var x: Double = 0.5
    var y: Double = 0.2
    var start: Double = 0
    var end: Double = 3
}

enum ExportResolution: String, Codable, CaseIterable, Identifiable {
    case hd720 = "720p", hd1080 = "1080p", uhd4K = "4K"
    var id: String { rawValue }
}

struct ExportSettings: Codable, Hashable {
    var resolution: ExportResolution = .hd1080
    var hevc = true
}

struct Project: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var folder: String?
    var sources: [SourceMedia] = []

    var status: CutStatus = .draft
    var progress: Double = 0
    var progressLabel: String = ""

    /// Transcript + loudness per source; kept so re-cutting with new settings is instant.
    var analyses: [SourceAnalysis]?
    var edl: EditDecisionList?
    var report: CutReport?
    /// Whether the "time saved" card has been shown for the current cut.
    var reportSeen = false

    var captions: [Caption] = []
    var captionsEnabled = true
    var captionStyle = CaptionStyle()
    var overlays: [TextOverlay] = []

    /// Let each cut's audio bleed slightly into the next for smoother transitions.
    var overlapAudio = false
    var exportSettings = ExportSettings()

    var footageDuration: Double { sources.reduce(0) { $0 + $1.duration } }
}

import SwiftUI
import EaseaCore

/// Refine the AI's cut: trim, split, delete and reorder clips; style captions; add text; export.
struct EditorView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(CutQueue.self) private var queue

    @State var project: Project
    @State private var player = PlayerModel()
    @State private var selectedClip: UUID?
    @State private var selectedOverlay: UUID?
    @State private var panel: Panel = .edit
    @State private var undoStack: [EditDecisionList] = []
    @State private var showReport = false

    enum Panel: String, CaseIterable, Identifiable {
        case edit = "Edit", captions = "Captions", text = "Text", export = "Export"
        var id: String { rawValue }
    }

    private var urls: [URL] { store.sourceURLs(for: project) }

    var body: some View {
        Group {
            #if os(macOS)
            HSplitView {
                VStack(spacing: 0) {
                    preview.padding()
                    transport
                    timeline
                }
                .frame(minWidth: 420)
                panelArea.frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
            #else
            VStack(spacing: 0) {
                preview.padding(.horizontal).padding(.top, 8)
                transport
                timeline
                panelArea.frame(height: 290)
            }
            #endif
        }
        .background(Theme.background)
        .navigationTitle(project.title)
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Show time saved", systemImage: "stopwatch") { showReport = true }
                    Button("Re-cut with current settings", systemImage: "wand.and.stars") { recut() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear {
            player.load(project: project, sourceURLs: urls)
            if !project.reportSeen { showReport = true }
        }
        .onDisappear { player.pause() }
        .onChange(of: project) { old, new in
            store.update(new)
            if old.edl != new.edl || old.overlapAudio != new.overlapAudio {
                player.load(project: new, sourceURLs: urls)
            }
        }
        .onChange(of: store.project(project.id)?.edl) { _, edl in
            // Picks up a re-cut done by the queue.
            if let edl, edl != project.edl, let fresh = store.project(project.id) { project = fresh }
        }
        .sheet(isPresented: $showReport, onDismiss: { project.reportSeen = true }) {
            CutReadyView(project: project) { showReport = false }
                .presentationDetents([.medium])
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            PlayerLayerView(player: player.player)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                if project.captionsEnabled, let caption = activeCaption {
                    let style = project.captionStyle
                    OverlayText(text: style.uppercase ? caption.uppercased() : caption, font: style.font,
                                size: style.size * w, color: style.textColor, background: style.background, maxWidth: w * 0.86)
                        .position(x: w / 2, y: h * style.verticalPosition)
                        .allowsHitTesting(false)
                }
                ForEach($project.overlays) { $overlay in
                    if (overlay.start...max(overlay.start, overlay.end)).contains(player.currentTime) || overlay.id == selectedOverlay && panel == .text {
                        OverlayText(text: overlay.text, font: overlay.font, size: overlay.size * w, color: overlay.color,
                                    background: overlay.background, maxWidth: w * 0.86)
                            .overlay {
                                if overlay.id == selectedOverlay && panel == .text {
                                    RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                                }
                            }
                            .position(x: w * overlay.x, y: h * overlay.y)
                            .gesture(DragGesture().onChanged { value in
                                selectedOverlay = overlay.id
                                overlay.x = min(1, max(0, value.location.x / w))
                                overlay.y = min(1, max(0, value.location.y / h))
                            })
                    }
                }
            }
        }
        .aspectRatio(player.renderSize, contentMode: .fit)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture { player.togglePlay() }
        .overlay {
            if let error = player.loadError {
                Text(error).font(.caption).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var activeCaption: String? {
        guard let edl = project.edl else { return nil }
        let t = player.currentTime
        return CaptionBuilder.layout(project.captions, on: edl).first { t >= $0.start && t < $0.end }?.text
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 32)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                   in: 0...max(0.1, player.duration))
            Text("\(player.currentTime.clockString) / \(player.duration.clockString)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var timeline: some View {
        TimelineStrip(edl: project.edl ?? EditDecisionList(), urls: urls, currentTime: player.currentTime,
                      selected: $selectedClip) { player.seek(to: $0) }
            .frame(height: 76)
    }

    // MARK: - Panels

    private var panelArea: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $panel) {
                ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            ScrollView {
                Group {
                    switch panel {
                    case .edit: editPanel
                    case .captions: CaptionsPanel(project: $project)
                    case .text: TextPanel(project: $project, selected: $selectedOverlay, currentTime: player.currentTime)
                    case .export: ExportPanel(project: $project)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .background(.background.opacity(0.7))
    }

    private var editPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                tool("Split", "scissors") { editEDL { $0.split(at: player.currentTime) } }
                tool("Delete", "trash", enabled: selectedClip != nil) {
                    if let id = selectedClip { editEDL { $0.delete(clipID: id) }; selectedClip = nil }
                }
                tool("Left", "arrow.left", enabled: selectedClip != nil) {
                    if let id = selectedClip { editEDL { $0.move(clipID: id, by: -1) } }
                }
                tool("Right", "arrow.right", enabled: selectedClip != nil) {
                    if let id = selectedClip { editEDL { $0.move(clipID: id, by: 1) } }
                }
                tool("Undo", "arrow.uturn.backward", enabled: !undoStack.isEmpty) {
                    if let last = undoStack.popLast() { project.edl = last }
                }
            }
            if let id = selectedClip, let clip = project.edl?.clips.first(where: { $0.id == id }) {
                let sourceDuration = project.sources[clip.sourceIndex].duration
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trim selected clip").font(.subheadline.weight(.semibold))
                    trimRow("Start", value: clip.start) { delta in
                        editEDL { $0.trim(clipID: id, start: clip.start + delta, sourceDuration: sourceDuration) }
                    }
                    trimRow("End", value: clip.end) { delta in
                        editEDL { $0.trim(clipID: id, end: clip.end + delta, sourceDuration: sourceDuration) }
                    }
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text("Tap a clip in the timeline to trim, move or delete it. Split cuts the clip under the playhead.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let report = project.report {
                HStack {
                    Pill(text: "\(report.trimCount) trims", systemImage: "scissors")
                    Pill(text: "\(report.retakesRemoved) retakes", systemImage: "arrow.counterclockwise")
                    Pill(text: "\(report.fillersRemoved) fillers", systemImage: "text.badge.minus")
                }
            }
        }
    }

    private func tool(_ title: String, _ icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func trimRow(_ label: String, value: Double, adjust: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 44, alignment: .leading)
            Text(String(format: "%.2fs", value)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            ForEach([-0.5, -0.1, 0.1, 0.5], id: \.self) { delta in
                Button(delta > 0 ? "+\(delta.formatted())" : delta.formatted()) { adjust(delta) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func editEDL(_ change: (inout EditDecisionList) -> Void) {
        guard var edl = project.edl else { return }
        let before = edl
        change(&edl)
        guard edl != before else { return }
        undoStack.append(before)
        if undoStack.count > 50 { undoStack.removeFirst() }
        project.edl = edl
    }

    private func recut() {
        guard let before = project.edl else { return }
        undoStack.append(before)
        queue.recut(project.id)
        if let fresh = store.project(project.id) { project = fresh }
    }
}

/// Text rendered the same way the exporter draws it (font size relative to video width).
struct OverlayText: View {
    let text: String
    let font: FontChoice
    let size: Double
    let color: RGBA
    let background: RGBA?
    let maxWidth: Double

    var body: some View {
        Text(text)
            .font(.custom(font.rawValue, fixedSize: size))
            .multilineTextAlignment(.center)
            .foregroundStyle(color.color)
            .padding(.horizontal, size * 0.35)
            .padding(.vertical, size * 0.15)
            .background(background?.color ?? .clear, in: RoundedRectangle(cornerRadius: size * 0.25))
            .frame(maxWidth: maxWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Horizontal strip of clips with thumbnails and a playhead.
struct TimelineStrip: View {
    let edl: EditDecisionList
    let urls: [URL]
    let currentTime: Double
    @Binding var selected: UUID?
    var onSeek: (Double) -> Void

    private let pointsPerSecond: CGFloat = 36
    private let spacing: CGFloat = 3

    private func width(_ clip: Clip) -> CGFloat { max(28, clip.duration * pointsPerSecond) }

    var body: some View {
        let starts = edl.clipStartTimes
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .leading) {
                HStack(spacing: spacing) {
                    ForEach(Array(edl.clips.enumerated()), id: \.element.id) { index, clip in
                        ThumbnailView(url: urls.indices.contains(clip.sourceIndex) ? urls[clip.sourceIndex] : nil,
                                      seconds: clip.start + min(0.2, clip.duration / 2))
                            .frame(width: width(clip), height: 60)
                            .overlay(alignment: .bottomLeading) {
                                Text(clip.duration.formatted(.number.precision(.fractionLength(1))) + "s")
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .padding(3).shadow(radius: 2)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(selected == clip.id ? Theme.brand : .clear, lineWidth: 3))
                            .onTapGesture {
                                selected = selected == clip.id ? nil : clip.id
                                onSeek(starts[index])
                            }
                    }
                }
                Rectangle().fill(.red).frame(width: 2, height: 72)
                    .offset(x: playheadX(starts: starts))
                    .allowsHitTesting(false)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func playheadX(starts: [Double]) -> CGFloat {
        var x: CGFloat = 0
        for (clip, start) in zip(edl.clips, starts) {
            if currentTime < start + clip.duration {
                return x + CGFloat(max(0, currentTime - start) / max(clip.duration, 0.001)) * width(clip)
            }
            x += width(clip) + spacing
        }
        return max(0, x - spacing)
    }
}

import SwiftUI
import EaseaCore

struct ColorSwatches: View {
    @Binding var color: RGBA

    var body: some View {
        HStack(spacing: 10) {
            ForEach(RGBA.presets, id: \.self) { preset in
                Circle()
                    .fill(preset.color)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
                    .overlay(Circle().strokeBorder(Theme.brand, lineWidth: color == preset ? 3 : 0).padding(-4))
                    .onTapGesture { color = preset }
            }
        }
    }
}

struct FontMenu: View {
    @Binding var font: FontChoice

    var body: some View {
        Picker("Font", selection: $font) {
            ForEach(FontChoice.allCases) { choice in
                Text(choice.label).tag(choice)
            }
        }
    }
}

struct CaptionsPanel: View {
    @Binding var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Show captions", isOn: $project.captionsEnabled)
            if project.captionsEnabled {
                FontMenu(font: $project.captionStyle.font)
                LabeledContent("Size") {
                    Slider(value: $project.captionStyle.size, in: 0.035...0.12)
                }
                LabeledContent("Position") {
                    Slider(value: $project.captionStyle.verticalPosition, in: 0.1...0.92)
                }
                LabeledContent("Color") { ColorSwatches(color: $project.captionStyle.textColor) }
                Toggle("Background", isOn: Binding(
                    get: { project.captionStyle.background != nil },
                    set: { project.captionStyle.background = $0 ? RGBA(r: 0, g: 0, b: 0, a: 0.55) : nil }))
                Toggle("All caps", isOn: $project.captionStyle.uppercase)

                Divider()
                HStack {
                    Text("Wording").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Regenerate") {
                        if let analyses = project.analyses { project.captions = CaptionBuilder.build(sources: analyses) }
                    }
                    .font(.caption)
                }
                ForEach(visibleCaptionIDs, id: \.self) { id in
                    if let index = project.captions.firstIndex(where: { $0.id == id }) {
                        TextField("Caption", text: $project.captions[index].text)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    /// Only captions that survive the current edit, in playback order.
    private var visibleCaptionIDs: [UUID] {
        guard let edl = project.edl else { return [] }
        var seen = Set<UUID>()
        return CaptionBuilder.layout(project.captions, on: edl).map(\.id).filter { seen.insert($0).inserted }
    }
}

struct TextPanel: View {
    @Binding var project: Project
    @Binding var selected: UUID?
    let currentTime: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                let overlay = TextOverlay(text: "Your text", start: currentTime, end: currentTime + 3)
                project.overlays.append(overlay)
                selected = overlay.id
            } label: {
                Label("Add text", systemImage: "textformat")
            }
            .buttonStyle(.borderedProminent)

            if project.overlays.isEmpty {
                Text("Text appears from the playhead for 3 seconds. Drag it on the preview to place it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            ForEach($project.overlays) { $overlay in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(overlay.text.isEmpty ? "Text" : overlay.text).lineLimit(1).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(overlay.start.clockString)–\(overlay.end.clockString)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = selected == overlay.id ? nil : overlay.id }

                    if selected == overlay.id {
                        TextField("Text", text: $overlay.text, axis: .vertical).textFieldStyle(.roundedBorder)
                        FontMenu(font: $overlay.font)
                        LabeledContent("Size") { Slider(value: $overlay.size, in: 0.04...0.16) }
                        LabeledContent("Color") { ColorSwatches(color: $overlay.color) }
                        Toggle("Background", isOn: Binding(
                            get: { overlay.background != nil },
                            set: { overlay.background = $0 ? RGBA(r: 0, g: 0, b: 0, a: 0.55) : nil }))
                        HStack {
                            Button("Start here") { overlay.start = currentTime; overlay.end = max(overlay.end, currentTime + 0.5) }
                            Button("End here") { overlay.end = max(currentTime, overlay.start + 0.2) }
                            Spacer()
                            Button(role: .destructive) {
                                project.overlays.removeAll { $0.id == overlay.id }
                                selected = nil
                            } label: { Image(systemName: "trash") }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

struct ExportPanel: View {
    @Environment(ProjectStore.self) private var store
    @Binding var project: Project
    @State private var progress: Double?
    @State private var exportedURL: URL?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Resolution", selection: $project.exportSettings.resolution) {
                ForEach(ExportResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("HEVC (smaller files)", isOn: $project.exportSettings.hevc)
            Toggle("Overlap audio between cuts", isOn: $project.overlapAudio)

            if let progress {
                ProgressView(value: progress) { Text("Exporting…") }
            } else {
                Button { Task { await export() } } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            if let exportedURL {
                ShareLink(item: exportedURL) {
                    Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func export() async {
        progress = 0
        message = nil
        defer { progress = nil }
        do {
            let url = try await Exporter.export(project: project, sourceURLs: store.sourceURLs(for: project)) { p in
                Task { @MainActor in progress = p }
            }
            exportedURL = url
            try await PhotoLibrary.save(videoAt: url)
            message = "Saved to Photos."
        } catch is CancellationError {
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

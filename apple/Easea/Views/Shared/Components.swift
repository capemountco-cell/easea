import SwiftUI
import EaseaCore

enum Theme {
    static let brand = Color.accentColor
    static let ink = Color(red: 0.07, green: 0.1, blue: 0.16)

    /// Soft sky gradient used behind most screens.
    static var background: some View {
        LinearGradient(colors: [Color(red: 0.96, green: 0.98, blue: 1), Color(red: 0.84, green: 0.91, blue: 0.98)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// Async thumbnail for a media file.
struct ThumbnailView: View {
    let url: URL?
    var seconds: Double = 0.5
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: "\(url?.path ?? "")#\(seconds)") {
            guard let url else { return }
            image = await Thumbnails.image(for: url, at: seconds)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.brand.opacity(isEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Small rounded label used for statuses and stats.
struct Pill: View {
    let text: String
    var systemImage: String?
    var tint: Color = Theme.brand

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }
}

/// Picks or creates a folder name for organizing cuts.
struct FolderPicker: View {
    @Binding var folder: String?
    let existing: [String]
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        Menu {
            Button("None") { folder = nil }
            ForEach(existing, id: \.self) { name in
                Button(name) { folder = name }
            }
            Divider()
            Button("New Folder…", systemImage: "folder.badge.plus") { naming = true }
        } label: {
            HStack {
                Text("Folder").foregroundStyle(.primary)
                Spacer()
                Text(folder ?? "None").foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { folder = trimmed }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }
}

extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` on iOS, nothing on macOS.
    func inlineTitle() -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }
}

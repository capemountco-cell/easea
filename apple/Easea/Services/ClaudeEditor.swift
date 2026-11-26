import Foundation
import EaseaCore

/// Where the Easea backend (see `backend/`) is deployed. Overridable in the You tab.
enum AppConfig {
    /// e.g. "https://easea-cut-planner.<your-subdomain>.workers.dev". Empty = not configured.
    static let defaultPlannerURL = ""
    /// Must match the backend's EASEA_APP_TOKEN secret.
    static let defaultAppToken = ""
}

enum EditorMode: String, Codable, CaseIterable, Identifiable {
    case claude, onDevice
    var id: String { rawValue }
    var label: String { self == .claude ? "Claude" : "On-device" }
}

enum EditPace: String, Codable, CaseIterable, Identifiable {
    case tight, natural, relaxed
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ClaudeEditorError: LocalizedError {
    case notConfigured
    case server(status: Int, message: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "The Claude editor isn't set up. Add the server address in You → AI editor."
        case .server(_, let message): message
        case .badResponse: "The Claude editor sent a reply Easea couldn't read."
        }
    }
}

/// Sends the word-timed transcript (never the video) to the Easea backend, which asks Claude
/// which words to cut. The Anthropic API key lives only on the backend.
struct ClaudeEditor {
    var endpoint: URL
    var appToken: String
    var pace: EditPace

    @MainActor init?(settings: AppSettings) {
        guard settings.editorMode == .claude,
              let base = URL(string: settings.plannerURL.trimmingCharacters(in: .whitespaces)),
              base.scheme == "https" || base.host == "localhost" else { return nil }
        endpoint = base.appendingPathComponent("v1/cut-plan")
        appToken = settings.appToken
        pace = settings.pace
    }

    private struct RequestBody: Encodable {
        struct Source: Encodable {
            struct W: Encodable { let t: String; let s: Double; let e: Double }
            let duration: Double
            let words: [W]
        }
        let sources: [Source]
        let pace: String
        let removeFillers: Bool
        let removeRetakes: Bool
    }

    private struct ErrorBody: Decodable { let error: String }

    func plan(sources: [SourceAnalysis], options: CutOptions) async throws -> CutPlan {
        let body = RequestBody(
            sources: sources.map { src in
                .init(duration: src.duration, words: src.words.map {
                    .init(t: $0.text, s: ($0.start * 1000).rounded() / 1000, e: ($0.end * 1000).rounded() / 1000)
                })
            },
            pace: pace.rawValue,
            removeFillers: options.removeFillers,
            removeRetakes: options.removeRetakes
        )
        var request = URLRequest(url: endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !appToken.isEmpty { request.setValue(appToken, forHTTPHeaderField: "X-Easea-Token") }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeEditorError.badResponse }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Server error \(http.statusCode)"
            throw ClaudeEditorError.server(status: http.statusCode, message: message)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let plan = try? decoder.decode(CutPlan.self, from: data) else { throw ClaudeEditorError.badResponse }
        return plan
    }
}

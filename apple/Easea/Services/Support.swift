import Foundation
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers
import UserNotifications
import Observation
import SwiftUI
import EaseaCore

/// User-tunable cut settings, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    var cutOptions: CutOptions {
        didSet { save() }
    }
    var defaultOverlapAudio: Bool {
        didSet { UserDefaults.standard.set(defaultOverlapAudio, forKey: "defaultOverlapAudio") }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "cutOptions"),
           let options = try? JSONDecoder().decode(CutOptions.self, from: data) {
            cutOptions = options
        } else {
            cutOptions = CutOptions()
        }
        defaultOverlapAudio = UserDefaults.standard.bool(forKey: "defaultOverlapAudio")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cutOptions) {
            UserDefaults.standard.set(data, forKey: "cutOptions")
        }
    }
}

/// Local notifications for "your cut is ready" — no push server needed for on-device processing.
enum Notifications {
    static let projectKey = "projectID"

    @discardableResult
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func send(title: String, body: String, projectID: UUID?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let projectID { content.userInfo = [projectKey: projectID.uuidString] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Shows banners while the app is open and routes taps to the right project.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    var onOpenProject: ((UUID) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo[Notifications.projectKey] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { onOpenProject?(id) }
    }
}

/// A video handed over by PhotosPicker, copied to a temporary file we own.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

enum Thumbnails {
    private static let cache = NSCache<NSString, CGImageWrapper>()
    final class CGImageWrapper { let image: CGImage; init(_ i: CGImage) { image = i } }

    static func image(for url: URL, at seconds: Double = 0.5, maxSize: CGFloat = 480) async -> CGImage? {
        let key = "\(url.path)#\(seconds)" as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        guard let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        cache.setObject(CGImageWrapper(result.image), forKey: key)
        return result.image
    }
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

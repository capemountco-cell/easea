import Foundation
import AVFoundation
import Observation
import SwiftUI

/// Records takes into separate files. Pausing ends a take; recording again adds another
/// take to the same session, and all takes are cut together as one video.
@MainActor
@Observable
final class CameraController: NSObject {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "easea.camera")
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false

    private(set) var isRecording = false
    private(set) var takes: [URL] = []
    private(set) var recordedSeconds: Double = 0
    private(set) var takeStartedAt: Date?
    private(set) var permissionDenied = false
    var errorMessage: String?
    var limit: Double = 60
    #if os(iOS)
    private(set) var position: AVCaptureDevice.Position = .front
    #endif

    func elapsed(at date: Date) -> Double {
        recordedSeconds + (takeStartedAt.map { date.timeIntervalSince($0) } ?? 0)
    }

    var remaining: Double { max(0, limit - recordedSeconds) }

    func start() async {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        guard video && audio else { permissionDenied = true; return }
        if !configured { configure() }
        let session = session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        #if os(iOS)
        session.sessionPreset = .high
        #endif
        if let device = Self.camera(position: currentPosition), let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        if let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        applyConnectionSettings()
    }

    private var currentPosition: AVCaptureDevice.Position {
        #if os(iOS)
        return position
        #else
        return .unspecified
        #endif
    }

    private static func camera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        #if os(iOS)
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        #else
        return AVCaptureDevice.default(for: .video)
        #endif
    }

    private func applyConnectionSettings() {
        guard let connection = output.connection(with: .video) else { return }
        #if os(iOS)
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }
        #endif
    }

    #if os(iOS)
    func flipCamera() {
        guard !isRecording else { return }
        position = position == .front ? .back : .front
        session.beginConfiguration()
        if let old = videoInput { session.removeInput(old) }
        if let device = Self.camera(position: position), let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        session.commitConfiguration()
        applyConnectionSettings()
    }
    #endif

    func toggleRecording() {
        isRecording ? stopTake() : startTake()
    }

    private func startTake() {
        guard remaining > 0.5 else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).mov")
        output.maxRecordedDuration = CMTime(seconds: remaining, preferredTimescale: 600)
        output.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        takeStartedAt = .now
    }

    private func stopTake() {
        output.stopRecording()
    }

    func discardAll() {
        for url in takes { try? FileManager.default.removeItem(at: url) }
        takes = []
        recordedSeconds = 0
    }

    /// Hands recorded takes to the caller, who takes ownership of the files.
    func collectTakes() -> [URL] {
        defer { takes = []; recordedSeconds = 0 }
        return takes
    }

    fileprivate func finished(url: URL, error: Error?) {
        isRecording = false
        let started = takeStartedAt
        takeStartedAt = nil
        let ns = error as NSError?
        let ok = error == nil || (ns?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        guard ok else {
            errorMessage = error?.localizedDescription
            try? FileManager.default.removeItem(at: url)
            return
        }
        takes.append(url)
        recordedSeconds += started.map { Date.now.timeIntervalSince($0) } ?? 0
        recordedSeconds = min(recordedSeconds, limit)
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.finished(url: outputFileURL, error: error) }
    }
}

// MARK: - Preview

#if os(iOS)
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}
#else
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif

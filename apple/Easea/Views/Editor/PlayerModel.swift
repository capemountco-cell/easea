import SwiftUI
import AVFoundation
import AVKit
import Observation

/// Plays the current edit. Rebuilt whenever the timeline changes.
@MainActor
@Observable
final class PlayerModel {
    let player = AVPlayer()
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var renderSize = CGSize(width: 1080, height: 1920)
    private(set) var loadError: String?
    private var observer: Any?
    private var buildTask: Task<Void, Never>?
    /// Source files behind the current item; tracks stop working if these are released.
    private var retainedAssets: [AVURLAsset] = []

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    func load(project: Project, sourceURLs: [URL]) {
        buildTask?.cancel()
        buildTask = Task {
            do {
                let plan = try await VideoRenderer.makePlan(project: project, sourceURLs: sourceURLs)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: plan.composition.copy() as! AVAsset)
                item.videoComposition = plan.videoComposition
                item.audioMix = plan.audioMix
                let resumeAt = currentTime
                let wasPlaying = isPlaying
                retainedAssets = plan.sourceAssets
                player.replaceCurrentItem(with: item)
                renderSize = plan.renderSize
                duration = plan.composition.duration.seconds
                loadError = nil
                seek(to: min(resumeAt, max(0, duration - 0.05)))
                if wasPlaying { player.play() }
            } catch {
                print("Couldn't build preview: \(error)")
                loadError = "This video couldn't be loaded. Try Rebuild from the ••• menu."
            }
        }
    }

    func togglePlay() {
        if player.rate == 0 {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        } else {
            player.pause()
        }
        isPlaying = player.rate != 0
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// Bare AVPlayerLayer, so overlays can be laid out in exact video coordinates.
#if os(iOS)
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class View: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> View {
        let view = View()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: View, context: Context) {}
}
#else
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif

/// Simple full-screen player for watching a raw clip.
struct PreviewPlayer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
                .onAppear { player = AVPlayer(url: url); player?.play() }
                .onDisappear { player?.pause() }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 640)
        #endif
    }
}

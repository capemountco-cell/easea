import Foundation
import AVFoundation
import QuartzCore
import CoreText
import EaseaCore

/// Turns a project's edit decisions into an AVComposition for preview and export.
enum VideoRenderer {
    struct Plan {
        var composition: AVMutableComposition
        var videoComposition: AVMutableVideoComposition
        var audioMix: AVMutableAudioMix
        var renderSize: CGSize
    }

    /// How far each clip's audio runs into the next when "overlap audio" is on.
    static let audioOverlap = 0.12

    static func makePlan(project: Project, sourceURLs: [URL]) async throws -> Plan {
        guard let edl = project.edl, !edl.clips.isEmpty else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Nothing to render yet."])
        }

        struct Source {
            var video: AVAssetTrack?
            var audio: AVAssetTrack?
            /// Where each track actually has media. Often shorter than the file, by a few frames.
            var videoRange: CMTimeRange = .invalid
            var audioRange: CMTimeRange = .invalid
            var transform: CGAffineTransform
            var size: CGSize
            var duration: Double
            var fps: Float
        }
        var sources: [Source] = []
        for url in sourceURLs {
            let asset = AVURLAsset(url: url)
            let video = try await asset.loadTracks(withMediaType: .video).first
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let duration = try await asset.load(.duration).seconds
            var transform = CGAffineTransform.identity
            var size = CGSize(width: 1080, height: 1920)
            var fps: Float = 30
            if let video {
                let (natural, preferred, rate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                transform = preferred
                size = natural
                fps = rate > 0 ? rate : 30
            }
            var source = Source(video: video, audio: audio, transform: transform, size: size, duration: duration, fps: fps)
            if let video { source.videoRange = try await video.load(.timeRange) }
            if let audio { source.audioRange = try await audio.load(.timeRange) }
            sources.append(source)
        }

        // Output size follows the first clip's (rotated) orientation.
        let first = sources[edl.clips[0].sourceIndex]
        let rotated = CGRect(origin: .zero, size: first.size).applying(first.transform)
        let renderSize = CGSize(width: abs(rotated.width).rounded(), height: abs(rotated.height).rounded())

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Two audio tracks alternate so neighboring clips' audio can overlap and crossfade.
        let audioTracks = [
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
        ].compactMap { $0 }
        let mixParams = audioTracks.map { AVMutableAudioMixInputParameters(track: $0) }

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        let overlap = project.overlapAudio ? audioOverlap : 0
        var cursor = CMTime.zero
        let timescale: CMTimeScale = 600

        for (i, clip) in edl.clips.enumerated() {
            let src = sources[clip.sourceIndex]
            let start = CMTime(seconds: clip.start, preferredTimescale: timescale)
            let duration = CMTime(seconds: clip.duration, preferredTimescale: timescale)

            if let video = src.video {
                try insert(CMTimeRange(start: start, duration: duration), of: video, available: src.videoRange,
                           into: videoTrack, at: cursor)
                layer.setTransform(fitTransform(src.transform, natural: src.size, into: renderSize), at: cursor)
            } else {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration))
            }

            if let audio = src.audio, !audioTracks.isEmpty {
                let t = i % audioTracks.count
                let isLast = i == edl.clips.count - 1
                let tail = isLast ? 0 : min(overlap, max(0, src.duration - clip.end))
                let range = CMTimeRange(start: start, duration: CMTime(seconds: clip.duration + tail, preferredTimescale: timescale))
                try insert(range, of: audio, available: src.audioRange, into: audioTracks[t], at: cursor,
                           padToFullLength: false)
                if tail > 0 {
                    let fade = CMTimeRange(start: cursor + duration, duration: CMTime(seconds: tail, preferredTimescale: timescale))
                    mixParams[t].setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: fade)
                    // Fade the next clip in under the tail.
                    let next = mixParams[(t + 1) % mixParams.count]
                    next.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: fade)
                }
            }
            cursor = cursor + duration
        }

        guard cursor > .zero else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This video couldn't be loaded."])
        }
        let instruction = AVMutableVideoCompositionInstruction()
        // Must cover the whole composition, or playback and export fail.
        instruction.timeRange = CMTimeRange(start: .zero, duration: max(cursor, composition.duration))
        instruction.layerInstructions = [layer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(first.fps.rounded()))
        videoComposition.instructions = [instruction]

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParams
        return Plan(composition: composition, videoComposition: videoComposition, audioMix: audioMix, renderSize: renderSize)
    }

    /// Inserts `range` of a source track, clipped to where that track has media.
    /// Asking for time past a track's end throws, and phone videos often have a video track
    /// a few frames shorter than the file. With `padToFullLength`, any missing part is filled
    /// with an empty segment so following clips stay in sync.
    static func insert(_ range: CMTimeRange, of track: AVAssetTrack, available: CMTimeRange,
                       into target: AVMutableCompositionTrack, at time: CMTime, padToFullLength: Bool = true) throws {
        let usable = available.isValid ? range.intersection(available) : range
        let lead = usable.isEmpty ? range.duration : max(.zero, usable.start - range.start)
        if padToFullLength, lead > .zero {
            target.insertEmptyTimeRange(CMTimeRange(start: time, duration: lead))
        }
        if !usable.isEmpty, usable.duration > .zero {
            try target.insertTimeRange(usable, of: track, at: time + (padToFullLength ? lead : usable.start - range.start))
        }
        let filled = (padToFullLength ? lead : .zero) + (usable.isEmpty ? .zero : usable.duration)
        if padToFullLength, filled < range.duration {
            target.insertEmptyTimeRange(CMTimeRange(start: time + filled, duration: range.duration - filled))
        }
    }

    /// Rotates a track upright and fits it inside the render area.
    static func fitTransform(_ preferred: CGAffineTransform, natural: CGSize, into render: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let upright = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let scale = min(render.width / rect.width, render.height / rect.height)
        let tx = (render.width - rect.width * scale) / 2
        let ty = (render.height - rect.height * scale) / 2
        return upright
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    // MARK: - Burned-in text for export

    /// Adds captions and text overlays as Core Animation layers rendered into the video.
    static func addTextLayers(to plan: Plan, project: Project) {
        let size = plan.renderSize
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.isGeometryFlipped = true // top-left origin, matching SwiftUI's preview
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        if project.captionsEnabled, let edl = project.edl {
            let style = project.captionStyle
            for item in CaptionBuilder.layout(project.captions, on: edl) {
                let text = style.uppercase ? item.text.uppercased() : item.text
                let layer = textLayer(text, font: style.font, size: style.size * size.width, color: style.textColor,
                                      background: style.background, center: CGPoint(x: 0.5, y: style.verticalPosition),
                                      in: size)
                show(layer, from: item.start, to: item.end)
                parent.addSublayer(layer)
            }
        }
        for overlay in project.overlays {
            let layer = textLayer(overlay.text, font: overlay.font, size: overlay.size * size.width, color: overlay.color,
                                  background: overlay.background, center: CGPoint(x: overlay.x, y: overlay.y), in: size)
            show(layer, from: overlay.start, to: overlay.end)
            parent.addSublayer(layer)
        }

        plan.videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    /// A rounded background pill containing centered, wrapped text.
    private static func textLayer(_ text: String, font: FontChoice, size: Double, color: RGBA, background: RGBA?,
                                  center: CGPoint, in canvas: CGSize) -> CALayer {
        let ctFont = CTFontCreateWithName(font.rawValue as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: canvas.width * 0.86, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(fit.width) + 2, height: ceil(fit.height))
        let padH = size * 0.35, padV = size * 0.15

        let container = CALayer()
        container.bounds = CGRect(x: 0, y: 0, width: textSize.width + padH * 2, height: textSize.height + padV * 2)
        container.position = CGPoint(x: center.x * canvas.width, y: center.y * canvas.height)
        container.backgroundColor = background?.cgColor
        container.cornerRadius = size * 0.25

        let label = CATextLayer()
        label.string = attributed
        label.isWrapped = true
        label.alignmentMode = .center
        label.contentsScale = 1
        label.frame = CGRect(origin: CGPoint(x: padH, y: padV), size: textSize)
        container.addSublayer(label)
        return container
    }

    /// Hidden by default, visible between `start` and `end` of the output timeline.
    private static func show(_ layer: CALayer, from start: Double, to end: Double) {
        layer.opacity = 0
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 1
        animation.beginTime = start <= 0 ? AVCoreAnimationBeginTimeAtZero : start
        animation.duration = max(0.05, end - max(0, start))
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "visible")
    }
}

extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

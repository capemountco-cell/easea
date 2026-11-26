import XCTest
import AVFoundation
import EaseaCore

/// Builds real video files on macOS and checks that edits play and export, including the
/// phone-video case where the video track ends before the file does.
final class VideoRendererTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    /// Portrait clip like an iPhone's: landscape pixels plus a 90° rotation,
    /// with audio that runs `audioExtra` seconds past the last video frame.
    private func makeSourceVideo(videoSeconds: Double = 2.0, audioExtra: Double = 0.25) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("render-test-\(UUID().uuidString).mov")
        tempFiles.append(url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        video.transform = CGAffineTransform(rotationAngle: .pi / 2)
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        let frameCount = Int(videoSeconds * Double(fps))
        let sampleRate = 44_100
        let chunk = 4_410
        let audioChunks = Int(((videoSeconds + audioExtra) * Double(sampleRate)) / Double(chunk))
        var frame = 0, audioIndex = 0

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

        let deadline = Date().addingTimeInterval(30)
        while frame < frameCount || audioIndex < audioChunks {
            XCTAssertLessThan(Date(), deadline, "Timed out writing the test video")
            if Date() > deadline { break }
            let videoTime = Double(frame) / Double(fps)
            let audioTime = Double(audioIndex * chunk) / Double(sampleRate)
            let writeVideo = frame < frameCount && (audioIndex >= audioChunks || videoTime <= audioTime)
            if writeVideo {
                guard video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { usleep(1_000); continue }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { XCTFail("No pixel buffer"); break }
                CVPixelBufferLockBaseAddress(buffer, [])
                memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 4 % 255), CVPixelBufferGetDataSize(buffer))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                frame += 1
            } else {
                guard audio.isReadyForMoreMediaData, let format else { usleep(1_000); continue }
                let bytes = chunk * 2
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                   flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                guard let block else { XCTFail("No block buffer"); break }
                CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: chunk,
                    presentationTimeStamp: CMTime(value: CMTimeValue(audioIndex * chunk), timescale: CMTimeScale(sampleRate)),
                    packetDescriptions: nil, sampleBufferOut: &sample)
                guard let sample else { XCTFail("No audio sample"); break }
                audio.append(sample)
                audioIndex += 1
            }
        }
        video.markAsFinished()
        audio.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    private func project(clips: [Clip], sourceDuration: Double, overlap: Bool) -> Project {
        var p = Project(title: "Test")
        p.sources = [SourceMedia(fileName: "x.mov", duration: sourceDuration)]
        p.edl = EditDecisionList(clips: clips)
        p.overlapAudio = overlap
        p.captions = [Caption(sourceIndex: 0, start: 0.0, end: 0.5, text: "Hello there")]
        p.overlays = [TextOverlay(text: "Title", start: 0, end: 1)]
        return p
    }

    /// The clip runs to the end of the file, past the last video frame (the bug seen on device).
    private func phoneLikeClips(fileDuration: Double) -> [Clip] {
        [
            Clip(sourceIndex: 0, start: 1.0, end: fileDuration),
            Clip(sourceIndex: 0, start: 0.0, end: 0.5),
            Clip(sourceIndex: 0, start: 0.6, end: 0.9),
        ]
    }

    func testPlanForClipPastVideoTrackEnd() async throws {
        let url = try await makeSourceVideo()
        let fileDuration = try await AVURLAsset(url: url).load(.duration).seconds
        let clips = phoneLikeClips(fileDuration: fileDuration)
        let plan = try await VideoRenderer.makePlan(project: project(clips: clips, sourceDuration: fileDuration, overlap: false),
                                                    sourceURLs: [url])
        XCTAssertEqual(plan.renderSize, CGSize(width: 180, height: 320), "Portrait output")
        let expected = clips.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(plan.composition.duration.seconds, expected, accuracy: 0.05)
    }

    @MainActor
    func testPreviewBecomesReadyToPlay() async throws {
        let url = try await makeSourceVideo()
        let fileDuration = try await AVURLAsset(url: url).load(.duration).seconds
        let plan = try await VideoRenderer.makePlan(
            project: project(clips: phoneLikeClips(fileDuration: fileDuration), sourceDuration: fileDuration, overlap: true),
            sourceURLs: [url])
        let item = AVPlayerItem(asset: plan.composition.copy() as! AVAsset)
        item.videoComposition = plan.videoComposition
        item.audioMix = plan.audioMix
        let player = AVPlayer(playerItem: item)
        for _ in 0..<100 where item.status == .unknown {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(item.status, .readyToPlay, "Player item failed: \(String(describing: item.error))")
        _ = player
    }

    func testExportWithCaptionsAndOverlap() async throws {
        let url = try await makeSourceVideo()
        let fileDuration = try await AVURLAsset(url: url).load(.duration).seconds
        let clips = phoneLikeClips(fileDuration: fileDuration)
        var p = project(clips: clips, sourceDuration: fileDuration, overlap: true)
        p.exportSettings = ExportSettings(resolution: .hd720, hevc: false)
        let output = try await Exporter.export(project: p, sourceURLs: [url]) { _ in }
        tempFiles.append(output)
        let exported = AVURLAsset(url: output)
        let duration = try await exported.load(.duration).seconds
        XCTAssertEqual(duration, clips.reduce(0) { $0 + $1.duration }, accuracy: 0.2)
        let videoTracks = try await exported.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
    }
}

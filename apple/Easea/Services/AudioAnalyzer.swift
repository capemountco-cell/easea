import Foundation
import AVFoundation
import EaseaCore

enum AudioAnalyzer {
    /// Exports a media file's audio to an .m4a, which the speech recognizer reads reliably.
    static func extractAudio(from url: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This video has no audio track."])
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .m4a
        await session.export()
        if let error = session.error { throw error }
    }

    /// Measures loudness (dBFS) in 10 ms windows.
    static func loudness(of url: URL, frameDuration: Double = 0.01) async throws -> Loudness {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return Loudness(frameDuration: frameDuration, decibels: [])
        }
        let sampleRate = 16_000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        let window = Int(sampleRate * frameDuration)
        var decibels: [Float] = []
        var sumSquares: Float = 0
        var count = 0

        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            for s in samples {
                sumSquares += s * s
                count += 1
                if count == window {
                    decibels.append(Self.db(sumSquares / Float(count)))
                    sumSquares = 0
                    count = 0
                }
            }
        }
        if count > 0 { decibels.append(Self.db(sumSquares / Float(count))) }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return Loudness(frameDuration: frameDuration, decibels: decibels)
    }

    private static func db(_ meanSquare: Float) -> Float {
        20 * log10(max(sqrt(meanSquare), 1e-7))
    }
}

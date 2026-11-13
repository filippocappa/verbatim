import AVFoundation

/// Any audio or video file as 16 kHz mono samples, the format everything else here works in.
nonisolated enum AudioFile {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// All the sound tracks mixed into one. A video's picture is ignored.
    static func load16k(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure(errorDescription: "There's no sound in this file.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure(errorDescription: "Couldn't read this file.") }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        if reader.status == .failed { throw reader.error ?? Failure(errorDescription: "Couldn't read this file.") }
        return samples
    }

    /// When it was recorded, if the file says; otherwise when the file was made.
    static func recordedAt(_ url: URL) async -> Date {
        if let item = try? await AVURLAsset(url: url).load(.creationDate), let date = try? await item.load(.dateValue) {
            return date
        }
        return (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
    }
}

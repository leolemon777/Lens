@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum TimelineWaveformSampler {
    static func peaks(from url: URL, bucketCount: Int = 240) async -> [Float] {
        let buckets = max(bucketCount, 8)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            return []
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            LensFailureLog.record("timeline.waveform_reader_failed", error: error)
            return []
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var peaks = Array(repeating: Float(0), count: buckets)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let safeDuration = max(duration.isFinite ? duration : 0, 0.001)
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return []
            }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 2 else { continue }
            var data = Data(count: length)
            let copyOK = data.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: length,
                    destination: base
                ) == noErr
            }
            guard copyOK else { continue }
            let time = sampleBuffer.presentationTimeStamp.seconds
            let bucket = min(
                max(Int((time / safeDuration) * Double(buckets)), 0),
                buckets - 1
            )
            data.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                var loudest: Int32 = 0
                for sample in samples {
                    loudest = max(loudest, Int32(abs(Int(sample))))
                }
                let normalized = Float(loudest) / Float(Int16.max)
                if normalized > peaks[bucket] {
                    peaks[bucket] = normalized
                }
            }
        }
        return peaks
    }
}

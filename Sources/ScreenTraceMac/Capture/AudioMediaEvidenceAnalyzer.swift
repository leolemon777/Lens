@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

struct AudioMediaEvidence: Sendable {
    let durationSeconds: Double
    let sampleRate: Double
    let channelCount: Int
    let rootMeanSquare: Double
    let peakAmplitude: Double
    let windowRootMeanSquares: [Double]
    let samples: [Float]

    var minimumWindowRootMeanSquare: Double {
        windowRootMeanSquares.min() ?? 0
    }
}

enum DistributedMediaEvidenceSampling {
    static func sampleCount(for durationSeconds: Double, shortCount: Int) -> Int {
        if durationSeconds >= 1_800 {
            return 24
        }
        if durationSeconds >= 300 {
            return 12
        }
        return shortCount
    }
}

enum AudioMediaEvidenceAnalyzer {
    /// Decodes short, evenly distributed PCM windows. This keeps verification
    /// bounded for hour-long recordings while still sampling the beginning,
    /// middle and end rather than trusting container metadata alone.
    static func analyze(url: URL) async -> AudioMediaEvidence? {
        await Task.detached(priority: .utility) {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    return nil
                }
                let timeRange = try await track.load(.timeRange)
                let duration = timeRange.duration.seconds
                guard duration.isFinite, duration > 0 else { return nil }
                let formatDescriptions = try await track.load(.formatDescriptions)
                let streamDescription = formatDescriptions.first.flatMap {
                    CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
                }
                let sampleRate = streamDescription?.mSampleRate ?? 48_000
                let channelCount = max(Int(streamDescription?.mChannelsPerFrame ?? 1), 1)
                let windowDuration = min(max(duration / 8, 0.35), 1.25)
                let maximumStart = max(duration - windowDuration, 0)
                let sampleCount = DistributedMediaEvidenceSampling.sampleCount(
                    for: duration,
                    shortCount: 5
                )
                let starts = (0..<sampleCount).map { index in
                    let progress = sampleCount == 1
                        ? 0.5
                        : Double(index) / Double(sampleCount - 1)
                    return maximumStart * progress
                }
                var samples: [Float] = []
                samples.reserveCapacity(
                    Int(sampleRate * windowDuration * Double(starts.count))
                        * channelCount
                )
                var windowRootMeanSquares: [Double] = []
                for start in starts {
                    try Task.checkCancellation()
                    let windowSamples = try await decodeWindow(
                        asset: asset,
                        track: track,
                        startSeconds: start,
                        durationSeconds: windowDuration
                    )
                    guard !windowSamples.isEmpty else { return nil }
                    windowRootMeanSquares.append(rootMeanSquare(of: windowSamples))
                    samples.append(contentsOf: windowSamples)
                }
                guard !samples.isEmpty else { return nil }
                var sumSquares = 0.0
                var peak = 0.0
                for sample in samples {
                    let value = Double(sample)
                    sumSquares += value * value
                    peak = max(peak, abs(value))
                }
                return AudioMediaEvidence(
                    durationSeconds: duration,
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    rootMeanSquare: sqrt(sumSquares / Double(samples.count)),
                    peakAmplitude: peak,
                    windowRootMeanSquares: windowRootMeanSquares,
                    samples: samples
                )
            } catch {
                return nil
            }
        }.value
    }

    static func meanAbsoluteDifference(
        _ first: [Float],
        _ second: [Float]
    ) -> Double? {
        let count = min(first.count, second.count)
        guard count > 0 else { return nil }
        var difference = 0.0
        for index in 0..<count {
            difference += abs(Double(first[index]) - Double(second[index]))
        }
        return difference / Double(count)
    }

    private static func rootMeanSquare(of samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(into: 0.0) { partialResult, sample in
            let value = Double(sample)
            partialResult += value * value
        }
        return sqrt(sum / Double(samples.count))
    }

    private static func decodeWindow(
        asset: AVAsset,
        track: AVAssetTrack,
        startSeconds: Double,
        durationSeconds: Double
    ) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 48_000),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 48_000)
        )
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(
                domain: "ScreenTrace.AudioMediaEvidence",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建音频验证读取器。"]
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "ScreenTrace.AudioMediaEvidence",
                code: 2
            )
        }
        var result: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount >= MemoryLayout<Int16>.size else { continue }
            var bytes = [UInt8](repeating: 0, count: byteCount)
            let status = bytes.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: destination.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else { continue }
            bytes.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Int16.self)
                result.reserveCapacity(result.count + values.count)
                for value in values {
                    result.append(Float(value) / Float(Int16.max))
                }
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? NSError(
                domain: "ScreenTrace.AudioMediaEvidence",
                code: 3
            )
        }
        return result
    }
}

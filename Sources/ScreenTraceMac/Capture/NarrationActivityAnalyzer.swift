import AVFoundation
import Foundation

struct NarrationActivityRange: Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double

    init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = max(0, startSeconds)
        self.endSeconds = max(self.startSeconds, endSeconds)
    }
}

enum NarrationActivityAnalyzerError: LocalizedError {
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedAudioFormat: "麦克风轨道的采样格式暂不支持自动旁白检测。"
        }
    }
}

final class NarrationActivityAnalyzer: @unchecked Sendable {
    func analyze(
        url: URL,
        thresholdDecibels: Double,
        windowSeconds: Double = 0.08
    ) throws -> [NarrationActivityRange] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0,
              format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else {
            throw NarrationActivityAnalyzerError.unsupportedAudioFormat
        }
        let windowFrames = AVAudioFrameCount(max(1, Int(format.sampleRate * windowSeconds)))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: windowFrames
        ) else {
            throw NarrationActivityAnalyzerError.unsupportedAudioFormat
        }

        var rawRanges: [NarrationActivityRange] = []
        var frameOffset: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frames = AVAudioFrameCount(min(Int64(windowFrames), remaining))
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0,
                  let channels = buffer.floatChannelData else { break }
            var energy: Double = 0
            let sampleCount = Int(buffer.frameLength)
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for index in 0..<sampleCount {
                    let value = Double(samples[index])
                    energy += value * value
                }
            }
            let divisor = Double(max(sampleCount * Int(format.channelCount), 1))
            let rms = sqrt(energy / divisor)
            let decibels = 20 * log10(max(rms, 1e-9))
            if decibels >= thresholdDecibels {
                rawRanges.append(NarrationActivityRange(
                    startSeconds: Double(frameOffset) / format.sampleRate,
                    endSeconds: Double(frameOffset + AVAudioFramePosition(buffer.frameLength))
                        / format.sampleRate
                ))
            }
            frameOffset += AVAudioFramePosition(buffer.frameLength)
        }
        return Self.merge(rawRanges, maximumGap: max(windowSeconds * 1.5, 0.02))
    }

    static func merge(
        _ ranges: [NarrationActivityRange],
        maximumGap: Double
    ) -> [NarrationActivityRange] {
        let sorted = ranges.sorted { lhs, rhs in
            lhs.startSeconds == rhs.startSeconds
                ? lhs.endSeconds < rhs.endSeconds
                : lhs.startSeconds < rhs.startSeconds
        }
        guard var current = sorted.first else { return [] }
        var result: [NarrationActivityRange] = []
        for range in sorted.dropFirst() {
            if range.startSeconds <= current.endSeconds + max(0, maximumGap) {
                current = NarrationActivityRange(
                    startSeconds: current.startSeconds,
                    endSeconds: max(current.endSeconds, range.endSeconds)
                )
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }
}

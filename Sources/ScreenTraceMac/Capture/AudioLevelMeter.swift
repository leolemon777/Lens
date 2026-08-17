import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLevel: Double = 0

    var level: Double {
        lock.withLock { storedLevel }
    }

    func reset() {
        lock.withLock { storedLevel = 0 }
    }

    func update(buffer: AVAudioPCMBuffer) {
        guard let rms = Self.rootMeanSquare(buffer: buffer) else { return }
        update(rootMeanSquare: rms)
    }

    func update(sampleBuffer: CMSampleBuffer) {
        guard let buffer = try? AudioSampleBufferPCMConverter.convert(sampleBuffer) else {
            return
        }
        update(buffer: buffer)
    }

    func update(rootMeanSquare: Double) {
        let decibels = 20 * log10(max(rootMeanSquare, 1e-9))
        let normalized = min(max((decibels + 60) / 60, 0), 1)
        let visualLevel = sqrt(normalized)
        lock.withLock {
            let response = visualLevel >= storedLevel ? 0.62 : 0.16
            storedLevel += (visualLevel - storedLevel) * response
        }
    }

    private static func rootMeanSquare(buffer: AVAudioPCMBuffer) -> Double? {
        guard buffer.frameLength > 0, buffer.format.channelCount > 0 else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let logicalSamplesPerBuffer = buffer.format.isInterleaved
            ? Int(buffer.frameLength) * Int(buffer.format.channelCount)
            : Int(buffer.frameLength)
        var energy: Double = 0
        var sampleCount = 0
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            for audioBuffer in buffers {
                guard let data = audioBuffer.mData else { continue }
                let count = min(
                    Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.stride,
                    logicalSamplesPerBuffer
                )
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    let sample = Double(samples[index])
                    energy += sample * sample
                }
                sampleCount += count
            }
        case .pcmFormatInt16:
            for audioBuffer in buffers {
                guard let data = audioBuffer.mData else { continue }
                let count = min(
                    Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.stride,
                    logicalSamplesPerBuffer
                )
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let sample = Double(samples[index]) / Double(Int16.max)
                    energy += sample * sample
                }
                sampleCount += count
            }
        case .pcmFormatInt32:
            for audioBuffer in buffers {
                guard let data = audioBuffer.mData else { continue }
                let count = min(
                    Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.stride,
                    logicalSamplesPerBuffer
                )
                let samples = data.assumingMemoryBound(to: Int32.self)
                for index in 0..<count {
                    let sample = Double(samples[index]) / Double(Int32.max)
                    energy += sample * sample
                }
                sampleCount += count
            }
        case .pcmFormatFloat64:
            for audioBuffer in buffers {
                guard let data = audioBuffer.mData else { continue }
                let count = min(
                    Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.stride,
                    logicalSamplesPerBuffer
                )
                let samples = data.assumingMemoryBound(to: Double.self)
                for index in 0..<count {
                    let sample = samples[index]
                    energy += sample * sample
                }
                sampleCount += count
            }
        case .otherFormat:
            return nil
        @unknown default:
            return nil
        }
        guard sampleCount > 0 else { return nil }
        return sqrt(energy / Double(sampleCount))
    }
}

final class SystemAudioLevelMonitor: NSObject, SCStreamOutput, @unchecked Sendable {
    static let queue = DispatchQueue(
        label: "app.screentrace.system-audio-meter",
        qos: .userInteractive
    )
    private let meter: AudioLevelMeter

    init(meter: AudioLevelMeter) {
        self.meter = meter
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        meter.update(sampleBuffer: sampleBuffer)
    }
}

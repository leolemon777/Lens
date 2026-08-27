@preconcurrency import AVFoundation
import Foundation
import LensCore

struct AudioSignalMetrics: Equatable, Sendable {
    let durationSeconds: Double
    let integratedLoudnessLUFS: Double
    let noiseFloorDecibels: Double
    let peakAmplitude: Double
}

struct VoiceAudioProcessingResult: Equatable, Sendable {
    let outputURL: URL
    let before: AudioSignalMetrics
    let after: AudioSignalMetrics
    let appliedGainDecibels: Double
}

enum VoiceAudioProcessorError: LocalizedError {
    case unsupportedFormat
    case bufferUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "麦克风轨道不是可处理的浮点 PCM 格式。"
        case .bufferUnavailable: "无法分配本地声音处理缓冲区。"
        }
    }
}

/// A deterministic, local-only voice chain. The raw microphone asset is never
/// changed: rumble filtering, downward expansion, gentle compression and
/// loudness normalization are written to a disposable sidecar used by export.
final class VoiceAudioProcessor: @unchecked Sendable {
    func analyze(url: URL) async throws -> AudioSignalMetrics {
        let worker = Task.detached(priority: .utility) {
            try Self.analyzeSynchronously(url: url)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func process(
        inputURL: URL,
        outputURL: URL,
        plan: AutoEditPlan.Audio
    ) async throws -> VoiceAudioProcessingResult {
        let worker = Task.detached(priority: .utility) {
            try Self.processSynchronously(
                inputURL: inputURL,
                outputURL: outputURL,
                plan: plan
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func recommendedGainDecibels(
        measuredLoudnessLUFS: Double,
        targetLoudnessLUFS: Double,
        peakAmplitude: Double,
        maximumBoostDecibels: Double = 12,
        maximumCutDecibels: Double = 18
    ) -> Double {
        guard measuredLoudnessLUFS.isFinite,
              measuredLoudnessLUFS > -119 else { return 0 }
        var gain = min(max(
            targetLoudnessLUFS - measuredLoudnessLUFS,
            -abs(maximumCutDecibels)
        ), abs(maximumBoostDecibels))
        if peakAmplitude.isFinite, peakAmplitude > 0 {
            let peakLimitedGain = 20 * log10(0.97 / peakAmplitude)
            gain = min(gain, peakLimitedGain)
        }
        return gain.isFinite ? gain : 0
    }

    static func linearGain(decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    private static func processSynchronously(
        inputURL: URL,
        outputURL: URL,
        plan: AutoEditPlan.Audio
    ) throws -> VoiceAudioProcessingResult {
        let before = try analyzeSynchronously(url: inputURL)
        let stageURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".voice-stage-\(UUID().uuidString).caf"
        )
        defer { try? FileManager.default.removeItem(at: stageURL) }

        let normalizationInput: URL
        if plan.reducesMicrophoneNoise, plan.noiseReductionAmount > 0.001 {
            try filterVoice(
                inputURL: inputURL,
                outputURL: stageURL,
                noiseFloorDecibels: before.noiseFloorDecibels,
                amount: plan.noiseReductionAmount
            )
            normalizationInput = stageURL
        } else {
            normalizationInput = inputURL
        }
        let processedMetrics = normalizationInput == inputURL
            ? before
            : try analyzeSynchronously(url: normalizationInput)
        let gainDecibels = plan.normalizesLoudness
            ? recommendedGainDecibels(
                measuredLoudnessLUFS: processedMetrics.integratedLoudnessLUFS,
                targetLoudnessLUFS: plan.targetLoudnessLUFS,
                peakAmplitude: processedMetrics.peakAmplitude
            )
            : 0
        try copyPCM(
            inputURL: normalizationInput,
            outputURL: outputURL,
            gain: linearGain(decibels: gainDecibels)
        )
        let after = try analyzeSynchronously(url: outputURL)
        return VoiceAudioProcessingResult(
            outputURL: outputURL,
            before: before,
            after: after,
            appliedGainDecibels: gainDecibels
        )
    }

    private static func analyzeSynchronously(url: URL) throws -> AudioSignalMetrics {
        let file = try AVAudioFile(forReading: url)
        let format = try supportedFormat(file.processingFormat)
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let framesPerBlock = max(Int(sampleRate * 0.1), 1)
        let capacity = AVAudioFrameCount(max(framesPerBlock, 8_192))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: capacity
        ) else {
            throw VoiceAudioProcessorError.bufferUnavailable
        }

        var blockEnergies: [Double] = []
        var noiseBlockEnergies: [Double] = []
        var blockEnergy = 0.0
        var noiseBlockEnergy = 0.0
        var blockFrameCount = 0
        var totalFrames: Int64 = 0
        var peak = 0.0
        var loudnessFilters = (0..<channelCount).map { _ in
            KWeightingFilter(sampleRate: sampleRate)
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let requestedFrames = AVAudioFrameCount(min(
                AVAudioFramePosition(capacity),
                file.length - file.framePosition
            ))
            try file.read(into: buffer, frameCount: requestedFrames)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw VoiceAudioProcessorError.unsupportedFormat
            }
            totalFrames += Int64(frameCount)
            for frame in 0..<frameCount {
                var frameEnergy = 0.0
                for channel in 0..<channelCount {
                    let sample = Double(channels[channel][frame])
                    peak = max(peak, abs(sample))
                    noiseBlockEnergy += sample * sample
                    let weighted = loudnessFilters[channel].process(sample)
                    frameEnergy += weighted * weighted
                }
                blockEnergy += frameEnergy
                blockFrameCount += 1
                if blockFrameCount == framesPerBlock {
                    blockEnergies.append(blockEnergy / Double(blockFrameCount))
                    noiseBlockEnergies.append(
                        noiseBlockEnergy / Double(blockFrameCount)
                    )
                    blockEnergy = 0
                    noiseBlockEnergy = 0
                    blockFrameCount = 0
                }
            }
        }
        if blockFrameCount > 0 {
            blockEnergies.append(blockEnergy / Double(blockFrameCount))
            noiseBlockEnergies.append(noiseBlockEnergy / Double(blockFrameCount))
        }

        let integrated = integratedLoudness(from: blockEnergies)
        let channelDivisor = Double(max(channelCount, 1))
        let audibleLevels = noiseBlockEnergies
            .map { 10 * log10(max($0 / channelDivisor, 1e-12)) }
            .filter { $0 > -90 }
            .sorted()
        let noiseFloor: Double
        if audibleLevels.isEmpty {
            noiseFloor = -90
        } else {
            let index = min(
                Int(Double(audibleLevels.count - 1) * 0.20),
                audibleLevels.count - 1
            )
            noiseFloor = audibleLevels[index]
        }
        return AudioSignalMetrics(
            durationSeconds: sampleRate > 0 ? Double(totalFrames) / sampleRate : 0,
            integratedLoudnessLUFS: integrated,
            noiseFloorDecibels: noiseFloor,
            peakAmplitude: peak
        )
    }

    private static func integratedLoudness(from energies: [Double]) -> Double {
        guard !energies.isEmpty else { return -120 }
        let gatedBlocks: [Double]
        if energies.count >= 4 {
            gatedBlocks = (3..<energies.count).map { index in
                energies[(index - 3)...index].reduce(0, +) / 4
            }
        } else {
            gatedBlocks = energies
        }
        let absoluteGated = gatedBlocks.filter { loudness(for: $0) >= -70 }
        guard !absoluteGated.isEmpty else { return -120 }
        let preliminaryEnergy = absoluteGated.reduce(0, +) / Double(absoluteGated.count)
        let relativeThreshold = loudness(for: preliminaryEnergy) - 10
        let relativeGated = absoluteGated.filter {
            loudness(for: $0) >= relativeThreshold
        }
        guard !relativeGated.isEmpty else { return loudness(for: preliminaryEnergy) }
        return loudness(
            for: relativeGated.reduce(0, +) / Double(relativeGated.count)
        )
    }

    private static func loudness(for energy: Double) -> Double {
        -0.691 + 10 * log10(max(energy, 1e-12))
    }

    private static func filterVoice(
        inputURL: URL,
        outputURL: URL,
        noiseFloorDecibels: Double,
        amount: Double
    ) throws {
        let input = try AVAudioFile(forReading: inputURL)
        let format = try supportedFormat(input.processingFormat)
        try prepareOutputURL(outputURL)
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: capacity
        ) else {
            throw VoiceAudioProcessorError.bufferUnavailable
        }
        let channelCount = Int(format.channelCount)
        let clampedAmount = min(max(amount, 0), 1)
        let cutoff = 65 + clampedAmount * 45
        var filters = (0..<channelCount).map { _ in
            BiquadHighPass(sampleRate: format.sampleRate, cutoff: cutoff)
        }
        let gateThreshold = min(max(
            noiseFloorDecibels + 5 + clampedAmount * 10,
            -62
        ), -28)
        let maximumGateReduction = 8 + clampedAmount * 24
        let sampleRate = max(format.sampleRate, 1)
        let envelopeAttack = exp(-1 / (0.008 * sampleRate))
        let envelopeRelease = exp(-1 / (0.12 * sampleRate))
        let gainAttack = exp(-1 / (0.012 * sampleRate))
        let gainRelease = exp(-1 / (0.16 * sampleRate))
        var envelope = 0.0
        var smoothedGain = 1.0

        while input.framePosition < input.length {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let requestedFrames = AVAudioFrameCount(min(
                AVAudioFramePosition(capacity),
                input.length - input.framePosition
            ))
            try input.read(into: buffer, frameCount: requestedFrames)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw VoiceAudioProcessorError.unsupportedFormat
            }
            for frame in 0..<frameCount {
                var frameEnergy = 0.0
                for channel in 0..<channelCount {
                    let filtered = filters[channel].process(
                        Double(channels[channel][frame])
                    )
                    channels[channel][frame] = Float(filtered)
                    frameEnergy += filtered * filtered
                }
                let level = sqrt(frameEnergy / Double(max(channelCount, 1)))
                let envelopeCoefficient = level > envelope
                    ? envelopeAttack
                    : envelopeRelease
                envelope = envelopeCoefficient * envelope
                    + (1 - envelopeCoefficient) * level
                let levelDecibels = 20 * log10(max(envelope, 1e-9))
                let belowThreshold = max(gateThreshold - levelDecibels, 0)
                let gateReduction = min(
                    belowThreshold * (0.35 + clampedAmount * 0.65),
                    maximumGateReduction
                )
                let compressionReduction = levelDecibels > -18
                    ? (levelDecibels + 18) * (1 - 1 / 3.0)
                    : 0
                let targetGain = linearGain(
                    decibels: -(gateReduction + compressionReduction)
                )
                let gainCoefficient = targetGain < smoothedGain
                    ? gainAttack
                    : gainRelease
                smoothedGain = gainCoefficient * smoothedGain
                    + (1 - gainCoefficient) * targetGain
                for channel in 0..<channelCount {
                    channels[channel][frame] *= Float(smoothedGain)
                }
            }
            try output.write(from: buffer)
        }
    }

    private static func copyPCM(
        inputURL: URL,
        outputURL: URL,
        gain: Double
    ) throws {
        let input = try AVAudioFile(forReading: inputURL)
        let format = try supportedFormat(input.processingFormat)
        try prepareOutputURL(outputURL)
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: capacity
        ) else {
            throw VoiceAudioProcessorError.bufferUnavailable
        }
        let channelCount = Int(format.channelCount)
        let safeGain = gain.isFinite ? max(gain, 0) : 1
        while input.framePosition < input.length {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let requestedFrames = AVAudioFrameCount(min(
                AVAudioFramePosition(capacity),
                input.length - input.framePosition
            ))
            try input.read(into: buffer, frameCount: requestedFrames)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw VoiceAudioProcessorError.unsupportedFormat
            }
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    let amplified = Double(channels[channel][frame]) * safeGain
                    channels[channel][frame] = Float(min(max(amplified, -0.98), 0.98))
                }
            }
            try output.write(from: buffer)
        }
    }

    private static func supportedFormat(_ format: AVAudioFormat) throws -> AVAudioFormat {
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              format.channelCount > 0,
              format.sampleRate > 0 else {
            throw VoiceAudioProcessorError.unsupportedFormat
        }
        return format
    }

    private static func prepareOutputURL(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

private struct BiquadHighPass {
    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    init(sampleRate: Double, cutoff: Double, quality: Double = 0.707) {
        let omega = 2 * Double.pi * min(max(cutoff, 20), sampleRate * 0.45) / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * max(quality, 0.1))
        let a0 = 1 + alpha
        b0 = ((1 + cosine) / 2) / a0
        b1 = (-(1 + cosine)) / a0
        b2 = ((1 + cosine) / 2) / a0
        a1 = (-2 * cosine) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ sample: Double) -> Double {
        let output = b0 * sample + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = sample
        y2 = y1
        y1 = output
        return output
    }
}

private struct KWeightingFilter {
    private var preFilter: BiquadFilter
    private var rlbHighPass: BiquadFilter

    init(sampleRate: Double) {
        let shelfFrequency = min(1_681.974_450_955_533, sampleRate * 0.45)
        let shelfGain = 3.999_843_853_973_347
        let shelfQuality = 0.707_175_236_955_419_6
        let shelfK = tan(Double.pi * shelfFrequency / sampleRate)
        let shelfVh = pow(10, shelfGain / 20)
        let shelfVb = pow(shelfVh, 0.499_666_774_154_541_6)
        let shelfA0 = 1 + shelfK / shelfQuality + shelfK * shelfK
        preFilter = BiquadFilter(
            b0: (shelfVh + shelfVb * shelfK / shelfQuality + shelfK * shelfK)
                / shelfA0,
            b1: 2 * (shelfK * shelfK - shelfVh) / shelfA0,
            b2: (shelfVh - shelfVb * shelfK / shelfQuality + shelfK * shelfK)
                / shelfA0,
            a1: 2 * (shelfK * shelfK - 1) / shelfA0,
            a2: (1 - shelfK / shelfQuality + shelfK * shelfK) / shelfA0
        )

        let highPassFrequency = min(38.135_470_876_024_44, sampleRate * 0.45)
        let highPassQuality = 0.500_327_037_323_877_3
        let highPassK = tan(Double.pi * highPassFrequency / sampleRate)
        let highPassA0 = 1 + highPassK / highPassQuality
            + highPassK * highPassK
        rlbHighPass = BiquadFilter(
            b0: 1,
            b1: -2,
            b2: 1,
            a1: 2 * (highPassK * highPassK - 1) / highPassA0,
            a2: (1 - highPassK / highPassQuality + highPassK * highPassK)
                / highPassA0
        )
    }

    mutating func process(_ sample: Double) -> Double {
        rlbHighPass.process(preFilter.process(sample))
    }
}

private struct BiquadFilter {
    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    mutating func process(_ sample: Double) -> Double {
        let output = b0 * sample + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = sample
        y2 = y1
        y1 = output
        return output
    }
}

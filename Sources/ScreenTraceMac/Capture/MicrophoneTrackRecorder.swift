import AVFoundation
import Foundation

enum MicrophoneTrackRecordingError: LocalizedError {
    case inputUnavailable
    case emptyTrack
    case stoppedUnexpectedly
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            "当前没有可用的麦克风输入。"
        case .emptyTrack:
            "麦克风轨道没有写入有效数据。"
        case .stoppedUnexpectedly:
            "麦克风输入在录制结束前意外停止。"
        case let .writeFailed(message):
            "麦克风轨道写入失败：\(message)"
        }
    }
}

@MainActor
final class MicrophoneTrackRecorder {
    private let levelMeter: AudioLevelMeter
    private var engine: AVAudioEngine?
    private var writer: MicrophoneFileWriter?
    private var outputURL: URL?

    var isRecording: Bool { engine?.isRunning == true }

    init(levelMeter: AudioLevelMeter = AudioLevelMeter()) {
        self.levelMeter = levelMeter
    }

    func start(outputURL: URL) throws {
        stopWithoutValidation()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneTrackRecordingError.inputUnavailable
        }

        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let writer = MicrophoneFileWriter(file: file)
        let tap = Self.makeTap(writer: writer, levelMeter: levelMeter)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format, block: tap)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        self.engine = engine
        self.writer = writer
        self.outputURL = outputURL
    }

    func stop() throws {
        guard let engine, let writer, let outputURL else { return }
        let stoppedUnexpectedly = !engine.isRunning
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
        self.writer = nil
        self.outputURL = nil

        if let failure = writer.failure {
            throw MicrophoneTrackRecordingError.writeFailed(failure.localizedDescription)
        }
        if stoppedUnexpectedly {
            throw MicrophoneTrackRecordingError.stoppedUnexpectedly
        }
        let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]
            as? NSNumber
        guard size?.int64Value ?? 0 > 0 else {
            throw MicrophoneTrackRecordingError.emptyTrack
        }
    }

    func cancel() {
        stopWithoutValidation()
    }

    private func stopWithoutValidation() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
        writer = nil
        outputURL = nil
    }

    nonisolated static func makeTap(
        writer: MicrophoneFileWriter,
        levelMeter: AudioLevelMeter
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            writer.write(buffer)
            levelMeter.update(buffer: buffer)
        }
    }
}

final class MicrophoneFileWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let lock = NSLock()
    private var storedFailure: Error?

    init(file: AVAudioFile) {
        self.file = file
    }

    var failure: Error? {
        lock.withLock { storedFailure }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard storedFailure == nil else { return }
            do {
                try file.write(from: buffer)
            } catch {
                storedFailure = error
            }
        }
    }
}

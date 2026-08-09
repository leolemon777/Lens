import AVFoundation
import Foundation

enum MicrophoneTrackRecordingError: LocalizedError {
    case inputUnavailable
    case emptyTrack
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            "当前没有可用的麦克风输入。"
        case .emptyTrack:
            "麦克风轨道没有写入有效数据。"
        case let .writeFailed(message):
            "麦克风轨道写入失败：\(message)"
        }
    }
}

@MainActor
final class MicrophoneTrackRecorder {
    private var engine: AVAudioEngine?
    private var writer: MicrophoneFileWriter?
    private var outputURL: URL?

    var isRecording: Bool { engine?.isRunning == true }

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
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            writer.write(buffer)
        }
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
        self.writer = nil
        self.outputURL = nil

        if let failure = writer.failure {
            throw MicrophoneTrackRecordingError.writeFailed(failure.localizedDescription)
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

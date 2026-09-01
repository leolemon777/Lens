import AVFoundation
import Foundation
import LensCore

enum NarrationSpeechError: LocalizedError {
    case emptyScript
    case voiceUnavailable(String)
    case synthesisFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyScript:
            "转写文本为空，无法生成配音。"
        case let .voiceUnavailable(language):
            "系统没有“\(language)”的可用语音，请在系统设置的语音内容里安装后重试。"
        case let .synthesisFailed(detail):
            "语音合成失败：\(detail)"
        }
    }
}

/// System-voice narration drafts. This is the local, zero-dependency tier:
/// the transcript becomes a speakable CAF file the user can drop into any
/// editor; no text ever leaves the machine.
struct NarrationSpeechSynthesizer: Sendable {
    /// Joins transcript segments into one speakable script, dropping the
    /// emptiest filler particles so the draft does not read them back.
    static func script(
        from transcript: TranscriptDocument,
        maximumCharacters: Int = 5_000
    ) -> String {
        let fillerParticles: Set<String> = ["嗯", "啊", "呃", "哦", "呣", "um", "uh", "erm", "hmm"]
        var lines: [String] = []
        for segment in transcript.segments {
            let characters = Array(segment.text)
            let words = CaptionWordSegmenter.words(in: segment.text)
            // Fillers are dropped over their whole word span (latin fillers can
            // be multi-character, e.g. "um").
            var fillerRanges: [Range<Int>] = []
            for word in words
            where fillerParticles.contains(word.text.lowercased()) {
                fillerRanges.append(word.offset..<(word.offset + word.text.count))
            }
            var kept = ""
            for (offset, character) in characters.enumerated()
            where fillerRanges.contains(where: { $0.contains(offset) }) == false {
                kept.append(character)
            }
            let line = kept.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        var script = lines.joined(separator: " ")
        if script.count > maximumCharacters {
            script = String(script.prefix(maximumCharacters))
        }
        return script.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes the synthesized speech to a temporary CAF file and returns it.
    func synthesize(text: String, language: String) async throws -> URL {
        let script = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { throw NarrationSpeechError.emptyScript }
        guard let voice = AVSpeechSynthesisVoice(language: language) else {
            throw NarrationSpeechError.voiceUnavailable(language)
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lens-narration-\(UUID().uuidString).caf")
        let utterance = AVSpeechUtterance(string: script)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
        utterance.postUtteranceDelay = 0.15

        return try await withCheckedThrowingContinuation { continuation in
            let synthesizer = AVSpeechSynthesizer()
            var audioFile: AVAudioFile?
            var writeError: Error?
            var finished = false
            func finish(_ result: Result<URL, Error>) {
                guard finished == false else { return }
                finished = true
                switch result {
                case let .success(url): continuation.resume(returning: url)
                case let .failure(error): continuation.resume(throwing: error)
                }
            }
            // The synthesizer must outlive the write callbacks.
            withExtendedLifetime(synthesizer) {
                synthesizer.write(utterance) { buffer in
                    guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
                    if pcmBuffer.frameLength == 0 {
                        // A zero-length buffer is the completion signal.
                        if let writeError {
                            try? FileManager.default.removeItem(at: outputURL)
                            finish(.failure(writeError))
                        } else if let audioFile {
                            finish(.success(audioFile.url))
                        } else {
                            finish(.failure(NarrationSpeechError.synthesisFailed(
                                "合成器没有输出任何音频"
                            )))
                        }
                        return
                    }
                    do {
                        if audioFile == nil {
                            let format = AVAudioFormat(
                                standardFormatWithSampleRate: pcmBuffer.format.sampleRate,
                                channels: pcmBuffer.format.channelCount
                            )
                            guard let format else {
                                throw NarrationSpeechError.synthesisFailed(
                                    "无法确定音频格式"
                                )
                            }
                            audioFile = try AVAudioFile(
                                forWriting: outputURL,
                                settings: format.settings
                            )
                        }
                        try audioFile?.write(from: pcmBuffer)
                    } catch {
                        writeError = error
                    }
                }
            }
        }
    }
}

import AppKit
import Darwin
import LensMac

let application = NSApplication.shared
if let effectsConfiguration = G3RenderedEffectsConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        Darwin.exit(await G3RenderedEffectsRunner.run(effectsConfiguration))
    }
    application.run()
} else if let transcriptionConfiguration = G3TranscriptionConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        Darwin.exit(await G3TranscriptionRunner.run(transcriptionConfiguration))
    }
    application.run()
} else {
    fputs("LensG3 requires --g3-rendered-effects or --g3-transcription\n", stderr)
    Darwin.exit(64)
}

import AppKit
import Darwin
import LensMac

let application = NSApplication.shared
if let accessibilityConfiguration = G4AccessibilityHostConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.accessory)
    guard G4AccessibilityHostRunner.start(accessibilityConfiguration) else {
        Darwin.exit(79)
    }
    application.run()
} else if let sourceHostConfiguration = G2SourceHostConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.accessory)
    guard G2SourceHostRunner.start(sourceHostConfiguration) else {
        Darwin.exit(79)
    }
    application.run()
} else if let audioProbeConfiguration = G2SystemAudioProbeConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let status = await G2SystemAudioProbeRunner.run(audioProbeConfiguration)
        Darwin.exit(status)
    }
    application.run()
} else if let interruptionConfiguration = G2SourceInterruptionConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        let status = await G2SourceInterruptionRunner.run(
            interruptionConfiguration
        )
        Darwin.exit(status)
    }
    application.run()
} else if let stressConfiguration = G1ScreenshotStressConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let status = await G1ScreenshotStressRunner.run(stressConfiguration)
        Darwin.exit(status)
    }
    application.run()
} else if let stressConfiguration = G2RecordingStressConfiguration(
    arguments: CommandLine.arguments
) {
    // The endurance gate owns a small, noninteractive animated stimulus window.
    // It is intentionally included in the diagnostic capture so the gate can
    // reject a perfectly timed but visually frozen recording.
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        let status = await G2RecordingStressRunner.run(stressConfiguration)
        Darwin.exit(status)
    }
    application.run()
} else if let effectsConfiguration = G3RenderedEffectsConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let status = await G3RenderedEffectsRunner.run(effectsConfiguration)
        Darwin.exit(status)
    }
    application.run()
} else if let transcriptionConfiguration = G3TranscriptionConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let status = await G3TranscriptionRunner.run(transcriptionConfiguration)
        Darwin.exit(status)
    }
    application.run()
} else if let recoveryConfiguration = G2RecordingRecoveryConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let status = await G2RecordingRecoveryRunner.run(recoveryConfiguration)
        Darwin.exit(status)
    }
    application.run()
} else {
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}

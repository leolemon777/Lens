import AppKit
import Darwin
import LensMac

let application = NSApplication.shared
if let sourceHostConfiguration = G2SourceHostConfiguration(
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
        Darwin.exit(await G2SystemAudioProbeRunner.run(audioProbeConfiguration))
    }
    application.run()
} else if let interruptionConfiguration = G2SourceInterruptionConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        Darwin.exit(await G2SourceInterruptionRunner.run(interruptionConfiguration))
    }
    application.run()
} else if let stressConfiguration = G2RecordingStressConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        Darwin.exit(await G2RecordingStressRunner.run(stressConfiguration))
    }
    application.run()
} else if let recoveryConfiguration = G2RecordingRecoveryConfiguration(
    arguments: CommandLine.arguments
) {
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        Darwin.exit(await G2RecordingRecoveryRunner.run(recoveryConfiguration))
    }
    application.run()
} else {
    fputs("LensG2 requires a G2 gate flag\n", stderr)
    Darwin.exit(64)
}

import AppKit
import Darwin
import LensMac

let application = NSApplication.shared
guard let configuration = G1ScreenshotStressConfiguration(
    arguments: CommandLine.arguments
) else {
    fputs("LensG1 requires --g1-screenshot-stress\n", stderr)
    Darwin.exit(64)
}
application.setActivationPolicy(.prohibited)
Task { @MainActor in
    Darwin.exit(await G1ScreenshotStressRunner.run(configuration))
}
application.run()

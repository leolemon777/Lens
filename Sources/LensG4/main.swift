import AppKit
import Darwin
import LensMac

let application = NSApplication.shared
guard let configuration = G4AccessibilityHostConfiguration(
    arguments: CommandLine.arguments
) else {
    fputs("LensG4 requires --g4-accessibility-host --ready-marker <path>\n", stderr)
    Darwin.exit(64)
}
application.setActivationPolicy(.accessory)
guard G4AccessibilityHostRunner.start(configuration) else {
    Darwin.exit(79)
}
application.run()

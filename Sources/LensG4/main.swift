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
// Keep the isolated accessibility host discoverable as a regular application
// so AX exposes window roles and SwiftUI descendants to the runtime audit.
application.setActivationPolicy(.regular)
guard G4AccessibilityHostRunner.start(configuration) else {
    Darwin.exit(79)
}
application.run()

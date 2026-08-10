import AppKit
import CoreGraphics
import ScreenTraceCore

@MainActor
final class PointerEventRecorder {
    nonisolated(unsafe) private var monitor: Any?
    private var pointerWriter: JSONLinesWriter<PointerEvent>?
    private var clickWriter: JSONLinesWriter<ClickEvent>?
    private var keyboardWriter: JSONLinesWriter<KeyboardEvent>?
    private var windowWriter: JSONLinesWriter<WindowEvent>?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    private var writeTask: Task<Void, Never>?
    private var startedAtUptime: TimeInterval = 0
    private var timelineOffset: TimeInterval = 0
    private var lastMoveAtUptime: TimeInterval = 0
    private var captureBounds: CGRect?
    private var trackedWindowID: CGWindowID?
    private var lastWindowBoundsRefresh: TimeInterval = 0
    private let minimumMoveInterval: TimeInterval = 1.0 / 60.0

    func start(
        session: RecordingTraceSession,
        captureBounds: CGRect,
        trackedWindowID: CGWindowID? = nil,
        timelineOffset: TimeInterval = 0
    ) throws {
        stopMonitoring()
        pointerWriter = try JSONLinesWriter(url: session.pointerEventsURL)
        clickWriter = try JSONLinesWriter(url: session.clickEventsURL)
        keyboardWriter = try JSONLinesWriter(url: session.keyboardEventsURL)
        windowWriter = try JSONLinesWriter(url: session.windowEventsURL)
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        self.timelineOffset = max(0, timelineOffset)
        lastMoveAtUptime = 0
        self.captureBounds = captureBounds.standardized
        self.trackedWindowID = trackedWindowID
        lastWindowBoundsRefresh = 0

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .keyDown
        ]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor in self?.recordActivation(of: application) }
        }
        if let application = NSWorkspace.shared.frontmostApplication {
            recordActivation(of: application)
        }
    }

    func stop() async {
        stopMonitoring()
        await writeTask?.value
        writeTask = nil
        if let pointerWriter {
            try? await pointerWriter.close()
        }
        if let clickWriter {
            try? await clickWriter.close()
        }
        if let keyboardWriter {
            try? await keyboardWriter.close()
        }
        if let windowWriter {
            try? await windowWriter.close()
        }
        self.pointerWriter = nil
        self.clickWriter = nil
        self.keyboardWriter = nil
        self.windowWriter = nil
        captureBounds = nil
        trackedWindowID = nil
        lastWindowBoundsRefresh = 0
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    func handle(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let location = event.cgEvent?.location ?? NSEvent.mouseLocation
        let point = TracePoint(x: location.x, y: location.y)
        let normalizedLocation = normalizedPoint(for: location)
        let elapsed = timelineOffset + max(0, now - startedAtUptime)

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard now - lastMoveAtUptime >= minimumMoveInterval else { return }
            lastMoveAtUptime = now
            let kind: PointerEventKind = event.type == .mouseMoved ? .moved : .dragged
            let pointerEvent = PointerEvent(
                time: elapsed,
                kind: kind,
                location: point,
                normalizedLocation: normalizedLocation,
                displayID: Self.displayID(at: location)
            )
            if let pointerWriter {
                enqueueWrite { try? await pointerWriter.append(pointerEvent) }
            }

        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            let click = ClickEvent(
                time: elapsed,
                button: Self.button(for: event),
                phase: Self.phase(for: event),
                location: point,
                normalizedLocation: normalizedLocation,
                displayID: Self.displayID(at: location),
                clickCount: max(event.clickCount, 1)
            )
            if let clickWriter {
                enqueueWrite { try? await clickWriter.append(click) }
            }

        case .keyDown:
            guard let keyboardEvent = Self.sanitizedKeyboardEvent(from: event, time: elapsed),
                  let keyboardWriter else { return }
            enqueueWrite { try? await keyboardWriter.append(keyboardEvent) }

        default:
            break
        }
    }

    private func recordActivation(of application: NSRunningApplication) {
        recordApplicationFocus(
            applicationName: application.localizedName,
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier
        )
    }

    func recordApplicationFocus(
        applicationName: String?,
        bundleIdentifier: String?,
        processIdentifier: pid_t
    ) {
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windowWriter else { return }
        let elapsed = timelineOffset + max(
            0,
            ProcessInfo.processInfo.systemUptime - startedAtUptime
        )
        let event = WindowEvent(
            time: elapsed,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier
        )
        guard event.applicationName != nil || event.bundleIdentifier != nil else { return }
        enqueueWrite { try? await windowWriter.append(event) }
    }

    static func sanitizedKeyboardEvent(from event: NSEvent, time: Double) -> KeyboardEvent? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isShortcut = flags.contains(.command) || flags.contains(.control)
        let specialLabel = specialKeyLabels[event.keyCode]
        guard isShortcut || specialLabel != nil else { return nil }

        let label: String? = specialLabel ?? shortcutLabel(from: event.charactersIgnoringModifiers)
        let modifiers: [KeyboardModifier] = [
            flags.contains(.command) ? .command : nil,
            flags.contains(.control) ? .control : nil,
            flags.contains(.option) ? .option : nil,
            flags.contains(.shift) ? .shift : nil,
            flags.contains(.function) ? .function : nil,
            flags.contains(.capsLock) ? .capsLock : nil
        ].compactMap { $0 }
        return KeyboardEvent(
            time: time,
            keyCode: Int(event.keyCode),
            label: label,
            modifiers: modifiers,
            isRepeat: event.isARepeat
        )
    }

    private static func shortcutLabel(from characters: String?) -> String? {
        guard let scalar = characters?.unicodeScalars.first,
              characters?.unicodeScalars.count == 1,
              scalar.isASCII,
              CharacterSet.alphanumerics.contains(scalar) else { return nil }
        return String(scalar).uppercased()
    }

    private static let specialKeyLabels: [UInt16: String] = [
        36: "Return", 48: "Tab", 51: "Delete", 53: "Escape", 71: "Clear",
        76: "Enter", 115: "Home", 116: "PageUp", 117: "ForwardDelete",
        119: "End", 121: "PageDown", 123: "Left", 124: "Right",
        125: "Down", 126: "Up",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]

    private func normalizedPoint(for location: CGPoint) -> TracePoint? {
        refreshTrackedWindowBoundsIfNeeded()
        guard let captureBounds else { return nil }
        return CaptureGeometry.normalizedPoint(location, in: captureBounds)
    }

    private func refreshTrackedWindowBoundsIfNeeded() {
        guard let trackedWindowID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWindowBoundsRefresh >= 1.0 / 15.0 else { return }
        lastWindowBoundsRefresh = now
        guard let info = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            trackedWindowID
        ) as? [[String: Any]],
        let item = info.first,
        let rawBounds = item[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
        bounds.width > 0,
        bounds.height > 0 else {
            return
        }
        captureBounds = bounds.standardized
    }

    private func enqueueWrite(_ operation: @escaping @Sendable () async -> Void) {
        let previous = writeTask
        writeTask = Task {
            await previous?.value
            await operation()
        }
    }

    private static func button(for event: NSEvent) -> PointerButton {
        switch event.type {
        case .leftMouseDown, .leftMouseUp: .left
        case .rightMouseDown, .rightMouseUp: .right
        case .otherMouseDown, .otherMouseUp:
            event.buttonNumber == 2 ? .middle : .other
        default: .other
        }
    }

    private static func phase(for event: NSEvent) -> ClickPhase {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: .down
        default: .up
        }
    }

    private static func displayID(at point: CGPoint) -> UInt32? {
        var displayID = CGDirectDisplayID()
        var count: UInt32 = 0
        let error = CGGetDisplaysWithPoint(point, 1, &displayID, &count)
        return error == .success && count > 0 ? displayID : nil
    }
}

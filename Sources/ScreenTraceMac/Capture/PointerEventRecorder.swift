import AppKit
import CoreGraphics
import ScreenTraceCore

@MainActor
final class PointerEventRecorder {
    typealias GlobalMonitorHandler = @Sendable (NSEvent) -> Void
    typealias GlobalMonitorInstaller = (
        NSEvent.EventTypeMask,
        @escaping GlobalMonitorHandler
    ) -> Any?

    private struct MonitoredInput: Sendable {
        enum Kind: Sendable {
            case moved
            case dragged
            case leftMouseDown
            case leftMouseUp
            case rightMouseDown
            case rightMouseUp
            case otherMouseDown
            case otherMouseUp
            case keyDown
            case unsupported
        }

        let kind: Kind
        let locationX: Double
        let locationY: Double
        let buttonNumber: Int
        let clickCount: Int
        let keyCode: UInt16
        let modifierFlags: UInt
        let charactersIgnoringModifiers: String?
        let isRepeat: Bool
    }

    nonisolated(unsafe) private var monitor: Any?
    private let addGlobalMonitorOverride: GlobalMonitorInstaller?
    private let removeMonitorOverride: ((Any) -> Void)?
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
    private var monitorGeneration: UInt64 = 0
    private let minimumMoveInterval: TimeInterval = 1.0 / 60.0

    init(
        addGlobalMonitorOverride: GlobalMonitorInstaller? = nil,
        removeMonitorOverride: ((Any) -> Void)? = nil
    ) {
        self.addGlobalMonitorOverride = addGlobalMonitorOverride
        self.removeMonitorOverride = removeMonitorOverride
    }

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
        let generation = monitorGeneration
        let deliver: @MainActor @Sendable (MonitoredInput, UInt64) -> Void = {
            [weak self] input, deliveredGeneration in
            self?.handle(input, generation: deliveredGeneration)
        }
        let globalHandler = Self.makeGlobalMonitorHandler(
            generation: generation,
            deliver: deliver
        )
        monitor = addGlobalMonitorOverride?(mask, globalHandler)
            ?? NSEvent.addGlobalMonitorForEvents(matching: mask, handler: globalHandler)
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
        monitorGeneration &+= 1
        if let monitor {
            removeMonitorOverride?(monitor) ?? NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    func handle(_ event: NSEvent) {
        handle(Self.monitoredInput(from: event), generation: monitorGeneration)
    }

    private func handle(_ input: MonitoredInput, generation: UInt64) {
        guard generation == monitorGeneration else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let location = CGPoint(x: input.locationX, y: input.locationY)
        let point = TracePoint(x: location.x, y: location.y)
        let normalizedLocation = normalizedPoint(for: location)
        let elapsed = timelineOffset + max(0, now - startedAtUptime)

        switch input.kind {
        case .moved, .dragged:
            guard now - lastMoveAtUptime >= minimumMoveInterval else { return }
            lastMoveAtUptime = now
            let kind: PointerEventKind = input.kind == .moved ? .moved : .dragged
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
                button: Self.button(for: input),
                phase: Self.phase(for: input),
                location: point,
                normalizedLocation: normalizedLocation,
                displayID: Self.displayID(at: location),
                clickCount: max(input.clickCount, 1)
            )
            if let clickWriter {
                enqueueWrite { try? await clickWriter.append(click) }
            }

        case .keyDown:
            guard let keyboardEvent = Self.sanitizedKeyboardEvent(from: input, time: elapsed),
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
        sanitizedKeyboardEvent(from: monitoredInput(from: event), time: time)
    }

    private static func sanitizedKeyboardEvent(
        from input: MonitoredInput,
        time: Double
    ) -> KeyboardEvent? {
        guard input.kind == .keyDown else { return nil }
        let flags = NSEvent.ModifierFlags(rawValue: input.modifierFlags)
        let isShortcut = flags.contains(.command) || flags.contains(.control)
        let specialLabel = specialKeyLabels[input.keyCode]
        guard isShortcut || specialLabel != nil else { return nil }

        let label: String? = specialLabel
            ?? shortcutLabel(from: input.charactersIgnoringModifiers)
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
            keyCode: Int(input.keyCode),
            label: label,
            modifiers: modifiers,
            isRepeat: input.isRepeat
        )
    }

    nonisolated private static func monitoredInput(from event: NSEvent) -> MonitoredInput {
        let kind = monitoredKind(from: event.type)
        let location: CGPoint
        switch kind {
        case .moved, .dragged,
             .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            location = event.cgEvent?.location ?? NSEvent.mouseLocation
        case .keyDown, .unsupported:
            location = .zero
        }
        let isButtonEvent: Bool
        switch kind {
        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            isButtonEvent = true
        default:
            isButtonEvent = false
        }
        let isKeyEvent = kind == .keyDown
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return MonitoredInput(
            kind: kind,
            locationX: location.x,
            locationY: location.y,
            buttonNumber: isButtonEvent ? event.buttonNumber : 0,
            clickCount: isButtonEvent ? event.clickCount : 0,
            keyCode: isKeyEvent ? event.keyCode : 0,
            modifierFlags: flags.rawValue,
            charactersIgnoringModifiers: isKeyEvent ? event.charactersIgnoringModifiers : nil,
            isRepeat: isKeyEvent && event.isARepeat
        )
    }

    nonisolated private static func monitoredKind(from type: NSEvent.EventType) -> MonitoredInput.Kind {
        switch type {
        case .mouseMoved: .moved
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: .dragged
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        case .rightMouseDown: .rightMouseDown
        case .rightMouseUp: .rightMouseUp
        case .otherMouseDown: .otherMouseDown
        case .otherMouseUp: .otherMouseUp
        case .keyDown: .keyDown
        default: .unsupported
        }
    }

    nonisolated private static func makeGlobalMonitorHandler(
        generation: UInt64,
        deliver: @escaping @MainActor @Sendable (MonitoredInput, UInt64) -> Void
    ) -> GlobalMonitorHandler {
        { @Sendable event in
            let input = monitoredInput(from: event)
            DispatchQueue.main.async { @MainActor in
                deliver(input, generation)
            }
        }
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

    private static func button(for input: MonitoredInput) -> PointerButton {
        switch input.kind {
        case .leftMouseDown, .leftMouseUp: .left
        case .rightMouseDown, .rightMouseUp: .right
        case .otherMouseDown, .otherMouseUp:
            input.buttonNumber == 2 ? .middle : .other
        default: .other
        }
    }

    private static func phase(for input: MonitoredInput) -> ClickPhase {
        switch input.kind {
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

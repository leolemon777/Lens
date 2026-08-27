import AppKit
import CoreGraphics
import LensCore

enum EventCaptureFailure: String, Equatable, Sendable {
    case inputMonitoringDenied
    case monitorUnavailable
    case eventsNotDelivered
    case writerFailure

    var userFacingDescription: String {
        switch self {
        case .inputMonitoringDenied:
            "输入监控未授权，已改为在原始视频中保留光标"
        case .monitorUnavailable:
            "无法启动全局事件监听，智能跟踪已降级"
        case .eventsNotDelivered:
            "检测到鼠标移动，但系统没有交付事件"
        case .writerFailure:
            "事件轨写入失败，原始录屏仍在继续"
        }
    }
}

enum EventCaptureHealth: Equatable, Sendable {
    case checking
    case waitingForActivity
    case healthy(pointerCount: Int, clickCount: Int)
    case degraded(EventCaptureFailure)

    var isDegraded: Bool {
        if case .degraded = self { return true }
        return false
    }
}

struct EventCaptureSnapshot: Equatable, Sendable {
    let health: EventCaptureHealth
    let pointerCount: Int
    let clickCount: Int
    let keyboardCount: Int
    let windowCount: Int
    let lastEventUptime: TimeInterval?
}

@MainActor
final class PointerEventRecorder {
    typealias GlobalMonitorHandler = @Sendable (NSEvent) -> Void
    typealias GlobalMonitorInstaller = (
        NSEvent.EventTypeMask,
        @escaping GlobalMonitorHandler
    ) -> Any?
    typealias WindowBoundsProvider = (CGWindowID) -> CGRect?

    private struct MonitoredInput: Sendable {
        enum Kind: Sendable {
            case moved
            case dragged
            case scroll
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
        let scrollingDeltaX: Double
        let scrollingDeltaY: Double
    }

    nonisolated(unsafe) private var monitor: Any?
    private let addGlobalMonitorOverride: GlobalMonitorInstaller?
    private let removeMonitorOverride: ((Any) -> Void)?
    private let inputMonitoringPreflight: () -> Bool
    private let mouseLocationProvider: () -> CGPoint
    private let cursorShapeProvider: () -> PointerCursorShape?
    private let windowBoundsProvider: WindowBoundsProvider
    private var pointerWriter: JSONLinesWriter<PointerEvent>?
    private var clickWriter: JSONLinesWriter<ClickEvent>?
    private var keyboardWriter: JSONLinesWriter<KeyboardEvent>?
    private var windowWriter: JSONLinesWriter<WindowEvent>?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    private var writeTask: Task<Void, Never>?
    private var startedAtUptime: TimeInterval = 0
    private var timelineOffset: TimeInterval = 0
    private var lastMoveAtUptime: TimeInterval = 0
    private var lastScrollAtUptime: TimeInterval = 0
    private var lastCursorShapeSampleAtUptime: TimeInterval = -.infinity
    private var sampledCursorShape: PointerCursorShape?
    private var captureBounds: CGRect?
    private var trackedWindowID: CGWindowID?
    private var lastWindowBoundsRefresh: TimeInterval = 0
    private var hasOnscreenFrameBounds = false
    private var monitorGeneration: UInt64 = 0
    private let minimumMoveInterval: TimeInterval = 1.0 / 60.0
    private var activeSessionPackageURL: URL?
    private var inputMonitoringGrantedAtStart = false
    private var initialMouseLocation = CGPoint.zero
    private var pointerEventCount = 0
    private var clickEventCount = 0
    private var keyboardEventCount = 0
    private var windowEventCount = 0
    private var lastEventUptime: TimeInterval?
    private var didEncounterWriterFailure = false
    private var isMonitoring = false
    private var healthBeforeStop: EventCaptureHealth = .checking

    init(
        addGlobalMonitorOverride: GlobalMonitorInstaller? = nil,
        removeMonitorOverride: ((Any) -> Void)? = nil,
        inputMonitoringPreflight: @escaping () -> Bool = {
            CGPreflightListenEventAccess()
        },
        mouseLocationProvider: @escaping () -> CGPoint = {
            NSEvent.mouseLocation
        },
        cursorShapeProvider: @escaping () -> PointerCursorShape? = {
            SystemCursorShapeMatcher.currentShape()
        },
        windowBoundsProvider: @escaping WindowBoundsProvider = {
            PointerEventRecorder.currentWindowBounds(for: $0)
        }
    ) {
        self.addGlobalMonitorOverride = addGlobalMonitorOverride
        self.removeMonitorOverride = removeMonitorOverride
        self.inputMonitoringPreflight = inputMonitoringPreflight
        self.mouseLocationProvider = mouseLocationProvider
        self.cursorShapeProvider = cursorShapeProvider
        self.windowBoundsProvider = windowBoundsProvider
    }

    var requiresEmbeddedCursorFallback: Bool {
        !inputMonitoringGrantedAtStart || monitor == nil
    }

    var eventCaptureSnapshot: EventCaptureSnapshot {
        let health = isMonitoring ? evaluateHealth() : healthBeforeStop
        return EventCaptureSnapshot(
            health: health,
            pointerCount: pointerEventCount,
            clickCount: clickEventCount,
            keyboardCount: keyboardEventCount,
            windowCount: windowEventCount,
            lastEventUptime: lastEventUptime
        )
    }

    func start(
        session: RecordingLensSession,
        captureBounds: CGRect,
        trackedWindowID: CGWindowID? = nil,
        timelineOffset: TimeInterval = 0
    ) throws {
        stopMonitoring()
        if activeSessionPackageURL?.standardizedFileURL != session.packageURL.standardizedFileURL {
            resetSessionHealth(packageURL: session.packageURL)
        }
        pointerWriter = try JSONLinesWriter(url: session.pointerEventsURL)
        clickWriter = try JSONLinesWriter(url: session.clickEventsURL)
        keyboardWriter = try JSONLinesWriter(url: session.keyboardEventsURL)
        windowWriter = try JSONLinesWriter(url: session.windowEventsURL)
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        self.timelineOffset = max(0, timelineOffset)
        lastMoveAtUptime = 0
        lastScrollAtUptime = 0
        lastCursorShapeSampleAtUptime = -.infinity
        sampledCursorShape = nil
        self.captureBounds = captureBounds.standardized
        self.trackedWindowID = trackedWindowID
        lastWindowBoundsRefresh = 0
        hasOnscreenFrameBounds = false
        inputMonitoringGrantedAtStart = inputMonitoringPreflight()
        initialMouseLocation = mouseLocationProvider()
        healthBeforeStop = .checking

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
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
        if let addGlobalMonitorOverride {
            monitor = addGlobalMonitorOverride(mask, globalHandler)
        } else {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: globalHandler)
        }
        isMonitoring = true
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
        healthBeforeStop = evaluateHealth()
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
        hasOnscreenFrameBounds = false
    }

    private func stopMonitoring() {
        isMonitoring = false
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
        let point = LensPoint(x: location.x, y: location.y)
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
                displayID: Self.displayID(at: location),
                cursorShape: cursorShape(at: now)
            )
            if let pointerWriter {
                pointerEventCount += 1
                lastEventUptime = now
                enqueueWrite { try await pointerWriter.append(pointerEvent) }
            }

        case .scroll:
            guard now - lastScrollAtUptime >= minimumMoveInterval else { return }
            lastScrollAtUptime = now
            let pointerEvent = PointerEvent(
                time: elapsed,
                kind: .scroll,
                location: point,
                normalizedLocation: normalizedLocation,
                displayID: Self.displayID(at: location),
                scrollDelta: LensPoint(
                    x: input.scrollingDeltaX,
                    y: input.scrollingDeltaY
                ),
                cursorShape: cursorShape(at: now)
            )
            if let pointerWriter {
                pointerEventCount += 1
                lastEventUptime = now
                enqueueWrite { try await pointerWriter.append(pointerEvent) }
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
                clickCount: max(input.clickCount, 1),
                cursorShape: cursorShape(at: now)
            )
            if let clickWriter {
                clickEventCount += 1
                lastEventUptime = now
                enqueueWrite { try await clickWriter.append(click) }
            }
            // A mouse-up can happen without a subsequent move. Emit a stationary
            // pointer sample so replay can end the dragged state at the exact
            // release time instead of leaving the cursor visually "held".
            if click.phase == .up, let pointerWriter {
                let release = PointerEvent(
                    time: elapsed,
                    kind: .moved,
                    location: point,
                    normalizedLocation: normalizedLocation,
                    displayID: Self.displayID(at: location),
                    cursorShape: click.cursorShape
                )
                pointerEventCount += 1
                lastEventUptime = now
                enqueueWrite { try await pointerWriter.append(release) }
            }

        case .keyDown:
            guard let keyboardEvent = Self.sanitizedKeyboardEvent(from: input, time: elapsed),
                  let keyboardWriter else { return }
            keyboardEventCount += 1
            lastEventUptime = now
            enqueueWrite { try await keyboardWriter.append(keyboardEvent) }

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
        windowEventCount += 1
        lastEventUptime = ProcessInfo.processInfo.systemUptime
        enqueueWrite { try await windowWriter.append(event) }
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
        case .moved, .dragged, .scroll,
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
            isRepeat: isKeyEvent && event.isARepeat,
            scrollingDeltaX: kind == .scroll ? event.scrollingDeltaX : 0,
            scrollingDeltaY: kind == .scroll ? event.scrollingDeltaY : 0
        )
    }

    nonisolated private static func monitoredKind(from type: NSEvent.EventType) -> MonitoredInput.Kind {
        switch type {
        case .mouseMoved: .moved
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: .dragged
        case .scrollWheel: .scroll
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

    private func normalizedPoint(for location: CGPoint) -> LensPoint? {
        refreshTrackedWindowBoundsIfNeeded()
        guard let captureBounds else { return nil }
        return CaptureGeometry.normalizedPoint(location, in: captureBounds)
    }

    /// ScreenCaptureKit reports the captured content's actual onscreen rectangle
    /// with each video frame. This remains correct when macOS presents a window
    /// through Stage Manager or another transform while CGWindow still exposes
    /// the window's untransformed logical frame.
    func updateOnscreenCaptureBounds(_ bounds: CGRect) {
        let bounds = bounds.standardized
        guard trackedWindowID != nil,
              bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else { return }
        captureBounds = bounds
        hasOnscreenFrameBounds = true
    }

    private func cursorShape(at uptime: TimeInterval) -> PointerCursorShape? {
        guard uptime - lastCursorShapeSampleAtUptime >= 1.0 / 12.0 else {
            return sampledCursorShape
        }
        lastCursorShapeSampleAtUptime = uptime
        sampledCursorShape = cursorShapeProvider()
        return sampledCursorShape
    }

    private func refreshTrackedWindowBoundsIfNeeded() {
        guard !hasOnscreenFrameBounds, let trackedWindowID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWindowBoundsRefresh >= 1.0 / 15.0 else { return }
        lastWindowBoundsRefresh = now
        guard let bounds = windowBoundsProvider(trackedWindowID) else { return }
        captureBounds = bounds.standardized
    }

    nonisolated static func currentWindowBounds(for windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            windowID
        ) as? [[String: Any]] else { return nil }
        return matchingWindowBounds(windowID: windowID, in: info)
    }

    nonisolated static func matchingWindowBounds(
        windowID: CGWindowID,
        in windowInfo: [[String: Any]]
    ) -> CGRect? {
        guard let item = windowInfo.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
        }),
        let rawBounds = item[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
        bounds.width > 0,
        bounds.height > 0 else {
            return nil
        }
        return bounds.standardized
    }

    private func enqueueWrite(_ operation: @escaping @Sendable () async throws -> Void) {
        let previous = writeTask
        writeTask = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await operation()
            } catch {
                self?.didEncounterWriterFailure = true
            }
        }
    }

    private func evaluateHealth() -> EventCaptureHealth {
        if didEncounterWriterFailure {
            return .degraded(.writerFailure)
        }
        if !inputMonitoringGrantedAtStart {
            return .degraded(.inputMonitoringDenied)
        }
        guard monitor != nil else {
            return .degraded(.monitorUnavailable)
        }
        if pointerEventCount > 0 || clickEventCount > 0 {
            return .healthy(
                pointerCount: pointerEventCount,
                clickCount: clickEventCount
            )
        }
        let currentLocation = mouseLocationProvider()
        if hypot(
            currentLocation.x - initialMouseLocation.x,
            currentLocation.y - initialMouseLocation.y
        ) >= 4 {
            return .degraded(.eventsNotDelivered)
        }
        return .waitingForActivity
    }

    private func resetSessionHealth(packageURL: URL) {
        activeSessionPackageURL = packageURL.standardizedFileURL
        pointerEventCount = 0
        clickEventCount = 0
        keyboardEventCount = 0
        windowEventCount = 0
        lastEventUptime = nil
        didEncounterWriterFailure = false
        healthBeforeStop = .checking
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

@MainActor
enum SystemCursorShapeMatcher {
    private struct Candidate {
        let shape: PointerCursorShape
        let cursor: NSCursor
    }

    private static let candidates: [Candidate] = [
        Candidate(shape: .arrow, cursor: .arrow),
        Candidate(shape: .pointingHand, cursor: .pointingHand),
        Candidate(shape: .iBeam, cursor: .iBeam),
        Candidate(shape: .verticalIBeam, cursor: .iBeamCursorForVerticalLayout),
        Candidate(shape: .crosshair, cursor: .crosshair),
        Candidate(shape: .openHand, cursor: .openHand),
        Candidate(shape: .closedHand, cursor: .closedHand),
        Candidate(shape: .horizontalResize, cursor: .columnResize),
        Candidate(shape: .verticalResize, cursor: .rowResize),
        Candidate(shape: .operationNotAllowed, cursor: .operationNotAllowed),
        Candidate(shape: .dragCopy, cursor: .dragCopy),
        Candidate(shape: .dragLink, cursor: .dragLink),
        Candidate(shape: .contextualMenu, cursor: .contextualMenu),
        Candidate(shape: .disappearingItem, cursor: .disappearingItem)
    ]

    static func currentShape() -> PointerCursorShape? {
        shape(for: NSCursor.currentSystem)
    }

    static func shape(for cursor: NSCursor?) -> PointerCursorShape? {
        guard let cursor else { return nil }
        let size = cursor.image.size
        let hotSpot = cursor.hotSpot
        let representations = representationSignature(of: cursor.image)
        let matches = candidates.filter { candidate in
            abs(candidate.cursor.image.size.width - size.width) < 0.5
                && abs(candidate.cursor.image.size.height - size.height) < 0.5
                && abs(candidate.cursor.hotSpot.x - hotSpot.x) < 0.5
                && abs(candidate.cursor.hotSpot.y - hotSpot.y) < 0.5
                && representationSignature(of: candidate.cursor.image) == representations
        }
        if matches.count == 1 { return matches[0].shape }
        let data = cursor.image.tiffRepresentation
        return matches.first {
            $0.cursor.image.tiffRepresentation == data
        }?.shape ?? .unknown
    }

    private static func representationSignature(of image: NSImage) -> [String] {
        image.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }
    }
}

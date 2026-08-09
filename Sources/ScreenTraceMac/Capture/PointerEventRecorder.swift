import AppKit
import CoreGraphics
import ScreenTraceCore

@MainActor
final class PointerEventRecorder {
    nonisolated(unsafe) private var monitor: Any?
    private var pointerWriter: JSONLinesWriter<PointerEvent>?
    private var clickWriter: JSONLinesWriter<ClickEvent>?
    private var writeTask: Task<Void, Never>?
    private var startedAtUptime: TimeInterval = 0
    private var lastMoveAtUptime: TimeInterval = 0
    private var captureDisplayID: CGDirectDisplayID?
    private var captureBounds: CGRect?
    private let minimumMoveInterval: TimeInterval = 1.0 / 60.0

    func start(session: RecordingTraceSession, displayID: CGDirectDisplayID) throws {
        stopMonitoring()
        pointerWriter = try JSONLinesWriter(url: session.pointerEventsURL)
        clickWriter = try JSONLinesWriter(url: session.clickEventsURL)
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        lastMoveAtUptime = 0
        captureDisplayID = displayID
        captureBounds = CGDisplayBounds(displayID)

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
            .otherMouseUp
        ]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
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
        self.pointerWriter = nil
        self.clickWriter = nil
        captureDisplayID = nil
        captureBounds = nil
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let location = event.cgEvent?.location ?? NSEvent.mouseLocation
        let point = TracePoint(x: location.x, y: location.y)
        let normalizedLocation = normalizedPoint(for: location)
        let elapsed = max(0, now - startedAtUptime)

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

        default:
            break
        }
    }

    private func normalizedPoint(for location: CGPoint) -> TracePoint? {
        guard let captureDisplayID,
              Self.displayID(at: location) == captureDisplayID,
              let captureBounds,
              captureBounds.width > 0,
              captureBounds.height > 0 else {
            return nil
        }
        return TracePoint(
            x: min(max((location.x - captureBounds.minX) / captureBounds.width, 0), 1),
            y: min(max((location.y - captureBounds.minY) / captureBounds.height, 0), 1)
        )
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

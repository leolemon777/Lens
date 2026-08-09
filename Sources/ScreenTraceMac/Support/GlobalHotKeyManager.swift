import AppKit
import Carbon
import ScreenTraceCore

@MainActor
final class GlobalHotKeyManager {
    private static let signature: OSType = 0x53545243 // STRC
    private static let actionCenterIdentifier: UInt32 = 1

    private var stateMachine = HotKeyStateMachine()
    nonisolated(unsafe) private var globalMonitor: Any?
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var actionCenterHotKey: EventHotKeyRef?
    private let handler: (HotKeyIntent) -> Void

    init(handler: @escaping (HotKeyIntent) -> Void) {
        self.handler = handler
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let hasNativeActionCenterHotKey = registerActionCenterHotKey()
        let mask: NSEvent.EventTypeMask = hasNativeActionCenterHotKey
            ? [.flagsChanged]
            : [.flagsChanged, .keyDown]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    deinit {
        if let actionCenterHotKey {
            UnregisterEventHotKey(actionCenterHotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    private func registerActionCenterHotKey() -> Bool {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == GlobalHotKeyManager.signature,
                      hotKeyID.id == GlobalHotKeyManager.actionCenterIdentifier else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    manager.handler(.toggleActionCenter)
                }
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        guard handlerStatus == noErr else { return false }
        eventHandler = installedHandler

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.actionCenterIdentifier
        )
        var registeredHotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(kEventKeyModifierFnMask),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard registrationStatus == noErr else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            return false
        }
        actionCenterHotKey = registeredHotKey
        return true
    }

    private func handle(_ event: NSEvent) {
        let kind: HotKeyEventKind = event.type == .flagsChanged ? .flagsChanged : .keyDown
        let input = HotKeyInput(
            kind: kind,
            keyCode: event.keyCode,
            modifiers: Self.modifiers(from: event.modifierFlags),
            isRepeat: event.isARepeat
        )
        if let intent = stateMachine.handle(input) {
            handler(intent)
        }
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> HotKeyModifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: HotKeyModifiers = []
        if flags.contains(.function) { result.insert(.function) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.capsLock) { result.insert(.capsLock) }
        return result
    }
}

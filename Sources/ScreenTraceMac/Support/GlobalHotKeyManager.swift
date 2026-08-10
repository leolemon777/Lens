import AppKit
import Carbon
import ScreenTraceCore

struct HotKeyRegistrationIssue: Equatable {
    let intent: HotKeyIntent
    let shortcut: HotKeyShortcut
    let status: OSStatus
}

struct HotKeyRegistrationReport: Equatable {
    let issues: [HotKeyRegistrationIssue]
    let usesEventMonitorFallback: Bool

    static let notStarted = HotKeyRegistrationReport(
        issues: [],
        usesEventMonitorFallback: false
    )
}

@MainActor
final class GlobalHotKeyManager {
    private static let signature: OSType = 0x53545243 // STRC

    private let configuration: HotKeyConfiguration
    private let handler: (HotKeyIntent) -> Void
    private let installEventHandlerOverride: (() -> Bool)?
    private let registerOverride: ((HotKeyBinding, UInt32) -> OSStatus)?
    private var stateMachine = HotKeyStateMachine(bindings: [])
    private var started = false
    private var intentByIdentifier: [UInt32: HotKeyIntent] = [:]
    nonisolated(unsafe) private var registeredHotKeys: [EventHotKeyRef] = []
    nonisolated(unsafe) private var globalMonitor: Any?
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?

    init(
        configuration: HotKeyConfiguration = .default,
        installEventHandlerOverride: (() -> Bool)? = nil,
        registerOverride: ((HotKeyBinding, UInt32) -> OSStatus)? = nil,
        handler: @escaping (HotKeyIntent) -> Void
    ) {
        self.configuration = configuration.isValid ? configuration : .default
        self.installEventHandlerOverride = installEventHandlerOverride
        self.registerOverride = registerOverride
        self.handler = handler
    }

    @discardableResult
    func start() -> HotKeyRegistrationReport {
        guard !started else { return .notStarted }
        started = true
        var issues: [HotKeyRegistrationIssue] = []
        var monitoredBindings = configuration.allBindings.filter {
            $0.shortcut.keyCode == nil
        }
        let keyBindings = configuration.allBindings.filter {
            $0.shortcut.keyCode != nil
        }

        if installEventHandlerOverride?() ?? installEventHandler() {
            for (offset, binding) in keyBindings.enumerated() {
                let identifier = UInt32(offset + 1)
                let status = registerOverride?(binding, identifier)
                    ?? register(binding, identifier: identifier)
                if status != noErr {
                    issues.append(HotKeyRegistrationIssue(
                        intent: binding.intent,
                        shortcut: binding.shortcut,
                        status: status
                    ))
                    monitoredBindings.append(binding)
                }
            }
        } else {
            for binding in keyBindings {
                issues.append(HotKeyRegistrationIssue(
                    intent: binding.intent,
                    shortcut: binding.shortcut,
                    status: OSStatus(eventInternalErr)
                ))
            }
            monitoredBindings.append(contentsOf: keyBindings)
        }

        startEventMonitors(for: monitoredBindings)
        return HotKeyRegistrationReport(
            issues: issues,
            usesEventMonitorFallback: !monitoredBindings.isEmpty
        )
    }

    func stop() {
        guard started else { return }
        started = false
        for hotKey in registeredHotKeys {
            UnregisterEventHotKey(hotKey)
        }
        registeredHotKeys.removeAll()
        intentByIdentifier.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        stateMachine = HotKeyStateMachine(bindings: [])
    }

    deinit {
        for hotKey in registeredHotKeys {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func installEventHandler() -> Bool {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let status = InstallEventHandler(
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
                      hotKeyID.signature == GlobalHotKeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in manager.handleNativeHotKey(identifier: hotKeyID.id) }
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        guard status == noErr else { return false }
        eventHandler = installedHandler
        return true
    }

    private func register(_ binding: HotKeyBinding, identifier: UInt32) -> OSStatus {
        guard let keyCode = binding.shortcut.keyCode else { return noErr }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        var registeredHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            Self.carbonModifiers(binding.shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        if status == noErr, let registeredHotKey {
            registeredHotKeys.append(registeredHotKey)
            intentByIdentifier[identifier] = binding.intent
        }
        return status
    }

    private func startEventMonitors(for bindings: [HotKeyBinding]) {
        guard !bindings.isEmpty else { return }
        stateMachine = HotKeyStateMachine(bindings: bindings)
        var mask: NSEvent.EventTypeMask = []
        if bindings.contains(where: { $0.shortcut.keyCode == nil }) {
            mask.insert(.flagsChanged)
        }
        if bindings.contains(where: { $0.shortcut.keyCode != nil }) {
            mask.insert(.keyDown)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handleMonitoredEvent(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMonitoredEvent(event)
            return event
        }
    }

    private func handleNativeHotKey(identifier: UInt32) {
        guard let intent = intentByIdentifier[identifier] else { return }
        handler(intent)
    }

    private func handleMonitoredEvent(_ event: NSEvent) {
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

    static func carbonModifiers(_ modifiers: HotKeyModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.function) { result |= UInt32(kEventKeyModifierFnMask) }
        return result
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> HotKeyModifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: HotKeyModifiers = []
        if flags.contains(.function) { result.insert(.function) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}

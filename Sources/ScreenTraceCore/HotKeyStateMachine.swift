import Foundation

public struct HotKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let function = HotKeyModifiers(rawValue: 1 << 0)
    public static let control = HotKeyModifiers(rawValue: 1 << 1)
    public static let command = HotKeyModifiers(rawValue: 1 << 2)
    public static let option = HotKeyModifiers(rawValue: 1 << 3)
    public static let shift = HotKeyModifiers(rawValue: 1 << 4)
    public static let capsLock = HotKeyModifiers(rawValue: 1 << 5)

    public static let configurable: HotKeyModifiers = [
        .function, .control, .command, .option, .shift
    ]
}

public enum HotKeyEventKind: Sendable {
    case flagsChanged
    case keyDown
}

public struct HotKeyInput: Sendable {
    public let kind: HotKeyEventKind
    public let keyCode: UInt16
    public let modifiers: HotKeyModifiers
    public let isRepeat: Bool

    public init(
        kind: HotKeyEventKind,
        keyCode: UInt16,
        modifiers: HotKeyModifiers,
        isRepeat: Bool = false
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

public enum HotKeyIntent: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case quickScreenshot
    case toggleActionCenter
}

public enum HotKeyShortcutValidationError: String, Error, Equatable, Sendable {
    case missingModifier
    case modifierOnlyRequiresFunction
    case modifierOnlyRequiresTwoModifiers
    case unsupportedModifier
}

public struct HotKeyShortcut: Codable, Equatable, Hashable, Sendable {
    /// Nil represents a modifier-only chord such as Fn + Control.
    public let keyCode: UInt16?
    public let modifiers: HotKeyModifiers

    public init(keyCode: UInt16?, modifiers: HotKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.configurable)
    }

    public var validationError: HotKeyShortcutValidationError? {
        if modifiers != modifiers.intersection(.configurable) {
            return .unsupportedModifier
        }
        if keyCode == nil {
            guard modifiers.contains(.function) else {
                return .modifierOnlyRequiresFunction
            }
            guard modifiers.rawValue.nonzeroBitCount >= 2 else {
                return .modifierOnlyRequiresTwoModifiers
            }
            return nil
        }
        let activationModifiers: HotKeyModifiers = [.function, .control, .command, .option]
        return modifiers.intersection(activationModifiers).isEmpty ? .missingModifier : nil
    }

    public var isValid: Bool { validationError == nil }

    public static let defaultQuickScreenshot = HotKeyShortcut(
        keyCode: nil,
        modifiers: [.function, .control]
    )
    public static let defaultActionCenter = HotKeyShortcut(
        keyCode: HotKeyStateMachine.spaceKeyCode,
        modifiers: [.function]
    )
    public static let fallbackQuickScreenshot = HotKeyShortcut(
        keyCode: 18,
        modifiers: [.control, .option]
    )
    public static let fallbackActionCenter = HotKeyShortcut(
        keyCode: 19,
        modifiers: [.control, .option]
    )
}

public struct HotKeyBinding: Equatable, Sendable {
    public let intent: HotKeyIntent
    public let shortcut: HotKeyShortcut

    public init(intent: HotKeyIntent, shortcut: HotKeyShortcut) {
        self.intent = intent
        self.shortcut = shortcut
    }
}

public enum HotKeyConfigurationError: String, Error, Equatable, Sendable {
    case duplicatePrimaryShortcut
    case quickScreenshotConflictsWithActionCenterFallback
    case actionCenterConflictsWithQuickScreenshotFallback
    case invalidQuickScreenshot
    case invalidActionCenter
}

public struct HotKeyConfiguration: Equatable, Sendable {
    public let quickScreenshot: HotKeyShortcut
    public let actionCenter: HotKeyShortcut

    public init(
        quickScreenshot: HotKeyShortcut = .defaultQuickScreenshot,
        actionCenter: HotKeyShortcut = .defaultActionCenter
    ) {
        self.quickScreenshot = quickScreenshot
        self.actionCenter = actionCenter
    }

    public var validationError: HotKeyConfigurationError? {
        guard quickScreenshot.isValid else { return .invalidQuickScreenshot }
        guard actionCenter.isValid else { return .invalidActionCenter }
        guard quickScreenshot != actionCenter else { return .duplicatePrimaryShortcut }
        guard quickScreenshot != .fallbackActionCenter else {
            return .quickScreenshotConflictsWithActionCenterFallback
        }
        guard actionCenter != .fallbackQuickScreenshot else {
            return .actionCenterConflictsWithQuickScreenshotFallback
        }
        return nil
    }

    public var isValid: Bool { validationError == nil }

    public var allBindings: [HotKeyBinding] {
        let candidates = [
            HotKeyBinding(intent: .quickScreenshot, shortcut: quickScreenshot),
            HotKeyBinding(intent: .toggleActionCenter, shortcut: actionCenter),
            HotKeyBinding(intent: .quickScreenshot, shortcut: .fallbackQuickScreenshot),
            HotKeyBinding(intent: .toggleActionCenter, shortcut: .fallbackActionCenter)
        ]
        var seen: Set<HotKeyBindingIdentity> = []
        return candidates.filter {
            seen.insert(HotKeyBindingIdentity(intent: $0.intent, shortcut: $0.shortcut)).inserted
        }
    }

    public static let `default` = HotKeyConfiguration()
}

private struct HotKeyBindingIdentity: Hashable {
    let intent: HotKeyIntent
    let shortcut: HotKeyShortcut
}

public struct HotKeyStateMachine: Sendable {
    public static let spaceKeyCode: UInt16 = 49

    private let bindings: [HotKeyBinding]
    private var pressedModifierIntents: Set<HotKeyIntent> = []

    public init(bindings: [HotKeyBinding] = [
        HotKeyBinding(intent: .quickScreenshot, shortcut: .defaultQuickScreenshot),
        HotKeyBinding(intent: .toggleActionCenter, shortcut: .defaultActionCenter)
    ]) {
        self.bindings = bindings.filter(\.shortcut.isValid)
    }

    public mutating func handle(_ input: HotKeyInput) -> HotKeyIntent? {
        let normalizedModifiers = input.modifiers.intersection(.configurable)
        switch input.kind {
        case .flagsChanged:
            var nextPressed: Set<HotKeyIntent> = []
            var triggered: HotKeyIntent?
            for binding in bindings where binding.shortcut.keyCode == nil {
                let matches = binding.shortcut.modifiers == normalizedModifiers
                if matches {
                    nextPressed.insert(binding.intent)
                    if !pressedModifierIntents.contains(binding.intent), triggered == nil {
                        triggered = binding.intent
                    }
                }
            }
            pressedModifierIntents = nextPressed
            return triggered

        case .keyDown:
            guard !input.isRepeat else { return nil }
            return bindings.first {
                $0.shortcut.keyCode == input.keyCode
                    && $0.shortcut.modifiers == normalizedModifiers
            }?.intent
        }
    }
}

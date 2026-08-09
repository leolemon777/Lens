import Foundation

public struct HotKeyModifiers: OptionSet, Sendable {
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

public enum HotKeyIntent: Equatable, Sendable {
    case quickScreenshot
    case toggleActionCenter
}

public struct HotKeyStateMachine: Sendable {
    public static let spaceKeyCode: UInt16 = 49

    private var quickScreenshotIsPressed = false

    public init() {}

    public mutating func handle(_ input: HotKeyInput) -> HotKeyIntent? {
        let disallowed: HotKeyModifiers = [.command, .option, .shift, .capsLock]
        let hasDisallowed = !input.modifiers.intersection(disallowed).isEmpty

        switch input.kind {
        case .flagsChanged:
            let matches = input.modifiers.contains([.function, .control]) && !hasDisallowed
            defer { quickScreenshotIsPressed = matches }
            return matches && !quickScreenshotIsPressed ? .quickScreenshot : nil

        case .keyDown:
            guard !input.isRepeat,
                  input.keyCode == Self.spaceKeyCode,
                  input.modifiers.contains(.function),
                  !input.modifiers.contains(.control),
                  !hasDisallowed else {
                return nil
            }
            return .toggleActionCenter
        }
    }
}

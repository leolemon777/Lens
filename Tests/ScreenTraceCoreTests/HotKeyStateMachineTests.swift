import XCTest
@testable import ScreenTraceCore

final class HotKeyStateMachineTests: XCTestCase {
    func testFnControlTriggersQuickScreenshotOncePerPress() {
        var machine = HotKeyStateMachine()
        let pressed = HotKeyInput(
            kind: .flagsChanged,
            keyCode: 59,
            modifiers: [.function, .control]
        )

        XCTAssertEqual(machine.handle(pressed), .quickScreenshot)
        XCTAssertNil(machine.handle(pressed))
        XCTAssertNil(machine.handle(HotKeyInput(kind: .flagsChanged, keyCode: 59, modifiers: [])))
        XCTAssertEqual(machine.handle(pressed), .quickScreenshot)
    }

    func testFnSpaceTogglesActionCenterAndRejectsRepeats() {
        var machine = HotKeyStateMachine()
        let valid = HotKeyInput(
            kind: .keyDown,
            keyCode: HotKeyStateMachine.spaceKeyCode,
            modifiers: [.function]
        )

        XCTAssertEqual(machine.handle(valid), .toggleActionCenter)
        XCTAssertNil(machine.handle(HotKeyInput(
            kind: .keyDown,
            keyCode: HotKeyStateMachine.spaceKeyCode,
            modifiers: [.function],
            isRepeat: true
        )))
    }

    func testExtraModifiersDoNotTriggerEitherShortcut() {
        var machine = HotKeyStateMachine()
        XCTAssertNil(machine.handle(HotKeyInput(
            kind: .flagsChanged,
            keyCode: 59,
            modifiers: [.function, .control, .shift]
        )))
        XCTAssertNil(machine.handle(HotKeyInput(
            kind: .keyDown,
            keyCode: HotKeyStateMachine.spaceKeyCode,
            modifiers: [.function, .command]
        )))
    }

    func testCustomKeyBindingsAndFallbacksAreMatchedExactly() {
        let configuration = HotKeyConfiguration(
            quickScreenshot: HotKeyShortcut(keyCode: 8, modifiers: [.command, .shift]),
            actionCenter: HotKeyShortcut(keyCode: 9, modifiers: [.control, .option])
        )
        XCTAssertTrue(configuration.isValid)
        var machine = HotKeyStateMachine(bindings: configuration.allBindings)

        XCTAssertEqual(machine.handle(HotKeyInput(
            kind: .keyDown,
            keyCode: 8,
            modifiers: [.command, .shift]
        )), .quickScreenshot)
        XCTAssertEqual(machine.handle(HotKeyInput(
            kind: .keyDown,
            keyCode: 19,
            modifiers: [.control, .option]
        )), .toggleActionCenter)
        XCTAssertNil(machine.handle(HotKeyInput(
            kind: .keyDown,
            keyCode: 8,
            modifiers: [.command, .shift, .option]
        )))
    }

    func testShortcutValidationRejectsUnsafeAndConflictingBindings() {
        XCTAssertEqual(
            HotKeyShortcut(keyCode: 8, modifiers: [.shift]).validationError,
            .missingModifier
        )
        XCTAssertEqual(
            HotKeyShortcut(keyCode: nil, modifiers: [.command, .shift]).validationError,
            .modifierOnlyRequiresFunction
        )
        XCTAssertEqual(
            HotKeyConfiguration(
                quickScreenshot: .defaultActionCenter,
                actionCenter: .defaultActionCenter
            ).validationError,
            .duplicatePrimaryShortcut
        )
        XCTAssertEqual(
            HotKeyConfiguration(
                quickScreenshot: .fallbackActionCenter,
                actionCenter: .defaultActionCenter
            ).validationError,
            .quickScreenshotConflictsWithActionCenterFallback
        )
    }

    func testModifierOnlyCustomShortcutTriggersOncePerPress() {
        let shortcut = HotKeyShortcut(keyCode: nil, modifiers: [.function, .option])
        var machine = HotKeyStateMachine(bindings: [
            HotKeyBinding(intent: .toggleActionCenter, shortcut: shortcut)
        ])
        let pressed = HotKeyInput(
            kind: .flagsChanged,
            keyCode: 58,
            modifiers: [.function, .option]
        )
        XCTAssertEqual(machine.handle(pressed), .toggleActionCenter)
        XCTAssertNil(machine.handle(pressed))
        XCTAssertNil(machine.handle(HotKeyInput(kind: .flagsChanged, keyCode: 58, modifiers: [])))
        XCTAssertEqual(machine.handle(pressed), .toggleActionCenter)
    }
}

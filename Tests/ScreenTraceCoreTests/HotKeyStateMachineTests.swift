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
}

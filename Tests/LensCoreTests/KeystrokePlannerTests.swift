import Foundation
import XCTest
@testable import LensCore

final class KeystrokePlannerTests: XCTestCase {
    func testShortcutEventsBecomeModifierPrefixedCapsules() {
        let displays = KeystrokePlanner().displays(
            events: [
                KeyboardEvent(
                    time: 2,
                    keyCode: 1,
                    label: "S",
                    modifiers: [.command, .shift],
                    isRepeat: false
                ),
                KeyboardEvent(
                    time: 4,
                    keyCode: 53,
                    label: "Escape",
                    modifiers: [],
                    isRepeat: false
                )
            ],
            durationSeconds: 10
        )
        XCTAssertEqual(displays.map(\.text), ["⌘⇧S", "Escape"])
        XCTAssertEqual(displays.map(\.time), [2, 4])
        XCTAssertEqual(displays[0].holdSeconds, 1.15)
    }

    func testRepeatsAndUnlabeledEventsAreSkipped() {
        let displays = KeystrokePlanner().displays(
            events: [
                KeyboardEvent(time: 1, keyCode: 1, label: nil, modifiers: [.command], isRepeat: false),
                KeyboardEvent(time: 2, keyCode: 1, label: "S", modifiers: [.command], isRepeat: true),
                KeyboardEvent(time: 3, keyCode: 1, label: "  ", modifiers: [.command], isRepeat: false)
            ],
            durationSeconds: 10
        )
        XCTAssertTrue(displays.isEmpty)
    }

    func testEventsOutsideRecordingSpanAreDropped() {
        let displays = KeystrokePlanner().displays(
            events: [
                // KeyboardEvent already clamps negative times to zero on init,
                // so a leading event survives and lands at t=0.
                KeyboardEvent(time: -1, keyCode: 1, label: "S", modifiers: [.command], isRepeat: false),
                KeyboardEvent(time: 99, keyCode: 1, label: "S", modifiers: [.command], isRepeat: false),
                KeyboardEvent(time: 5, keyCode: 1, label: "S", modifiers: [.command], isRepeat: false)
            ],
            durationSeconds: 6
        )
        XCTAssertEqual(displays.map(\.time), [0, 5])
    }

    func testFunctionAndCapsLockNeverAddSymbols() {
        XCTAssertEqual(
            KeystrokePlanner.displayText(for: KeyboardEvent(
                time: 0,
                keyCode: 1,
                label: "F1",
                modifiers: [.function, .capsLock],
                isRepeat: false
            )),
            "F1"
        )
    }

    func testInteractionDecodesLegacyPlansWithoutKeystrokes() throws {
        let legacy = Data("""
        {"showsClickPulse":true,"clickEffect":"ripple","clickEffectStrength":1,"clickPulseScale":1.25,"clickPulseColorHex":"#FF684D","clickPulses":[]}
        """.utf8)
        let interaction = try JSONDecoder().decode(
            AutoEditPlan.Interaction.self,
            from: legacy
        )
        XCTAssertFalse(interaction.showsKeystrokes)
        XCTAssertTrue(interaction.keystrokes.isEmpty)

        let encoded = try JSONEncoder().encode(AutoEditPlan.Interaction(
            showsKeystrokes: true,
            keystrokes: [AutoEditPlan.KeystrokeDisplay(time: 1, text: "⌘S")]
        ))
        let decoded = try JSONDecoder().decode(
            AutoEditPlan.Interaction.self,
            from: encoded
        )
        XCTAssertTrue(decoded.showsKeystrokes)
        XCTAssertEqual(decoded.keystrokes.first?.text, "⌘S")
    }
}

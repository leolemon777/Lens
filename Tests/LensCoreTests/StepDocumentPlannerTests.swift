import Foundation
import XCTest
@testable import LensCore

final class StepDocumentPlannerTests: XCTestCase {
    private func click(
        _ time: Double,
        x: Double = 0.5,
        y: Double = 0.5,
        button: PointerButton = .left,
        clickCount: Int = 1
    ) -> ClickEvent {
        ClickEvent(
            time: time,
            button: button,
            phase: .down,
            location: LensPoint(x: x, y: y),
            normalizedLocation: LensPoint(x: x, y: y),
            displayID: 1,
            clickCount: clickCount
        )
    }

    func testBurstClicksMergeIntoOneStepWithAppContext() {
        let document = StepDocumentPlanner().document(
            clicks: [
                click(1.0),
                click(1.2),
                click(1.35),
                click(6.0)
            ],
            windows: [
                WindowEvent(time: 0, applicationName: "Safari", bundleIdentifier: "com.apple.Safari"),
                WindowEvent(time: 5, applicationName: "访达", bundleIdentifier: "com.apple.finder")
            ],
            durationSeconds: 10
        )
        XCTAssertEqual(document.steps.count, 2)
        XCTAssertEqual(document.steps[0].time, 1.0, accuracy: 0.000_1)
        XCTAssertEqual(document.steps[0].title, "在 Safari 中点击")
        XCTAssertEqual(document.steps[1].title, "在 访达 中点击")
    }

    func testRightClickAndDoubleClickGetDistinctVerbs() {
        let document = StepDocumentPlanner().document(
            clicks: [
                click(1, button: .right),
                click(3, clickCount: 2)
            ],
            windows: [],
            durationSeconds: 5
        )
        XCTAssertEqual(document.steps.map(\.title), ["右键点击", "双击"])
    }

    func testDetailNamesTheNineRegionGrid() {
        XCTAssertEqual(StepDocumentPlanner.regionName(for: LensPoint(x: 0.1, y: 0.1)), "左上")
        XCTAssertEqual(StepDocumentPlanner.regionName(for: LensPoint(x: 0.5, y: 0.5)), "中部")
        XCTAssertEqual(StepDocumentPlanner.regionName(for: LensPoint(x: 0.9, y: 0.9)), "右下")
        XCTAssertEqual(StepDocumentPlanner.regionName(for: LensPoint(x: 0.9, y: 0.1)), "右上")

        let document = StepDocumentPlanner().document(
            clicks: [click(1, x: 0.9, y: 0.1)],
            windows: [],
            durationSeconds: 4
        )
        XCTAssertEqual(document.steps.first?.detail, "画面右上")
    }

    func testMaximumStepsCapAndClickUpEventsAreIgnored() {
        var clicks: [ClickEvent] = []
        for index in 0..<80 {
            clicks.append(click(Double(index) * 2, x: 0.5, y: 0.5))
            clicks.append(ClickEvent(
                time: Double(index) * 2 + 0.1,
                button: .left,
                phase: .up,
                location: LensPoint(x: 0.5, y: 0.5),
                normalizedLocation: LensPoint(x: 0.5, y: 0.5),
                displayID: 1,
                clickCount: 1
            ))
        }
        let document = StepDocumentPlanner().document(
            clicks: clicks,
            windows: [],
            durationSeconds: 200
        )
        XCTAssertEqual(document.steps.count, 60)
        XCTAssertEqual(document.steps.first?.index, 1)
        XCTAssertEqual(document.steps.last?.index, 60)
    }

    func testMarkdownReferencesPerStepFrames() {
        let document = StepDocumentPlanner().document(
            clicks: [click(65)],
            windows: [WindowEvent(time: 0, applicationName: "Xcode", bundleIdentifier: nil)],
            durationSeconds: 70
        )
        let markdown = document.markdown
        XCTAssertTrue(markdown.contains("# 操作步骤"))
        XCTAssertTrue(markdown.contains("共 1 步 · 录制时长 1:10"))
        XCTAssertTrue(markdown.contains("1. **[1:05] 在 Xcode 中点击**"))
        XCTAssertTrue(markdown.contains("step-01.png"))
    }
}

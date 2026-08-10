import Foundation
import XCTest
@testable import ScreenTraceCore

final class ScreenshotEditPlanTests: XCTestCase {
    func testPlanRoundTripsAllAnnotationKinds() throws {
        let annotations = ScreenshotAnnotationKind.allCases.enumerated().map { index, kind in
            let text: String? = switch kind {
            case .text: "ScreenTrace"
            case .step: "1"
            default: nil
            }
            return ScreenshotAnnotation(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                kind: kind,
                bounds: TraceRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2),
                start: kind == .arrow ? TracePoint(x: 0.1, y: 0.2) : nil,
                end: kind == .arrow ? TracePoint(x: 0.4, y: 0.4) : nil,
                points: kind == .freehand
                    ? [TracePoint(x: 0.1, y: 0.2), TracePoint(x: 0.4, y: 0.4)]
                    : nil,
                text: text,
                style: ScreenshotAnnotationStyle(
                    lineWidth: 0.008,
                    fontSize: 0.05,
                    color: .orange,
                    fillColor: TraceColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.12),
                    intensity: 0.04
                )
            )
        }
        let plan = ScreenshotEditPlan(
            sourceDimensions: TraceDimensions(width: 1_440, height: 900),
            annotations: annotations,
            canvasStyle: ScreenshotCanvasStyle(
                backgroundKind: .gradient,
                primaryColor: .blue,
                secondaryColor: .orange,
                padding: 0.1,
                cornerRadius: 0.04,
                shadowRadius: 0.05,
                shadowOpacity: 0.4,
                aspectRatio: .widescreen16x9
            )
        )

        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(ScreenshotEditPlan.self, from: data)

        XCTAssertEqual(decoded, plan)
        XCTAssertEqual(decoded.annotations.map(\.kind), ScreenshotAnnotationKind.allCases)
        XCTAssertEqual(decoded.schemaVersion, ScreenshotEditPlan.currentSchemaVersion)
    }

    func testCanvasPlannerPreservesPaddingAndExpandsWithoutCropping() {
        let style = ScreenshotCanvasStyle(
            padding: 0.1,
            aspectRatio: .square
        )
        let layout = ScreenshotCanvasPlanner.layout(
            sourceDimensions: TraceDimensions(width: 1_000, height: 500),
            style: style
        )

        XCTAssertEqual(layout.outputDimensions, TraceDimensions(width: 1_100, height: 1_100))
        XCTAssertEqual(
            layout.sourceFrame,
            TraceRect(x: 50, y: 300, width: 1_000, height: 500)
        )
    }

    func testLegacyPointTwoPlanDecodesWithoutCanvasStyle() throws {
        let json = """
        {
          "schemaVersion": "0.2",
          "sourceDimensions": { "width": 800, "height": 500 },
          "annotations": []
        }
        """
        let plan = try JSONDecoder().decode(ScreenshotEditPlan.self, from: Data(json.utf8))

        XCTAssertEqual(plan.schemaVersion, "0.2")
        XCTAssertNil(plan.canvasStyle)
        XCTAssertEqual(
            ScreenshotCanvasPlanner.layout(
                sourceDimensions: plan.sourceDimensions,
                style: plan.canvasStyle
            ).outputDimensions,
            plan.sourceDimensions
        )
    }
}

import Foundation
import XCTest

final class G0BaselineScenarioTests: XCTestCase {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let updatedAt: String
        let scenarios: [Scenario]
    }

    private struct Scenario: Decodable {
        let id: String
        let gate: String
        let area: String
        let title: String
        let evidenceLevel: String
        let automation: String
        let steps: [String]
        let expected: [String]
    }

    func testManifestKeepsThirtyStableUniqueScenarios() throws {
        let manifest = try loadManifest()
        let expectedIDs = Set((1...30).map { String(format: "ST-G0-%03d", $0) })

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.updatedAt, "2026-08-13")
        XCTAssertEqual(manifest.scenarios.count, 30)
        XCTAssertEqual(Set(manifest.scenarios.map(\.id)), expectedIDs)
        XCTAssertEqual(Set(manifest.scenarios.map(\.id)).count, manifest.scenarios.count)

        let gates = Set(manifest.scenarios.flatMap { scenario in
            scenario.gate.split(separator: "+").map(String.init)
        })
        XCTAssertTrue(gates.isSuperset(of: ["G1", "G2", "G3", "G4", "G5"]))
    }

    func testEveryScenarioHasExecutableEvidenceWithoutPrivatePaths() throws {
        let manifest = try loadManifest()
        let allowedAutomation = Set(["automatic", "hybrid", "manual"])
        let privateMarkers = ["/Users/", "file://", "@example.com"]

        for scenario in manifest.scenarios {
            XCTAssertFalse(scenario.area.isEmpty, scenario.id)
            XCTAssertFalse(scenario.title.isEmpty, scenario.id)
            XCTAssertTrue(scenario.evidenceLevel.hasPrefix("E"), scenario.id)
            XCTAssertTrue(allowedAutomation.contains(scenario.automation), scenario.id)
            XCTAssertGreaterThanOrEqual(scenario.steps.count, 2, scenario.id)
            XCTAssertFalse(scenario.expected.isEmpty, scenario.id)

            let content = ([scenario.title] + scenario.steps + scenario.expected)
                .joined(separator: " ")
            for marker in privateMarkers {
                XCTAssertFalse(content.contains(marker), "\(scenario.id) contains \(marker)")
            }
        }
    }

    private func loadManifest() throws -> Manifest {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = projectRoot.appendingPathComponent("Config/G0BaselineScenarios.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
}

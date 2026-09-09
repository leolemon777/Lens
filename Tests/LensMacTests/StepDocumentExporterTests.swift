import Foundation
import ImageIO
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class StepDocumentExporterTests: XCTestCase {
    func testExporterWritesMarkdownAndOneFramePerStepWithoutVideo() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdownURL = directory.appendingPathComponent("操作步骤.md")
        let document = StepDocument(
            steps: [
                .init(index: 1, time: 1.25, title: "点击", detail: "画面左上"),
                .init(index: 2, time: 61.5, title: "双击")
            ],
            durationSeconds: 72
        )
        var receivedTimes: [Double] = []
        let exporter = StepDocumentExporter(document: document) { time, imageURL in
            receivedTimes.append(time)
            try Data("PNG-\(time)".utf8).write(to: imageURL, options: .atomic)
        }

        try await exporter.write(to: markdownURL)

        XCTAssertEqual(receivedTimes, [1.25, 61.5])
        XCTAssertEqual(
            try String(contentsOf: markdownURL, encoding: .utf8),
            document.markdown(imageDirectory: "操作步骤.assets")
        )
        XCTAssertEqual(
            try String(
                contentsOf: directory
                    .appendingPathComponent("操作步骤.assets")
                    .appendingPathComponent("step-01.png"),
                encoding: .utf8
            ),
            "PNG-1.25"
        )
        XCTAssertEqual(
            try String(
                contentsOf: directory
                    .appendingPathComponent("操作步骤.assets")
                    .appendingPathComponent("step-02.png"),
                encoding: .utf8
            ),
            "PNG-61.5"
        )
    }

    func testEmptyDocumentFailsBeforeFrameWriterRuns() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var writerWasCalled = false
        let exporter = StepDocumentExporter(
            document: StepDocument(steps: [], durationSeconds: 0)
        ) { _, _ in
            writerWasCalled = true
        }

        do {
            try await exporter.write(to: directory.appendingPathComponent("empty.md"))
            XCTFail("Expected an empty document to be rejected")
        } catch let error as StepDocumentExportError {
            guard case .noSteps = error else {
                XCTFail("Unexpected export error: \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(writerWasCalled)
    }

    func testFrameFailureDoesNotLeavePartialExportArtifacts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdownURL = directory.appendingPathComponent("操作步骤.md")
        let document = StepDocument(
            steps: [
                .init(index: 1, time: 1, title: "第一步"),
                .init(index: 2, time: 2, title: "第二步")
            ],
            durationSeconds: 3
        )
        var callCount = 0
        let exporter = StepDocumentExporter(document: document) { _, imageURL in
            callCount += 1
            if callCount == 2 {
                throw NSError(domain: "StepDocumentExporterTests", code: 2)
            }
            try Data("PNG".utf8).write(to: imageURL, options: .atomic)
        }

        do {
            try await exporter.write(to: markdownURL)
            XCTFail("Expected the second frame to fail")
        } catch {
            XCTAssertEqual(callCount, 2)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markdownURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("操作步骤.assets")
                    .appendingPathComponent("step-01.png")
                    .path
            )
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".lens-step-export-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testDestinationConflictIsRejectedBeforeFrameWriterRuns() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var writerCallCount = 0
        let document = StepDocument(
            steps: [
                .init(index: 1, time: 1, title: "第一步"),
                .init(index: 1, time: 2, title: "重复步骤")
            ],
            durationSeconds: 3
        )
        let exporter = StepDocumentExporter(document: document) { _, _ in
            writerCallCount += 1
        }

        do {
            try await exporter.write(to: directory.appendingPathComponent("操作步骤.md"))
            XCTFail("Expected duplicate step names to be rejected")
        } catch let error as StepDocumentExportError {
            guard case .destinationConflict = error else {
                XCTFail("Unexpected export error: \(error)")
                return
            }
        }
        XCTAssertEqual(writerCallCount, 0)
    }

    func testExporterExtractsRealFramesFromSyntheticVideo() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("source.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: videoURL,
            frameCount: 24,
            framesPerSecond: 24,
            width: 320,
            height: 180
        )
        let markdownURL = directory.appendingPathComponent("操作步骤.md")
        let document = StepDocument(
            steps: [
                .init(index: 1, time: 0.25, title: "点击"),
                .init(index: 2, time: 0.75, title: "双击")
            ],
            durationSeconds: 1
        )

        try await StepDocumentExporter(document: document, videoURL: videoURL)
            .write(to: markdownURL)

        let frameURL = directory
            .appendingPathComponent("操作步骤.assets")
            .appendingPathComponent("step-01.png")
        guard let source = CGImageSourceCreateWithURL(frameURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("The exporter must write a readable PNG frame")
            return
        }
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 180)
        XCTAssertEqual(
            CGImageSourceGetType(source) as String?,
            "public.png"
        )
        XCTAssertEqual(
            try String(contentsOf: markdownURL, encoding: .utf8),
            document.markdown(imageDirectory: "操作步骤.assets")
        )
    }

    func testExistingUserDirectoryIsNeverUsedAsExportAssets() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let userDirectory = directory.appendingPathComponent("操作步骤.assets", isDirectory: true)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let userFile = userDirectory.appendingPathComponent("用户资料.txt")
        try Data("keep".utf8).write(to: userFile)

        let document = StepDocument(
            steps: [.init(index: 1, time: 1, title: "一步")],
            durationSeconds: 2
        )
        let exporter = StepDocumentExporter(document: document) { _, imageURL in
            try Data("PNG".utf8).write(to: imageURL, options: .atomic)
        }

        do {
            try await exporter.write(to: directory.appendingPathComponent("操作步骤.md"))
            XCTFail("Expected a user-owned assets directory to be rejected")
        } catch let error as StepDocumentExportError {
            guard case .unsafeDestination(userDirectory) = error else {
                XCTFail("Unexpected export error: \(error)")
                return
            }
        }
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "keep")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("操作步骤.md").path
            )
        )
    }

    func testDifferentMarkdownFilesUseIndependentAssetDirectories() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = StepDocument(
            steps: [.init(index: 1, time: 1, title: "第一步")],
            durationSeconds: 2
        )
        let second = StepDocument(
            steps: [.init(index: 1, time: 2, title: "第二步")],
            durationSeconds: 3
        )
        try await StepDocumentExporter(document: first) { _, imageURL in
            try Data("FIRST".utf8).write(to: imageURL, options: .atomic)
        }.write(to: directory.appendingPathComponent("第一份.md"))
        try await StepDocumentExporter(document: second) { _, imageURL in
            try Data("SECOND".utf8).write(to: imageURL, options: .atomic)
        }.write(to: directory.appendingPathComponent("第二份.md"))

        XCTAssertEqual(
            try String(
                contentsOf: directory
                    .appendingPathComponent("第一份.assets")
                    .appendingPathComponent("step-01.png"),
                encoding: .utf8
            ),
            "FIRST"
        )
        XCTAssertEqual(
            try String(
                contentsOf: directory
                    .appendingPathComponent("第二份.assets")
                    .appendingPathComponent("step-01.png"),
                encoding: .utf8
            ),
            "SECOND"
        )
        XCTAssertTrue(
            try String(contentsOf: directory.appendingPathComponent("第一份.md"), encoding: .utf8)
                .contains("第一份.assets/step-01.png")
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepDocumentExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

import Foundation
import XCTest
@testable import ScreenTraceMac

final class CameraTrackRecorderTests: XCTestCase {
    @MainActor
    func testValidatorAcceptsSyntheticVideoTrack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceCameraTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("camera.mp4")
        try await SyntheticVideoFactory.makeVideo(at: url, frameCount: 12, framesPerSecond: 24)

        try await CameraTrackRecorder.validateVideoTrack(at: url)
    }

    @MainActor
    func testValidatorRejectsEmptyCameraTrack() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceEmptyCamera-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try await CameraTrackRecorder.validateVideoTrack(at: url)
            XCTFail("An empty camera track must not validate")
        } catch CameraTrackRecordingError.emptyTrack {
            // Expected: an empty placeholder must be removed from the manifest.
        } catch {
            XCTFail("Unexpected validation error: \(error)")
        }
    }
}

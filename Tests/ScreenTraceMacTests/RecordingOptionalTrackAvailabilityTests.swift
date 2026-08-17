import XCTest
@testable import ScreenTraceMac

final class RecordingOptionalTrackAvailabilityTests: XCTestCase {
    func testDisconnectedOptionalTrackStaysDisabledForResumedSegments() {
        let options = ScreenRecordingOptions(
            capturesMicrophone: true,
            capturesCamera: true
        )
        var availability = RecordingOptionalTrackAvailability()

        XCTAssertTrue(availability.isEnabled(.microphone, requestedOptions: options))
        XCTAssertTrue(availability.isEnabled(.camera, requestedOptions: options))

        XCTAssertTrue(availability.disable(.microphone))
        XCTAssertFalse(availability.disable(.microphone), "重复回调不能重复通知用户")
        XCTAssertFalse(availability.isEnabled(.microphone, requestedOptions: options))
        XCTAssertTrue(availability.isEnabled(.camera, requestedOptions: options))
    }

    func testNewRecordingProbesPreviouslyDisconnectedTracksAgain() {
        let options = ScreenRecordingOptions(
            capturesMicrophone: true,
            capturesCamera: true
        )
        var previousSession = RecordingOptionalTrackAvailability()
        previousSession.disable(.camera)

        let nextSession = RecordingOptionalTrackAvailability()

        XCTAssertFalse(previousSession.isEnabled(.camera, requestedOptions: options))
        XCTAssertTrue(nextSession.isEnabled(.camera, requestedOptions: options))
    }

    func testUnrequestedOptionalTracksNeverBecomeEnabled() {
        let options = ScreenRecordingOptions(
            capturesMicrophone: false,
            capturesCamera: false
        )
        let availability = RecordingOptionalTrackAvailability()

        XCTAssertFalse(availability.isEnabled(.microphone, requestedOptions: options))
        XCTAssertFalse(availability.isEnabled(.camera, requestedOptions: options))
    }
}

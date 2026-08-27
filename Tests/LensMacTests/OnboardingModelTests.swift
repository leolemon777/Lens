import XCTest
@testable import LensMac

@MainActor
final class OnboardingModelTests: XCTestCase {
    private func makeDefaults(
        function: String = #function
    ) throws -> UserDefaults {
        let name = "OnboardingModelTests.\(function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeModel(
        defaults: UserDefaults,
        states: [SystemPermissionKind: PermissionAccessState] = [:]
    ) -> OnboardingModel {
        OnboardingModel(defaults: defaults, stateProvider: { states })
    }

    // MARK: - Tiers

    func testShippedShortcutsMakeAccessibilityEssentialRatherThanOptional() {
        // The default shortcuts are modifier-only, carry no key code, and are
        // therefore delivered by a global monitor instead of Carbon. Demoting
        // this permission would let a first run end with a shortcut that
        // silently does nothing.
        XCTAssertEqual(SystemPermissionKind.accessibility.onboardingTier, .essential)
        XCTAssertEqual(SystemPermissionKind.screenCapture.onboardingTier, .essential)
    }

    func testEventTrackPermissionIsSmartAndOptionalTracksStayOptional() {
        XCTAssertEqual(SystemPermissionKind.inputMonitoring.onboardingTier, .smart)
        XCTAssertEqual(SystemPermissionKind.microphone.onboardingTier, .optional)
        XCTAssertEqual(SystemPermissionKind.camera.onboardingTier, .optional)
        XCTAssertEqual(SystemPermissionKind.speechRecognition.onboardingTier, .optional)
    }

    func testEveryPermissionKindIsClassifiedExactlyOnce() {
        let classified = OnboardingModel.kinds(in: .essential)
            + OnboardingModel.kinds(in: .smart)
            + OnboardingModel.kinds(in: .optional)

        XCTAssertEqual(
            Set(classified),
            Set(SystemPermissionKind.allCases)
        )
        XCTAssertEqual(classified.count, SystemPermissionKind.allCases.count)
    }

    // MARK: - Satisfaction

    func testEssentialsAreNotSatisfiedWhileAnyRequiredPermissionIsMissing() throws {
        let defaults = try makeDefaults()
        let model = makeModel(defaults: defaults, states: [
            .screenCapture: .granted,
            .accessibility: .denied
        ])

        XCTAssertFalse(model.areEssentialsSatisfied)
    }

    func testEssentialsAreSatisfiedWhenEveryRequiredPermissionIsGranted() throws {
        let defaults = try makeDefaults()
        let model = makeModel(defaults: defaults, states: [
            .screenCapture: .granted,
            .accessibility: .granted
        ])

        XCTAssertTrue(model.areEssentialsSatisfied)
    }

    func testOptionalPermissionsDoNotAffectEssentials() throws {
        let defaults = try makeDefaults()
        let model = makeModel(defaults: defaults, states: [
            .screenCapture: .granted,
            .accessibility: .granted,
            .microphone: .denied,
            .camera: .denied,
            .speechRecognition: .denied,
            .inputMonitoring: .denied
        ])

        XCTAssertTrue(model.areEssentialsSatisfied)
    }

    // MARK: - Relaunch hint

    func testRelaunchIsNotSuggestedBeforeTheUserHasAskedForScreenRecording() {
        XCTAssertFalse(
            OnboardingModel.suggestsRelaunch(
                didRequestScreenCaptureThisSession: false,
                states: [.screenCapture: .denied]
            )
        )
    }

    func testRelaunchIsSuggestedOnceAskingDidNotChangeTheAnswer() {
        // Granting screen recording never reaches the running process, so this
        // is the only signal available that a reopen is what is missing.
        XCTAssertTrue(
            OnboardingModel.suggestsRelaunch(
                didRequestScreenCaptureThisSession: true,
                states: [.screenCapture: .denied]
            )
        )
    }

    func testRelaunchStopsBeingSuggestedOnceAccessIsReadable() {
        XCTAssertFalse(
            OnboardingModel.suggestsRelaunch(
                didRequestScreenCaptureThisSession: true,
                states: [.screenCapture: .granted]
            )
        )
    }

    // MARK: - First run

    func testGuideIsPresentedUntilItHasBeenCompletedOnce() throws {
        let defaults = try makeDefaults()
        let model = makeModel(defaults: defaults)

        XCTAssertTrue(model.shouldPresentOnLaunch)

        model.markPresentationComplete(build: "20260816083903")

        XCTAssertFalse(makeModel(defaults: defaults).shouldPresentOnLaunch)
    }

    func testUpgradingDoesNotWalkAReturningUserThroughTheGuideAgain() throws {
        let defaults = try makeDefaults()
        makeModel(defaults: defaults).markPresentationComplete(build: "1")

        // A later build must still read as already onboarded.
        XCTAssertFalse(makeModel(defaults: defaults).shouldPresentOnLaunch)
    }

    // MARK: - Navigation

    func testStepsRunFromWelcomeToReadyAndStopAtBothEnds() {
        XCTAssertNil(OnboardingModel.step(before: .welcome))
        XCTAssertEqual(OnboardingModel.step(after: .welcome), .essentials)
        XCTAssertEqual(OnboardingModel.step(after: .essentials), .smart)
        XCTAssertEqual(OnboardingModel.step(after: .smart), .ready)
        XCTAssertNil(OnboardingModel.step(after: .ready))
        XCTAssertEqual(OnboardingModel.step(before: .ready), .smart)
    }

    func testAdvancingIsNeverBlockedByAMissingPermission() throws {
        // A modal wall on first launch is worse than a shortcut that has to be
        // retried, so the guide always lets the user reach the end.
        let defaults = try makeDefaults()
        let model = makeModel(defaults: defaults, states: [
            .screenCapture: .denied,
            .accessibility: .denied
        ])

        model.advance()
        model.advance()
        model.advance()

        XCTAssertEqual(model.step, .ready)
        XCTAssertFalse(model.areEssentialsSatisfied)
    }

    func testAdvancingRechecksPermissionsSoAGrantMadeMidGuideIsPickedUp() throws {
        let defaults = try makeDefaults()
        var states: [SystemPermissionKind: PermissionAccessState] = [
            .screenCapture: .denied,
            .accessibility: .denied
        ]
        let model = OnboardingModel(defaults: defaults, stateProvider: { states })

        XCTAssertFalse(model.areEssentialsSatisfied)
        states = [.screenCapture: .granted, .accessibility: .granted]
        model.advance()

        XCTAssertTrue(model.areEssentialsSatisfied)
    }
}

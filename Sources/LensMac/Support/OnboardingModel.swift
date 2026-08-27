import Foundation
import SwiftUI

/// How much of the product stops working while a system permission is missing.
enum OnboardingPermissionTier: Equatable, Sendable {
    /// Neither golden loop runs at all. The first run cannot be called finished
    /// while one of these is missing.
    case essential

    /// Capture still records, but the automatic camera, redrawn cursor and
    /// click feedback never receive the events they are planned from, so the
    /// result is an ordinary screen recording.
    case smart

    /// Only an optional track or a post-processing step is unavailable.
    case optional
}

extension SystemPermissionKind {
    var onboardingTier: OnboardingPermissionTier {
        switch self {
        case .screenCapture:
            .essential
        case .accessibility:
            // The shipped default shortcuts are modifier-only combinations, so
            // they carry no key code, skip Carbon registration entirely and are
            // delivered by a global event monitor. Without this permission the
            // primary way into the app silently does nothing.
            .essential
        case .inputMonitoring:
            .smart
        case .microphone, .camera, .speechRecognition:
            .optional
        }
    }
}

enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case essentials
    case smart
    case ready

    var id: Int { rawValue }
}

/// First-run guidance. The decisions are plain values so they can be tested
/// without a window, a capture session or a real TCC database.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var step: OnboardingStep = .welcome
    @Published private(set) var states: [SystemPermissionKind: PermissionAccessState] = [:]

    private let defaults: UserDefaults
    private let stateProvider: () -> [SystemPermissionKind: PermissionAccessState]
    private var didRequestScreenCaptureThisSession = false

    private enum PreferenceKey {
        static let completedBuild = "onboarding.completedBuild"
    }

    init(
        defaults: UserDefaults = .standard,
        stateProvider: @escaping () -> [SystemPermissionKind: PermissionAccessState]
            = { PermissionCenterModel.currentStates() }
    ) {
        self.defaults = defaults
        self.stateProvider = stateProvider
        states = stateProvider()
    }

    // MARK: - First run

    /// Whether the guide should open on launch. Recording completion against a
    /// build rather than a bare flag means a user who upgrades is not walked
    /// through the guide again, while a reinstall onto a fresh preference
    /// domain still gets it.
    var shouldPresentOnLaunch: Bool {
        defaults.string(forKey: PreferenceKey.completedBuild) == nil
    }

    func markPresentationComplete(build: String) {
        defaults.set(build, forKey: PreferenceKey.completedBuild)
    }

    // MARK: - Permission state

    func refresh() {
        states = stateProvider()
    }

    func state(for kind: SystemPermissionKind) -> PermissionAccessState {
        states[kind] ?? .notDetermined
    }

    static func kinds(in tier: OnboardingPermissionTier) -> [SystemPermissionKind] {
        SystemPermissionKind.allCases.filter { $0.onboardingTier == tier }
    }

    /// Whether every permission in a tier has been granted.
    static func isSatisfied(
        tier: OnboardingPermissionTier,
        states: [SystemPermissionKind: PermissionAccessState]
    ) -> Bool {
        kinds(in: tier).allSatisfy { states[$0] == .granted }
    }

    var areEssentialsSatisfied: Bool {
        Self.isSatisfied(tier: .essential, states: states)
    }

    /// Granting screen recording in System Settings does not reach a process
    /// that is already running, and a preflight check cannot tell that apart
    /// from a permission that was never granted. Asking during this session and
    /// still reading denied afterwards is the honest signal that the user has
    /// most likely granted it and only needs to reopen the app.
    static func suggestsRelaunch(
        didRequestScreenCaptureThisSession: Bool,
        states: [SystemPermissionKind: PermissionAccessState]
    ) -> Bool {
        didRequestScreenCaptureThisSession
            && states[.screenCapture] != .granted
    }

    var suggestsRelaunch: Bool {
        Self.suggestsRelaunch(
            didRequestScreenCaptureThisSession: didRequestScreenCaptureThisSession,
            states: states
        )
    }

    func noteScreenCaptureRequested() {
        didRequestScreenCaptureThisSession = true
    }

    // MARK: - Navigation

    /// The guide never blocks. A user who wants to grant permissions later can
    /// always reach the end, because a modal wall on first launch is worse than
    /// a shortcut that has to be retried.
    static func step(after step: OnboardingStep) -> OnboardingStep? {
        OnboardingStep(rawValue: step.rawValue + 1)
    }

    static func step(before step: OnboardingStep) -> OnboardingStep? {
        OnboardingStep(rawValue: step.rawValue - 1)
    }

    func advance() {
        guard let next = Self.step(after: step) else { return }
        refresh()
        step = next
    }

    func retreat() {
        guard let previous = Self.step(before: step) else { return }
        step = previous
    }

    func jump(to step: OnboardingStep) {
        self.step = step
    }
}

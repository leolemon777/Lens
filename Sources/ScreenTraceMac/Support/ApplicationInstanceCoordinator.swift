import AppKit
import Foundation

struct RunningScreenTraceInstance: Equatable, Sendable {
    let processIdentifier: pid_t
    let identity: BuildIdentity
}

enum ApplicationInstanceConflict: Equatable, Sendable {
    case none
    case sameBuild(RunningScreenTraceInstance)
    case differentBuild(RunningScreenTraceInstance)
}

enum ApplicationInstanceLaunchDisposition {
    case continueLaunch
    case terminateCurrent
    case waitForOtherApplicationToTerminate(NSRunningApplication)
}

enum ApplicationInstanceConflictDetector {
    static func detect(
        current: BuildIdentity,
        instances: [RunningScreenTraceInstance]
    ) -> ApplicationInstanceConflict {
        guard let running = instances.sorted(by: instanceSort).first else {
            return .none
        }
        return current.isSameBuild(as: running.identity)
            ? .sameBuild(running)
            : .differentBuild(running)
    }

    private static func instanceSort(
        _ lhs: RunningScreenTraceInstance,
        _ rhs: RunningScreenTraceInstance
    ) -> Bool {
        lhs.processIdentifier < rhs.processIdentifier
    }
}

@MainActor
final class ApplicationInstanceCoordinator {
    typealias ApplicationsProvider = (String) -> [NSRunningApplication]

    private let currentIdentity: BuildIdentity
    private let currentProcessIdentifier: pid_t
    private let applicationsProvider: ApplicationsProvider

    init(
        currentIdentity: BuildIdentity = .current,
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        applicationsProvider: @escaping ApplicationsProvider = {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
    ) {
        self.currentIdentity = currentIdentity
        self.currentProcessIdentifier = currentProcessIdentifier
        self.applicationsProvider = applicationsProvider
    }

    func resolveLaunch() -> ApplicationInstanceLaunchDisposition {
        let applications = applicationsProvider(currentIdentity.bundleIdentifier)
            .filter { $0.processIdentifier != currentProcessIdentifier && !$0.isTerminated }
        let snapshots = applications.map { application in
            RunningScreenTraceInstance(
                processIdentifier: application.processIdentifier,
                identity: application.bundleURL
                    .flatMap(Bundle.init(url:))
                    .map(BuildIdentity.init(bundle:))
                    ?? BuildIdentity(
                        version: BuildIdentity.developmentValue,
                        buildNumber: BuildIdentity.developmentValue,
                        bundleIdentifier: currentIdentity.bundleIdentifier,
                        executableURL: application.executableURL
                    )
            )
        }

        switch ApplicationInstanceConflictDetector.detect(
            current: currentIdentity,
            instances: snapshots
        ) {
        case .none:
            return .continueLaunch
        case let .sameBuild(instance):
            activateApplication(with: instance.processIdentifier, in: applications)
            return .terminateCurrent
        case let .differentBuild(instance):
            guard let application = applications.first(where: {
                $0.processIdentifier == instance.processIdentifier
            }) else {
                return .continueLaunch
            }
            return presentConflictAlert(running: application, identity: instance.identity)
        }
    }

    private func presentConflictAlert(
        running application: NSRunningApplication,
        identity runningIdentity: BuildIdentity
    ) -> ApplicationInstanceLaunchDisposition {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检测到另一个屏迹版本正在运行"
        alert.informativeText = """
        已运行：\(runningIdentity.displayVersion) · \(runningIdentity.channel.presentationTitle)
        当前打开：\(currentIdentity.displayVersion) · \(currentIdentity.channel.presentationTitle)

        为避免窗口、权限和录屏项目混用，同一时间只运行一个版本。
        """
        alert.addButton(withTitle: "使用已运行版本")
        alert.addButton(withTitle: "退出旧版并继续")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            application.activate(options: [.activateAllWindows])
            return .terminateCurrent
        case .alertSecondButtonReturn:
            guard application.terminate() else {
                showTerminationFailure(for: application)
                return .terminateCurrent
            }
            return .waitForOtherApplicationToTerminate(application)
        default:
            return .terminateCurrent
        }
    }

    private func activateApplication(
        with processIdentifier: pid_t,
        in applications: [NSRunningApplication]
    ) {
        applications.first { $0.processIdentifier == processIdentifier }?
            .activate(options: [.activateAllWindows])
    }

    private func showTerminationFailure(for application: NSRunningApplication) {
        application.activate(options: [.activateAllWindows])
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "无法安全退出正在运行的屏迹"
        alert.informativeText = "请先在已运行版本中停止录屏并退出，然后重新打开当前版本。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

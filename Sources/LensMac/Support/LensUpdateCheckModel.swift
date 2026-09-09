import Foundation
import LensCore

/// Work that must finish before a future installer may replace the current
/// application bundle. Downloading a release page is still safe; installation
/// is the operation that this gate protects.
struct LensUpdateActivityState: Equatable, Sendable {
    var isRecording = false
    var isRendering = false
    var hasUnsavedEdits = false

    var blocksInstallation: Bool {
        isRecording || isRendering || hasUnsavedEdits
    }

    var blockingMessage: String? {
        if isRecording {
            return "录制进行中，完成录制后才能替换当前安装。"
        }
        if isRendering {
            return "正在生成成片，完成处理后才能替换当前安装。"
        }
        if hasUnsavedEdits {
            return "存在未保存编辑，保存后才能替换当前安装。"
        }
        return nil
    }
}

enum LensUpdateCheckStatus: Equatable, Sendable {
    case idle
    case checking
    case available(version: String, build: String, downloadURL: String)
    case upToDate
    case failed(message: String)
}

/// Main-actor presentation state for the user-initiated update check.
///
/// The release host is injected so the settings panel can be tested without
/// network access. Automatic checks are deliberately not started here: the
/// preference is explicit and opt-in, while scheduling and trusted hosting
/// remain separate release work.
@MainActor
final class LensUpdateCheckModel: ObservableObject {
    typealias CheckOperation = @MainActor @Sendable () async -> LensUpdateCheckResult
    typealias ActivityStateProvider = @MainActor () -> LensUpdateActivityState

    @Published private(set) var status: LensUpdateCheckStatus = .idle
    @Published private(set) var activityState = LensUpdateActivityState()

    private let configured: Bool
    private let check: CheckOperation
    private var activityStateProvider: ActivityStateProvider?

    init(
        configured: Bool = false,
        check: @escaping CheckOperation = { .failed(.transport) },
        activityStateProvider: ActivityStateProvider? = nil
    ) {
        self.configured = configured
        self.check = check
        self.activityStateProvider = activityStateProvider
    }

    var isChecking: Bool {
        status == .checking
    }

    var statusMessage: String? {
        switch status {
        case .idle:
            nil
        case .checking:
            "正在检查更新…"
        case let .available(version, build, _):
            "发现新版本 \(version)（\(build)），请打开下载页手动安装。"
        case .upToDate:
            "当前已是最新版本。"
        case let .failed(message):
            message
        }
    }

    var availableDownloadURL: URL? {
        guard case let .available(_, _, rawURL) = status,
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    /// A future installer must consult this value immediately before replacing
    /// the current bundle. The current release deliberately stops at a manual
    /// download page because its installer and rollback path are not configured.
    var canReplaceCurrentInstall: Bool {
        availableDownloadURL != nil && !effectiveActivityState.blocksInstallation
    }

    var installationBlockMessage: String? {
        effectiveActivityState.blockingMessage
    }

    func setActivityState(_ state: LensUpdateActivityState) {
        activityState = state
    }

    func bindActivityStateProvider(_ provider: @escaping ActivityStateProvider) {
        activityStateProvider = provider
        refreshActivityState()
    }

    func refreshActivityState() {
        guard let activityStateProvider else { return }
        activityState = activityStateProvider()
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        status = .checking
        guard configured else {
            status = .failed(message: "当前构建尚未配置更新源，未发起联网请求。")
            return
        }

        let result = await check()
        switch result {
        case let .available(manifest):
            status = .available(
                version: manifest.version,
                build: manifest.build,
                downloadURL: manifest.downloadURL
            )
        case .upToDate:
            status = .upToDate
        case let .failed(failure):
            status = .failed(message: Self.message(for: failure))
        }
    }

    private static func message(for failure: LensUpdateCheckFailure) -> String {
        switch failure {
        case .transport:
            "无法连接更新服务，当前版本保持不变。"
        case .malformedPayload:
            "更新服务返回的数据无效，当前版本保持不变。"
        case let .manifest(error):
            "更新清单校验失败：\(error.localizedDescription)"
        case .channelMismatch:
            "更新渠道不匹配，当前版本保持不变。"
        case .notNewer:
            "没有可用的新版本。"
        }
    }

    private var effectiveActivityState: LensUpdateActivityState {
        activityStateProvider?() ?? activityState
    }
}

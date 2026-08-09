import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import Foundation

enum SystemPermissionKind: String, CaseIterable, Identifiable {
    case screenCapture
    case microphone
    case camera
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenCapture: "屏幕与系统音频"
        case .microphone: "麦克风"
        case .camera: "摄像头"
        case .accessibility: "辅助功能"
        }
    }

    var detail: String {
        switch self {
        case .screenCapture: "截图、录屏和窗口识别"
        case .microphone: "录制讲解声音，可随时关闭"
        case .camera: "可选的人像摄像头轨道"
        case .accessibility: "全局快捷键与后续键盘事件轨"
        }
    }

    var symbol: String {
        switch self {
        case .screenCapture: "rectangle.inset.filled.and.person.filled"
        case .microphone: "mic.fill"
        case .camera: "video.fill"
        case .accessibility: "accessibility"
        }
    }
}

enum PermissionAccessState: String, Equatable {
    case notDetermined
    case granted
    case denied
    case restricted

    init(authorizationStatus: AVAuthorizationStatus) {
        switch authorizationStatus {
        case .notDetermined:
            self = .notDetermined
        case .authorized:
            self = .granted
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            self = .restricted
        }
    }

    var title: String {
        switch self {
        case .notDetermined: "尚未请求"
        case .granted: "已允许"
        case .denied: "未允许"
        case .restricted: "受系统限制"
        }
    }

    var primaryActionTitle: String? {
        switch self {
        case .notDetermined: "允许"
        case .granted: nil
        case .denied, .restricted: "打开设置"
        }
    }
}

@MainActor
final class PermissionCenterModel: ObservableObject {
    @Published private(set) var states: [SystemPermissionKind: PermissionAccessState] = [:]

    init() {
        refresh()
    }

    func state(for kind: SystemPermissionKind) -> PermissionAccessState {
        states[kind] ?? .notDetermined
    }

    func refresh() {
        states = [
            .screenCapture: ScreenPermission.hasAccess ? .granted : .denied,
            .microphone: PermissionAccessState(
                authorizationStatus: AVCaptureDevice.authorizationStatus(for: .audio)
            ),
            .camera: PermissionAccessState(
                authorizationStatus: AVCaptureDevice.authorizationStatus(for: .video)
            ),
            .accessibility: AXIsProcessTrusted() ? .granted : .denied
        ]
    }

    func performPrimaryAction(for kind: SystemPermissionKind) {
        let state = state(for: kind)
        switch kind {
        case .screenCapture:
            if state == .notDetermined || !ScreenPermission.hasAccess {
                if ScreenPermission.requestAccess() {
                    refresh()
                } else {
                    ScreenPermission.openSystemSettings()
                }
            }
        case .microphone:
            handleMediaPermission(.audio, currentState: state, settingsPane: "Privacy_Microphone")
        case .camera:
            handleMediaPermission(.video, currentState: state, settingsPane: "Privacy_Camera")
        case .accessibility:
            if state == .granted { return }
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            scheduleRefresh()
        }
    }

    private func handleMediaPermission(
        _ mediaType: AVMediaType,
        currentState: PermissionAccessState,
        settingsPane: String
    ) {
        if currentState == .notDetermined {
            Task { @MainActor [weak self] in
                _ = await AVCaptureDevice.requestAccess(for: mediaType)
                self?.refresh()
            }
        } else if currentState != .granted {
            openPrivacyPane(settingsPane)
        }
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func scheduleRefresh() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.refresh()
        }
    }
}

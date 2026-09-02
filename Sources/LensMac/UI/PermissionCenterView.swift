import AppKit
import LensCore
import SwiftUI

struct PermissionCenterView: View {
    @ObservedObject var model: PermissionCenterModel
    @ObservedObject var appModel: AppModel
    let onShortcutsChanged: () -> Void
    var onShortcutCaptureActiveChange: (Bool) -> Void = { _ in }
    let onClose: () -> Void
    private let buildIdentity = BuildIdentity.current

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    shortcutsSection
                    recordingPreferencesSection
                    conversationInboxSection
                    permissionsSection
                    buildIdentitySection
                    diagnosticsSection
                    privacyNote
                }
                .padding(.vertical, LensSpacing.section)
            }
        }
        .padding(LensSpacing.panel)
        .frame(width: 610, height: 640)
        .lensGlassSurface(role: .window, cornerRadius: LensGlassMetrics.windowCornerRadius)
        .padding(34)
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(LensGlassPalette.accent.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: LensIcon.large, weight: .semibold))
                    .foregroundStyle(LensGlassPalette.accent)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("设置与权限")
                    .font(.system(size: LensType.title, weight: .semibold))
                Text("权限只在对应功能被使用时生效")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("重新检查权限")
            .accessibilityLabel("重新检查权限")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: LensIcon.small, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel("关闭设置与权限")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.bottom, 15)
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                sectionTitle("快捷启动", symbol: "keyboard")
                Spacer()
                Button("恢复默认") {
                    appModel.restoreDefaultShortcuts()
                    onShortcutsChanged()
                }
                .buttonStyle(.plain)
                .font(.system(size: LensType.caption, weight: .semibold))
                .foregroundStyle(LensGlassPalette.accent)
            }
            VStack(spacing: 8) {
                shortcutRow(
                    title: "快速区域截图",
                    detail: "不经过模式选择",
                    shortcut: $appModel.quickScreenshotShortcut,
                    forbidden: [
                        appModel.actionCenterShortcut,
                        appModel.conversationInboxShortcut,
                        appModel.stopRecordingShortcut,
                        .fallbackActionCenter,
                        .fallbackConversationInbox,
                        .fallbackStopRecording
                    ]
                )
                Divider().padding(.leading, 122).opacity(0.4)
                shortcutRow(
                    title: "Lens 操作中心",
                    detail: "截图、录屏与最近项目",
                    shortcut: $appModel.actionCenterShortcut,
                    forbidden: [
                        appModel.quickScreenshotShortcut,
                        appModel.conversationInboxShortcut,
                        appModel.stopRecordingShortcut,
                        .fallbackQuickScreenshot,
                        .fallbackConversationInbox,
                        .fallbackStopRecording
                    ]
                )
                Divider().padding(.leading, 122).opacity(0.4)
                shortcutRow(
                    title: "终端截屏",
                    detail: "保存 PNG 并复制路径",
                    shortcut: $appModel.conversationInboxShortcut,
                    forbidden: [
                        appModel.quickScreenshotShortcut,
                        appModel.actionCenterShortcut,
                        appModel.stopRecordingShortcut,
                        .fallbackQuickScreenshot,
                        .fallbackActionCenter,
                        .fallbackStopRecording
                    ]
                )
                Divider().padding(.leading, 122).opacity(0.4)
                shortcutRow(
                    title: "停止录制",
                    detail: "录制中随时结束并保存",
                    shortcut: $appModel.stopRecordingShortcut,
                    forbidden: [
                        appModel.quickScreenshotShortcut,
                        appModel.actionCenterShortcut,
                        appModel.conversationInboxShortcut,
                        .fallbackQuickScreenshot,
                        .fallbackActionCenter,
                        .fallbackConversationInbox
                    ]
                )
            }
            .padding(11)
            .lensGlassSurface(role: .card, cornerRadius: LensGlassMetrics.cardCornerRadius)
            Text("无 Fn 备用：Control + Option + 1 快速截图，2 打开操作中心，3 终端截屏，4 停止录制。录入快捷键时会暂停全局热键，避免误触发截屏。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var recordingPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("录屏偏好", symbol: "record.circle")
            VStack(alignment: .leading, spacing: 10) {
                Toggle("系统声音", isOn: $appModel.capturesSystemAudio)
                Toggle("麦克风", isOn: $appModel.capturesMicrophone)
                Toggle("开始前倒计时", isOn: $appModel.showsRecordingCountdown)
                Toggle("结束后自动转写", isOn: $appModel.automaticallyTranscribesRecordings)
                Picker("帧率", selection: $appModel.recordingFrameRate) {
                    Text("30 FPS").tag(RecordingFrameRate.fps30)
                    Text("60 FPS").tag(RecordingFrameRate.fps60)
                }
                .pickerStyle(.segmented)
            }
            .padding(LensSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lensGlassSurface(role: .card, cornerRadius: LensGlassMetrics.cardCornerRadius)
            Text("摄像头仍只在每次开始录制时显式选择，不会从这里记住。")
                .font(.system(size: LensType.micro, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var conversationInboxSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("终端截屏", symbol: "terminal")
            VStack(alignment: .leading, spacing: 8) {
                Text("框选后覆盖保存为 latest.png，并把这条文件路径复制到剪贴板，方便在终端里粘贴给 AI。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(appModel.conversationInboxDirectory.path)
                    .font(.system(size: LensType.micro, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                Text(ConversationInboxStore(directory: appModel.conversationInboxDirectory).latestURL.path)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("粘贴路径")
                HStack(spacing: 8) {
                    Button("选择文件夹…") {
                        chooseConversationInboxDirectory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("恢复默认") {
                        appModel.restoreDefaultConversationInboxDirectory()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: LensType.caption, weight: .semibold))
                    .foregroundStyle(LensGlassPalette.accent)
                    Button("在 Finder 中打开") {
                        revealConversationInboxDirectory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(LensSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lensGlassSurface(role: .card, cornerRadius: LensGlassMetrics.cardCornerRadius)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("终端截屏文件夹，截图会覆盖保存为 latest.png 并复制路径")
    }

    private func chooseConversationInboxDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = appModel.conversationInboxDirectory
        panel.prompt = "选择"
        panel.message = "终端截屏会覆盖保存到这个文件夹里的 latest.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appModel.conversationInboxDirectory = url.standardizedFileURL
    }

    private func revealConversationInboxDirectory() {
        let directory = appModel.conversationInboxDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("系统权限", symbol: "checkmark.shield")
            VStack(spacing: 0) {
                ForEach(Array(SystemPermissionKind.allCases.enumerated()), id: \.element.id) { index, kind in
                    permissionRow(kind)
                    if index < SystemPermissionKind.allCases.count - 1 {
                        Divider().padding(.leading, 47).opacity(0.4)
                    }
                }
            }
            .lensGlassSurface(role: .card, cornerRadius: LensGlassMetrics.cardCornerRadius)
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(LensGlassPalette.success)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("本地优先")
                    .font(.system(size: LensType.caption, weight: .semibold))
                Text("Lens 默认不上传截图、录屏、声音或事件轨。即使自动处理失败，原始素材也会先保存。")
                    .font(.system(size: LensType.micro, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(13)
        .background(LensGlassPalette.success.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var diagnosticsSection: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: LensIcon.medium, weight: .semibold))
                .foregroundStyle(LensGlassPalette.accent)
                .frame(width: 30, height: 30)
                .background(LensGlassPalette.accent.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("诊断与支持")
                    .font(.system(size: LensType.caption, weight: .semibold))
                Text("仅包含版本、权限状态和错误代码；不包含媒体、正文、标题或路径。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = model.diagnosticStatusMessage {
                    Label(message, systemImage: message.contains("已复制") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: LensType.micro, weight: .semibold))
                        .foregroundStyle(message.contains("已复制") ? LensGlassPalette.success : LensGlassPalette.recording)
                }
            }
            Spacer(minLength: 10)
            Button(model.isPreparingDiagnosticSummary ? "正在准备…" : "复制诊断摘要") {
                model.copyDiagnosticSummary()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isPreparingDiagnosticSummary)
        }
        .padding(LensSpacing.m)
        .background(
            .primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: LensGlassMetrics.cardCornerRadius, style: .continuous)
        )
    }

    private var buildIdentitySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("当前版本", symbol: "shippingbox.fill")
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "app.badge.checkmark.fill")
                    .font(.system(size: LensIcon.medium, weight: .semibold))
                    .foregroundStyle(LensGlassPalette.accent)
                    .frame(width: 30, height: 30)
                    .background(LensGlassPalette.accent.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(buildIdentity.displayVersion)
                        .font(.system(size: LensType.caption, weight: .semibold, design: .monospaced))
                    Text(buildIdentity.displayDetail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let executableURL = buildIdentity.executableURL {
                        Text(executableURL.path)
                            .font(.system(size: LensType.micro, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(LensSpacing.m)
            .lensGlassSurface(role: .card, cornerRadius: LensGlassMetrics.cardCornerRadius)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "当前版本 \(buildIdentity.displayVersion)，\(buildIdentity.displayDetail)"
        )
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func shortcutRow(
        title: String,
        detail: String,
        shortcut: Binding<HotKeyShortcut>,
        forbidden: Set<HotKeyShortcut>
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: LensType.caption, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .leading)
            ShortcutRecorderButton(
                shortcut: shortcut,
                forbidden: forbidden,
                onChanged: onShortcutsChanged,
                onCaptureActiveChange: onShortcutCaptureActiveChange
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(_ kind: SystemPermissionKind) -> some View {
        let state = model.state(for: kind)
        return HStack(spacing: 11) {
            Image(systemName: kind.symbol)
                .font(.system(size: LensIcon.medium, weight: .semibold))
                .foregroundStyle(LensGlassPalette.accent)
                .frame(width: 26, height: 26)
                .background(LensGlassPalette.accent.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: LensType.caption, weight: .semibold))
                Text(kind.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(state.title, systemImage: stateSymbol(state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(stateColor(state))
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("\(kind.title)权限状态")
                .accessibilityValue(state.title)
            if let actionTitle = state.primaryActionTitle {
                Button(actionTitle) {
                    model.performPrimaryAction(for: kind)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("\(actionTitle)：\(kind.title)")
                .accessibilityHint(
                    state == .notDetermined
                        ? "请求\(kind.title)权限"
                        : "打开系统设置中的\(kind.title)权限"
                )
            }
        }
        .padding(.horizontal, LensSpacing.m)
        .padding(.vertical, LensSpacing.inset)
    }

    private func stateColor(_ state: PermissionAccessState) -> Color {
        switch state {
        case .granted: LensGlassPalette.success
        case .notDetermined: LensGlassPalette.warning
        case .denied, .restricted: LensGlassPalette.recording
        }
    }

    private func stateSymbol(_ state: PermissionAccessState) -> String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .notDetermined: "questionmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .restricted: "exclamationmark.triangle.fill"
        }
    }
}

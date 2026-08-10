import ScreenTraceCore
import SwiftUI

struct PermissionCenterView: View {
    @ObservedObject var model: PermissionCenterModel
    @ObservedObject var appModel: AppModel
    let onShortcutsChanged: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    shortcutsSection
                    permissionsSection
                    diagnosticsSection
                    privacyNote
                }
                .padding(.vertical, 18)
            }
        }
        .padding(20)
        .frame(width: 610, height: 560)
        .traceGlassPanel(cornerRadius: 30)
        .padding(34)
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(.cyan.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("设置与权限")
                    .font(.system(size: 16, weight: .semibold))
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
                    .font(.system(size: 10, weight: .bold))
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
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.cyan)
            }
            VStack(spacing: 8) {
                shortcutRow(
                    title: "快速区域截图",
                    detail: "不经过模式选择",
                    shortcut: $appModel.quickScreenshotShortcut,
                    forbidden: [
                        appModel.actionCenterShortcut,
                        .fallbackActionCenter
                    ]
                )
                Divider().padding(.leading, 122).opacity(0.4)
                shortcutRow(
                    title: "屏迹操作中心",
                    detail: "截图、录屏与最近项目",
                    shortcut: $appModel.actionCenterShortcut,
                    forbidden: [
                        appModel.quickScreenshotShortcut,
                        .fallbackQuickScreenshot
                    ]
                )
            }
            .padding(11)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("无 Fn 备用：Control + Option + 1 快速截图，Control + Option + 2 打开操作中心。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
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
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("本地优先")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("屏迹默认不上传截图、录屏、声音或事件轨。即使自动处理失败，原始素材也会先保存。")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(13)
        .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var diagnosticsSection: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 30, height: 30)
                .background(.cyan.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("诊断与支持")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("仅包含版本、权限状态和错误代码；不包含媒体、正文、标题或路径。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = model.diagnosticStatusMessage {
                    Label(message, systemImage: message.contains("已复制") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(message.contains("已复制") ? .green : .red)
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
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                    .font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .leading)
            ShortcutRecorderButton(
                shortcut: shortcut,
                forbidden: forbidden,
                onChanged: onShortcutsChanged
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(_ kind: SystemPermissionKind) -> some View {
        let state = model.state(for: kind)
        return HStack(spacing: 11) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 26, height: 26)
                .background(.cyan.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(kind.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(state.title, systemImage: stateSymbol(state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(stateColor(state))
                .labelStyle(.titleAndIcon)
            if let actionTitle = state.primaryActionTitle {
                Button(actionTitle) {
                    model.performPrimaryAction(for: kind)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func stateColor(_ state: PermissionAccessState) -> Color {
        switch state {
        case .granted: .green
        case .notDetermined: .orange
        case .denied, .restricted: .red
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

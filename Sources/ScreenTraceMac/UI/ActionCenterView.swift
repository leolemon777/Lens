import SwiftUI

enum ActionCenterAction: String, CaseIterable, Identifiable {
    case screenshot
    case windowScreenshot
    case multiWindowScreenshot
    case displayScreenshot
    case recordingSetup
    case recording
    case regionRecording
    case windowRecording
    case ocr
    case scrollingCapture
    case pin
    case openLibrary
    case openSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot: "截图"
        case .windowScreenshot: "窗口截图"
        case .multiWindowScreenshot: "多窗口截图"
        case .displayScreenshot: "屏幕截图"
        case .recordingSetup: "录屏"
        case .recording: "当前屏幕"
        case .regionRecording: "区域录制"
        case .windowRecording: "窗口录制"
        case .ocr: "OCR"
        case .scrollingCapture: "长截图"
        case .pin: "贴图"
        case .openLibrary: "屏迹库"
        case .openSettings: "设置"
        }
    }

    var subtitle: String {
        switch self {
        case .screenshot: "区域 · 窗口 · 屏幕"
        case .windowScreenshot: "选择一个窗口"
        case .multiWindowScreenshot: "组合多个窗口"
        case .displayScreenshot: "当前显示器"
        case .recordingSetup: "智能成片工作台"
        case .recording: "录制当前显示器"
        case .regionRecording: "选择一个区域"
        case .windowRecording: "选择一个窗口"
        case .ocr: "识别文字"
        case .scrollingCapture: "滚动捕获"
        case .pin: "浮在桌面"
        case .openLibrary: "所有记录"
        case .openSettings: "偏好与权限"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: "viewfinder"
        case .windowScreenshot: "macwindow"
        case .multiWindowScreenshot: "rectangle.3.group"
        case .displayScreenshot: "display"
        case .recordingSetup, .recording: "record.circle"
        case .regionRecording: "viewfinder.circle"
        case .windowRecording: "macwindow.badge.plus"
        case .ocr: "text.viewfinder"
        case .scrollingCapture: "rectangle.and.arrow.up.right.and.arrow.down.left"
        case .pin: "pin"
        case .openLibrary: "square.grid.2x2"
        case .openSettings: "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .recordingSetup, .recording, .regionRecording, .windowRecording: .red
        case .screenshot, .windowScreenshot, .multiWindowScreenshot, .displayScreenshot: .cyan
        case .ocr: .indigo
        case .scrollingCapture: .orange
        case .pin: .yellow
        case .openLibrary, .openSettings: .secondary
        }
    }
}

struct ActionCenterView: View {
    @ObservedObject var model: AppModel
    let onAction: (ActionCenterAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            primaryActions
            Divider().opacity(0.45)
            recentSection
            footer
        }
        .frame(width: 620)
        .padding(16)
        .traceGlassSurface(role: .window, cornerRadius: TraceGlassMetrics.windowCornerRadius)
        .padding(34)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(TraceGlassPalette.brandGradient)
            Text("屏迹")
                .font(.system(size: 15, weight: .semibold))
            Text("ScreenTrace")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text("内测版 A")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(TraceGlassPalette.ice.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 13)
    }

    private var primaryActions: some View {
        HStack(spacing: 10) {
            screenshotMenu
            actionTile(.recordingSetup, shortcut: "2")
            actionTile(.ocr, shortcut: "3")
            actionTile(.scrollingCapture, shortcut: "4")
            actionTile(.pin, shortcut: "5")
        }
        .padding(.vertical, 14)
    }

    private var screenshotMenu: some View {
        Menu {
            Button {
                onAction(.screenshot)
            } label: {
                Label("区域截图", systemImage: "viewfinder")
            }
            Button {
                onAction(.windowScreenshot)
            } label: {
                Label("窗口截图", systemImage: "macwindow")
            }
            Button {
                onAction(.multiWindowScreenshot)
            } label: {
                Label("多窗口截图", systemImage: "rectangle.3.group")
            }
            Button {
                onAction(.displayScreenshot)
            } label: {
                Label("当前屏幕", systemImage: "display")
            }
        } label: {
            actionTileLabel(.screenshot)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(TraceGlassButtonStyle(tint: .cyan, cornerRadius: 18))
        .keyboardShortcut("1", modifiers: [])
        .help("选择截图模式")
        .accessibilityLabel("选择截图模式")
        .accessibilityHint("区域截图、窗口截图、多窗口截图或当前屏幕")
    }

    private func actionTile(_ action: ActionCenterAction, shortcut: KeyEquivalent) -> some View {
        Button {
            onAction(action)
        } label: {
            actionTileLabel(action)
        }
        .buttonStyle(TraceGlassButtonStyle(tint: action.tint, cornerRadius: 18))
        .keyboardShortcut(shortcut, modifiers: [])
        .help(action.title)
    }

    private func actionTileLabel(_ action: ActionCenterAction) -> some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(action.tint.opacity(0.13))
                    .frame(width: 38, height: 38)
                Image(systemName: action.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(action.tint)
            }
            Text(action.title)
                .font(.system(size: 13, weight: .semibold))
            Text(action.subtitle)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近屏迹")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("查看全部") { onAction(.openLibrary) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let recent = model.recentTrace {
                HStack(spacing: 12) {
                    Image(nsImage: recent.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 92, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white.opacity(0.16), lineWidth: 1)
                        )
                        .accessibilityLabel("最近屏迹预览")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recent.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("\(recent.dimensions.width) × \(recent.dimensions.height) · 已保存到本地")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .padding(10)
                .traceGlassSurface(role: .card, cornerRadius: TraceGlassMetrics.cardCornerRadius)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                    Text("完成第一次截图后，它会在这里立即出现。")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .traceGlassSurface(role: .card, cornerRadius: TraceGlassMetrics.cardCornerRadius)
            }
        }
        .padding(.vertical, 13)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("\(model.quickScreenshotShortcut.displayName)  快速截图", systemImage: "command")
            Spacer()
            Button {
                onAction(.openSettings)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("设置")
            .accessibilityLabel("打开设置与权限")
            Text("Esc 关闭")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
        .padding(.top, 1)
    }
}

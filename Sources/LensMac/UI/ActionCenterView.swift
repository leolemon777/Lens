import AppKit
import SwiftUI

enum ActionCenterAction: String, CaseIterable, Identifiable {
    case screenshot
    case windowScreenshot
    case multiWindowScreenshot
    case displayScreenshot
    case conversationInbox
    case recordingSetup
    case recording
    case regionRecording
    case windowRecording
    case ocr
    case scrollingCapture
    case pin
    case openLibrary
    case openSettings
    case enableHotKeys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot: "截图"
        case .windowScreenshot: "窗口截图"
        case .multiWindowScreenshot: "多窗口截图"
        case .displayScreenshot: "屏幕截图"
        case .conversationInbox: "截到对话"
        case .recordingSetup: "录屏"
        case .recording: "当前屏幕"
        case .regionRecording: "区域录制"
        case .windowRecording: "窗口录制"
        case .ocr: "OCR"
        case .scrollingCapture: "长截图"
        case .pin: "贴图"
        case .openLibrary: "Lens 库"
        case .openSettings: "设置"
        case .enableHotKeys: "开启快捷键"
        }
    }

    var subtitle: String {
        switch self {
        case .screenshot: "松手就已复制"
        case .windowScreenshot: "选择一个窗口"
        case .multiWindowScreenshot: "组合多个窗口"
        case .displayScreenshot: "当前显示器"
        case .conversationInbox: "PNG 路径给终端"
        case .recordingSetup: "停下就能拖走"
        case .recording: "录制当前显示器"
        case .regionRecording: "选择一个区域"
        case .windowRecording: "选择一个窗口"
        case .ocr: "改完再复制"
        case .scrollingCapture: "滚动捕获"
        case .pin: "剪贴板或最近截图"
        case .openLibrary: "所有记录"
        case .openSettings: "偏好与权限"
        case .enableHotKeys: "辅助功能"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .recordingSetup:
            "打开录屏设置，选择来源、音频和摄像头"
        case .recording:
            "开始录制当前屏幕"
        case .regionRecording:
            "选择区域后开始录制"
        case .windowRecording:
            "选择窗口后开始录制"
        case .screenshot, .windowScreenshot, .multiWindowScreenshot, .displayScreenshot:
            "选择截图方式并开始捕获"
        case .ocr:
            "识别选区中的文字并允许修改后复制"
        case .scrollingCapture:
            "捕获可滚动内容"
        case .pin:
            "把截图或剪贴板内容贴在屏幕上"
        case .conversationInbox:
            "将选区保存到对话文件夹并复制路径"
        case .openLibrary:
            "打开 Lens 库"
        case .openSettings:
            "打开设置与权限"
        case .enableHotKeys:
            "打开系统设置并开启辅助功能"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: "viewfinder"
        case .windowScreenshot: "macwindow"
        case .multiWindowScreenshot: "rectangle.3.group"
        case .displayScreenshot: "display"
        case .conversationInbox: "terminal"
        case .recordingSetup, .recording: "record.circle"
        case .regionRecording: "viewfinder.circle"
        case .windowRecording: "macwindow.badge.plus"
        case .ocr: "text.viewfinder"
        case .scrollingCapture: "rectangle.and.arrow.up.right.and.arrow.down.left"
        case .pin: "pin"
        case .openLibrary: "square.grid.2x2"
        case .openSettings, .enableHotKeys: "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .recordingSetup, .recording, .regionRecording, .windowRecording:
            LensGlassPalette.recording
        case .screenshot, .windowScreenshot, .multiWindowScreenshot, .displayScreenshot,
             .conversationInbox, .ocr, .scrollingCapture, .pin,
             .openLibrary, .openSettings, .enableHotKeys:
            LensGlassPalette.neutral
        }
    }
}

struct ActionCenterView: View {
    @ObservedObject var model: AppModel
    var hotKeysNeedAccessibility = false
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
        .lensGlassSurface(role: .window, cornerRadius: LensGlassMetrics.windowCornerRadius)
        .padding(34)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text("Lens")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 13)
    }

    @ViewBuilder
    private var hotKeyBanner: some View {
        if hotKeysNeedAccessibility {
            Button {
                onAction(.enableHotKeys)
            } label: {
                Label("快捷键还不能用，点这里开启辅助功能", systemImage: "keyboard")
                    .font(.system(size: LensType.caption, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        .orange.opacity(0.12),
                        in: RoundedRectangle(
                            cornerRadius: LensGlassMetrics.controlCornerRadius,
                            style: .continuous
                        )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("开启快捷键")
            .padding(.bottom, 8)
        }
    }

    private var primaryActions: some View {
        VStack(spacing: 10) {
            hotKeyBanner
            HStack(spacing: 10) {
                screenshotMenu
                actionTile(.recordingSetup, shortcut: "2")
                moreMenu
            }
        }
        .padding(.vertical, 14)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                onAction(.ocr)
            } label: {
                Label("OCR 文字", systemImage: "text.viewfinder")
            }
            .keyboardShortcut("3", modifiers: [])
            Button {
                onAction(.scrollingCapture)
            } label: {
                Label("长截图", systemImage: "rectangle.and.arrow.up.right.and.arrow.down.left")
            }
            .keyboardShortcut("4", modifiers: [])
            Button {
                onAction(.pin)
            } label: {
                Label("贴图", systemImage: "pin")
            }
            .keyboardShortcut("5", modifiers: [])
            Divider()
            Button {
                onAction(.openLibrary)
            } label: {
                Label("Lens 库", systemImage: "square.grid.2x2")
            }
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.13))
                        .frame(width: 38, height: 38)
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text("更多")
                    .font(.system(size: 13, weight: .semibold))
                Text("文字 · 长截图 · 贴图")
                    .font(.system(size: LensType.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: LensGlassMetrics.tileCornerRadius, style: .continuous))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(LensGlassButtonStyle(tint: LensGlassPalette.neutral, cornerRadius: LensGlassMetrics.tileCornerRadius))
        .help("更多")
        .accessibilityLabel("更多")
        .accessibilityHint("OCR、长截图、贴图和 Lens 库")
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
            Divider()
            Button {
                onAction(.conversationInbox)
            } label: {
                Label("截到对话文件夹", systemImage: "terminal")
            }
        } label: {
            actionTileLabel(.screenshot)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(LensGlassButtonStyle(tint: LensGlassPalette.neutral, cornerRadius: LensGlassMetrics.tileCornerRadius))
        .keyboardShortcut("1", modifiers: [])
        .help("选择截图模式")
        .accessibilityLabel("选择截图模式")
        .accessibilityHint("区域截图、窗口截图、多窗口截图、当前屏幕，或截到对话文件夹")
    }

    private func actionTile(_ action: ActionCenterAction, shortcut: KeyEquivalent) -> some View {
        Button {
            onAction(action)
        } label: {
            actionTileLabel(action)
        }
        .buttonStyle(LensGlassButtonStyle(tint: action.tint, cornerRadius: LensGlassMetrics.tileCornerRadius))
        .keyboardShortcut(shortcut, modifiers: [])
        .help(action.title)
        .accessibilityLabel(action.title)
        .accessibilityValue(action.subtitle)
        .accessibilityHint(action.accessibilityHint)
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
                .font(.system(size: LensType.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .contentShape(RoundedRectangle(cornerRadius: LensGlassMetrics.tileCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("查看全部") { onAction(.openLibrary) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let recent = model.recentLens {
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
                        .accessibilityLabel("最近 Lens 预览")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recent.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("\(recent.dimensions.width) × \(recent.dimensions.height) · 已保存到本地")
                            .font(.system(size: LensType.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开") {
                        onAction(.openLibrary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("打开最近记录")
                    .accessibilityHint("在 Lens 库中查看这条记录")
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .padding(10)
                .lensGlassSurface(role: .card, cornerRadius: LensGlassMetrics.cardCornerRadius)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                    Text("完成第一次截图后，它会在这里立即出现。")
                        .font(.system(size: LensType.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .lensGlassSurface(role: .card, cornerRadius: LensGlassMetrics.cardCornerRadius)
            }
        }
        .padding(.vertical, 13)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("\(model.quickScreenshotShortcut.displayName)  截图", systemImage: "command")
            Spacer()
            Button {
                onAction(.openSettings)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("设置")
            .accessibilityLabel("打开设置与权限")
            Text("Esc 关闭 · Command-Q 退出")
        }
        .font(.system(size: LensType.caption, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
        .padding(.top, 1)
    }
}

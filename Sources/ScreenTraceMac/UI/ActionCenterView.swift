import SwiftUI

enum ActionCenterAction: String, CaseIterable, Identifiable {
    case screenshot
    case windowScreenshot
    case displayScreenshot
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
        case .displayScreenshot: "屏幕截图"
        case .recording: "录屏"
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
        case .displayScreenshot: "当前显示器"
        case .recording: "区域 · 窗口 · 屏幕"
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
        case .displayScreenshot: "display"
        case .recording: "record.circle"
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
        case .recording, .regionRecording, .windowRecording: .red
        case .screenshot, .windowScreenshot, .displayScreenshot: .cyan
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
        .traceGlassPanel(cornerRadius: 30)
        .padding(34)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            Text("屏迹")
                .font(.system(size: 15, weight: .semibold))
            Text("ScreenTrace")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text("原生原型")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.primary.opacity(0.055), in: Capsule())
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 13)
    }

    private var primaryActions: some View {
        HStack(spacing: 10) {
            screenshotMenu
            recordingMenu
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
                onAction(.displayScreenshot)
            } label: {
                Label("当前屏幕", systemImage: "display")
            }
        } label: {
            actionTileLabel(.screenshot)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(TraceActionButtonStyle(tint: .cyan))
        .keyboardShortcut("1", modifiers: [])
        .help("选择截图模式")
    }

    private var recordingMenu: some View {
        Menu {
            Button {
                onAction(.regionRecording)
            } label: {
                Label("录制区域", systemImage: "viewfinder.circle")
            }
            Button {
                onAction(.windowRecording)
            } label: {
                Label("录制窗口", systemImage: "macwindow.badge.plus")
            }
            Button {
                onAction(.recording)
            } label: {
                Label("录制当前屏幕", systemImage: "display")
            }
            Divider()
            Toggle(isOn: $model.capturesSystemAudio) {
                Label("录制系统声音", systemImage: "speaker.wave.2")
            }
            Toggle(isOn: $model.capturesMicrophone) {
                Label("单独录制麦克风", systemImage: "mic")
            }
            Toggle(isOn: $model.capturesCamera) {
                Label("单独录制摄像头", systemImage: "video")
            }
            Divider()
            Picker("录制帧率", selection: $model.recordingFrameRate) {
                Text("30 FPS · 省空间").tag(RecordingFrameRate.fps30)
                Text("60 FPS · 更流畅").tag(RecordingFrameRate.fps60)
            }
            Divider()
            Toggle(isOn: $model.automaticallyTranscribesRecordings) {
                Label("录完自动转写与整理", systemImage: "sparkles")
            }
            Picker("转写语言", selection: $model.transcriptionLanguage) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
        } label: {
            actionTileLabel(.recording)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(TraceActionButtonStyle(tint: .red))
        .keyboardShortcut("2", modifiers: [])
        .help("选择录屏来源")
    }

    private func actionTile(_ action: ActionCenterAction, shortcut: KeyEquivalent) -> some View {
        Button {
            onAction(action)
        } label: {
            actionTileLabel(action)
        }
        .buttonStyle(TraceActionButtonStyle(tint: action.tint))
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
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(.vertical, 13)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("Fn + Control  快速截图", systemImage: "command")
            Spacer()
            Button {
                onAction(.openSettings)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("设置")
            Text("Esc 关闭")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
        .padding(.top, 1)
    }
}

private struct TraceActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(configuration.isPressed ? tint.opacity(0.16) : .primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(configuration.isPressed ? 0.22 : 0.10), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

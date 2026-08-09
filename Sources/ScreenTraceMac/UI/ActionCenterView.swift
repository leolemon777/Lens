import SwiftUI

enum ActionCenterAction: String, CaseIterable, Identifiable {
    case screenshot
    case recording
    case ocr
    case scrollingCapture
    case pin
    case openLibrary
    case openSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot: "截图"
        case .recording: "录屏"
        case .ocr: "OCR"
        case .scrollingCapture: "长截图"
        case .pin: "贴图"
        case .openLibrary: "屏迹库"
        case .openSettings: "设置"
        }
    }

    var subtitle: String {
        switch self {
        case .screenshot: "区域或窗口"
        case .recording: "自然运镜"
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
        case .recording: "record.circle"
        case .ocr: "text.viewfinder"
        case .scrollingCapture: "rectangle.and.arrow.up.right.and.arrow.down.left"
        case .pin: "pin"
        case .openLibrary: "square.grid.2x2"
        case .openSettings: "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .recording: .red
        case .screenshot: .cyan
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
            actionTile(.screenshot, shortcut: "1")
            actionTile(.recording, shortcut: "2")
            actionTile(.ocr, shortcut: "3")
            actionTile(.scrollingCapture, shortcut: "4")
            actionTile(.pin, shortcut: "5")
        }
        .padding(.vertical, 14)
    }

    private func actionTile(_ action: ActionCenterAction, shortcut: KeyEquivalent) -> some View {
        Button {
            onAction(action)
        } label: {
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
        .buttonStyle(TraceActionButtonStyle(tint: action.tint))
        .keyboardShortcut(shortcut, modifiers: [])
        .help(action.title)
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

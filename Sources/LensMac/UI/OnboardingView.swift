import LensCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var appModel: AppModel
    let onGrant: (SystemPermissionKind) -> Void
    let onQuit: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.step {
                    case .welcome: welcomeStep
                    case .essentials: essentialsStep
                    case .smart: smartStep
                    case .ready: readyStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
            }
            Divider().opacity(0.45)
            footer
        }
        .padding(20)
        .frame(width: 610, height: 440)
        .lensGlassSurface(role: .window, cornerRadius: LensGlassMetrics.windowCornerRadius)
        .padding(34)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(LensGlassPalette.accent.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LensGlassPalette.accent)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(stepTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text(stepCaption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stepIndicator
        }
        .padding(.bottom, 15)
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                Capsule()
                    .fill(step.rawValue <= model.step.rawValue
                          ? AnyShapeStyle(LensGlassPalette.accent)
                          : AnyShapeStyle(.primary.opacity(0.14)))
                    .frame(width: step == model.step ? 18 : 7, height: 7)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.step)
        .accessibilityLabel("第 \(model.step.rawValue + 1) 步，共 \(OnboardingStep.allCases.count) 步")
    }

    private var stepTitle: String {
        switch model.step {
        case .welcome: "欢迎使用 Lens"
        case .essentials: "必需权限"
        case .smart: "让成片像剪过"
        case .ready: "可以开始了"
        }
    }

    private var stepCaption: String {
        switch model.step {
        case .welcome: "一按即捕捉，停下即成品"
        case .essentials: "这两项决定 Lens 能不能工作"
        case .smart: "这一项决定成片像不像剪过"
        case .ready: "随时可以在设置与权限中调整"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if OnboardingModel.step(before: model.step) != nil {
                Button("上一步") { model.retreat() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.step == .ready {
                Button("开始使用", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("以后再说", action: onFinish)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("继续") { model.advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 14)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lens 把截图和录屏放在同一个本地工作台里。所有素材、事件轨和编辑计划都留在你自己的磁盘上。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            sectionTitle("两个常用入口", symbol: "keyboard")
            shortcutRow(
                shortcut: appModel.quickScreenshotShortcut,
                title: "快速区域截图",
                detail: "拖出选区即可，松手就已复制"
            )
            shortcutRow(
                shortcut: appModel.actionCenterShortcut,
                title: "打开操作中心",
                detail: "录屏、长截图、 Lens 库都从这里进入"
            )

            Label(
                "这两个默认组合是纯修饰键，需要辅助功能权限才能被系统送达。下一步就是开启它。",
                systemImage: "info.circle"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var essentialsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("没有这两项，截图和录屏无法开始。 Lens 只在你主动触发捕捉时读取屏幕。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(OnboardingModel.kinds(in: .essential)) { kind in
                permissionRow(kind)
            }

            if model.suggestsRelaunch {
                Label(
                    "屏幕录制权限对已经在运行的应用不会立即生效。如果你刚刚在系统设置里允许了 Lens，需要退出后重新打开一次。",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

                Button("退出 Lens", action: onQuit)
                    .help("退出后从启动台或访达重新打开，屏幕录制权限即可生效")
            }
        }
    }

    private var smartStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lens 的自动运镜、光标重绘和点击波纹都是从真实的指针与点击事件规划出来的。没有这项权限，录屏仍然能录，但成片就是一段普通录屏。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(OnboardingModel.kinds(in: .smart)) { kind in
                permissionRow(kind)
            }

            sectionTitle("按需开启", symbol: "slider.horizontal.3")
            Text("麦克风、摄像头和本地语音识别只在你打开对应轨道时才会被请求，现在可以跳过。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.areEssentialsSatisfied {
                Label("必需权限已就绪", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Label(
                    "还有必需权限没有开启，快捷键可能不会有反应。你可以随时在设置与权限中补上。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            sectionTitle("现在就试一次", symbol: "play.circle")
            shortcutRow(
                shortcut: appModel.quickScreenshotShortcut,
                title: "按一下，拖出一块区域",
                detail: "松手即复制，同时留一份可再编辑的项目"
            )

            Text("菜单栏图标里可以随时打开 Lens 库、设置与权限。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Rows

    private func permissionRow(_ kind: SystemPermissionKind) -> some View {
        let state = model.state(for: kind)
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.primary.opacity(0.06))
                    .frame(width: 34, height: 34)
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(kind.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(state.title, systemImage: permissionStateSymbol(state))
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(permissionStateColor(state))
                .accessibilityLabel("\(kind.title)权限状态")
                .accessibilityValue(state.title)
            if let action = state.primaryActionTitle {
                Button(action) { onGrant(kind) }
                    .accessibilityLabel("\(action)：\(kind.title)")
                    .accessibilityHint(permissionActionHint(for: state, kind: kind))
            }
        }
        .padding(11)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func permissionActionHint(
        for state: PermissionAccessState,
        kind: SystemPermissionKind
    ) -> String {
        state == .notDetermined
            ? "请求\(kind.title)权限"
            : "打开系统设置中的\(kind.title)权限"
    }

    private func permissionStateSymbol(_ state: PermissionAccessState) -> String {
        switch state {
        case .granted:
            "checkmark.circle.fill"
        case .notDetermined:
            "questionmark.circle"
        case .denied, .restricted:
            "exclamationmark.circle.fill"
        }
    }

    private func permissionStateColor(_ state: PermissionAccessState) -> Color {
        switch state {
        case .granted:
            .green
        case .notDetermined:
            .orange
        case .denied, .restricted:
            .red
        }
    }

    private func shortcutRow(
        shortcut: HotKeyShortcut,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(shortcut.displayName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

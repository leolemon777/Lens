import SwiftUI
import ScreenTraceCore

enum RecordingSourceChoice: String, CaseIterable, Identifiable {
    case region
    case window
    case display

    var id: String { rawValue }

    var title: String {
        switch self {
        case .region: "区域"
        case .window: "窗口"
        case .display: "当前屏幕"
        }
    }

    var subtitle: String {
        switch self {
        case .region: "框选重点范围"
        case .window: "跟踪单个 App 窗口"
        case .display: "录制整个显示器"
        }
    }

    var symbol: String {
        switch self {
        case .region: "viewfinder.circle"
        case .window: "macwindow.badge.plus"
        case .display: "display"
        }
    }

    var action: ActionCenterAction {
        switch self {
        case .region: .regionRecording
        case .window: .windowRecording
        case .display: .recording
        }
    }
}

enum RecordingSetupStartRequest {
    case action(ActionCenterAction)
    case source(RecordingCaptureSource)
}

struct RecordingSetupView: View {
    @ObservedObject var model: AppModel
    let onStart: (RecordingSetupStartRequest) -> Void
    let onClose: () -> Void

    @StateObject private var windowPicker: RecordingWindowPickerModel
    @State private var source: RecordingSourceChoice

    init(
        model: AppModel,
        initialSource: RecordingSourceChoice = .region,
        windowPicker: RecordingWindowPickerModel = RecordingWindowPickerModel(),
        onStart: @escaping (RecordingSetupStartRequest) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.onStart = onStart
        self.onClose = onClose
        _windowPicker = StateObject(wrappedValue: windowPicker)
        _source = State(initialValue: initialSource)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceSection
                    presetSection
                    HStack(alignment: .top, spacing: 14) {
                        trackSection
                        qualityAndAutomationSection
                    }
                    capabilitySection
                }
                .padding(20)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 780, height: 660)
        .traceGlassSurface(role: .window, cornerRadius: 22)
        .task(id: source) {
            guard source == .window else { return }
            await windowPicker.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.red.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "record.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("录屏工作台")
                    .font(.system(size: 16, weight: .semibold))
                Text("先选择来源和成片方式，停止后自动生成可编辑预览")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("关闭")
            .accessibilityLabel("关闭录屏工作台")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(
            LinearGradient(
                colors: [TraceGlassPalette.coral.opacity(0.075), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private var sourceSection: some View {
        setupSection("录制来源", symbol: "rectangle.dashed") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(RecordingSourceChoice.allCases) { item in
                        Button {
                            source = item
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(source == item ? .red : .secondary)
                                Text(item.title)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(item.subtitle)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        }
                        .buttonStyle(TraceGlassButtonStyle(
                            tint: .red,
                            isSelected: source == item
                        ))
                        .accessibilityAddTraits(source == item ? .isSelected : [])
                    }
                }
                if source == .window {
                    windowPickerSection
                }
            }
        }
    }

    private var windowPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前桌面可录制窗口")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("可以选择后台被遮挡的浏览器或 App 窗口")
                        .font(.system(size: 9.2, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if windowPicker.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在刷新窗口")
                }
                Button {
                    Task { await windowPicker.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(windowPicker.isRefreshing)
            }

            if windowPicker.options.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: windowPicker.isRefreshing
                          ? "rectangle.on.rectangle.angled"
                          : "macwindow.badge.exclamationmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(windowPicker.isRefreshing ? "正在读取打开的窗口…" : "暂时没有可录制窗口")
                            .font(.system(size: 10.5, weight: .semibold))
                        if let errorMessage = windowPicker.errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .padding(.horizontal, 14)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(windowPicker.options) { option in
                            windowCard(option)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.visible)
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [.red.opacity(0.065), .primary.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.7)
        }
    }

    private func windowCard(_ option: RecordingWindowOption) -> some View {
        let isSelected = windowPicker.selectedWindowID == option.id
        return Button {
            windowPicker.selectWindow(id: option.id)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.black.opacity(0.13))
                    if let thumbnail = option.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if isSelected {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white, .red)
                                    .padding(7)
                            }
                            Spacer()
                        }
                    }
                }
                .frame(width: 198, height: 112)
                HStack(spacing: 6) {
                    if let appIcon = option.appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 17, height: 17)
                    } else {
                        Image(systemName: "app")
                            .frame(width: 17, height: 17)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.applicationName)
                            .font(.system(size: 9.8, weight: .semibold))
                            .lineLimit(1)
                        Text(option.windowTitle)
                            .font(.system(size: 8.7, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(8)
            .frame(width: 214, alignment: .leading)
            .background(.primary.opacity(isSelected ? 0.085 : 0.035))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.red : Color.primary.opacity(0.09),
                        lineWidth: isSelected ? 1.8 : 0.7
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.applicationName)，\(option.windowTitle)")
        .accessibilityHint("选择后只录制这个窗口")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var presetSection: some View {
        setupSection("成片模式", symbol: "sparkles.rectangle.stack") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(RecordingExperiencePreset.allCases) { preset in
                    Button {
                        model.recordingExperiencePreset = preset
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: preset.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(
                                    model.recordingExperiencePreset == preset ? .cyan : .secondary
                                )
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title)
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text(preset.subtitle)
                                    .font(.system(size: 9.2, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if model.recordingExperiencePreset == preset {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.cyan)
                            }
                        }
                        .padding(11)
                    }
                    .buttonStyle(TraceGlassButtonStyle(
                        tint: .cyan,
                        isSelected: model.recordingExperiencePreset == preset
                    ))
                    .accessibilityAddTraits(
                        model.recordingExperiencePreset == preset ? .isSelected : []
                    )
                }
            }
        }
    }

    private var trackSection: some View {
        setupSection("独立轨道", symbol: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 11) {
                Toggle("系统声音", isOn: $model.capturesSystemAudio)
                Toggle("麦克风讲解", isOn: $model.capturesMicrophone)
                Toggle(isOn: $model.capturesCamera) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("前置摄像头")
                        Text("默认关闭 · 本次录制单独开启")
                            .font(.system(size: 8.8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("屏幕、声音、麦克风和摄像头分别保存，原始轨不会被后期覆盖。")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var qualityAndAutomationSection: some View {
        setupSection("质量与自动处理", symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("帧率", selection: $model.recordingFrameRate) {
                    Text("30 FPS · 省空间").tag(RecordingFrameRate.fps30)
                    Text("60 FPS · 更流畅").tag(RecordingFrameRate.fps60)
                }
                .pickerStyle(.segmented)
                Toggle("录完自动转写与整理", isOn: $model.automaticallyTranscribesRecordings)
                    .toggleStyle(.switch)
                Picker("转写语言", selection: $model.transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .disabled(!model.automaticallyTranscribesRecordings)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var capabilitySection: some View {
        setupSection("停止后自动得到", symbol: "wand.and.stars") {
            FlowLayout(spacing: 7) {
                capability("自动运镜", symbol: "camera.metering.center.weighted")
                capability("平滑光标", symbol: "cursorarrow.motionlines")
                capability("点击反馈", symbol: "cursorarrow.click.2")
                capability("背景与圆角", symbol: "rectangle.inset.filled")
                capability("画中画", symbol: "pip")
                capability("旁白降噪混音", symbol: "waveform")
                capability("时间线剪辑", symbol: "timeline.selection")
                capability("字幕校对", symbol: "captions.bubble")
                capability("九类视频标注", symbol: "pencil.and.outline")
                capability("三档 MP4 导出", symbol: "square.and.arrow.up")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(footerTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(trackSummary)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消", action: onClose)
                .buttonStyle(.bordered)
            Button {
                startSelectedSource()
            } label: {
                Label(startButtonTitle, systemImage: "record.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
            .disabled(source == .window && windowPicker.selectedSource == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.primary.opacity(0.025))
    }

    private var footerTitle: String {
        if source == .window {
            if let option = windowPicker.selectedOption {
                return "\(option.applicationName) · \(option.windowTitle)"
            }
            return "窗口录制 · 请先在上方选择一个窗口"
        }
        return "\(source.title) · \(model.recordingExperiencePreset.title) · \(model.recordingFrameRate.rawValue) FPS"
    }

    private var startButtonTitle: String {
        source == .window && windowPicker.selectedSource == nil
            ? "请先选择窗口"
            : "开始录制\(source.title)"
    }

    private func startSelectedSource() {
        if source == .window {
            guard let selectedSource = windowPicker.selectedSource else { return }
            onStart(.source(selectedSource))
        } else {
            onStart(.action(source.action))
        }
    }

    private var trackSummary: String {
        var tracks = ["屏幕"]
        if model.capturesSystemAudio { tracks.append("系统声") }
        if model.capturesMicrophone { tracks.append("麦克风") }
        if model.capturesCamera { tracks.append("摄像头") }
        return tracks.joined(separator: " + ") + " · 独立安全写盘"
    }

    private func capability(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.055), in: Capsule())
    }

    private func setupSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        TraceGlassSection(title, symbol: symbol) {
            content()
        }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? 700
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), points)
    }
}

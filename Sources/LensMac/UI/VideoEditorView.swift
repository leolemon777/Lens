import AVKit
import LensCore
import SwiftUI

enum VideoEditorInspectorSection: Hashable {
    case captions
    case export
}

enum VideoEditorInspectorMode: String, CaseIterable, Identifiable {
    case quick
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: "快速优化"
        case .advanced: "全部设置"
        }
    }
}

struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var playback: VideoEditorPlaybackController
    let title: String
    let initialInspectorSection: VideoEditorInspectorSection?
    let onRegenerateCamera: () -> Void
    let onRefreshPreview: () -> Void
    let onSave: () -> Void
    let onCancelProcessing: () -> Void
    let onExport: () -> Void
    let onExportStepDocument: () -> Void
    let onExportNarrationDraft: () -> Void
    let onClose: () -> Void

    @State private var presenterDragStart: PresenterCameraFrameState?
    @State private var presenterResizeStart: PresenterCameraFrameState?
    @State private var inspectorScrollPosition: VideoEditorInspectorSection?
    @State private var isCaptionCueEditorExpanded: Bool
    @State private var isAdvancedCameraExpanded = false
    @State private var isCursorDetailExpanded = false
    @State private var isClickDetailExpanded = false
    @State private var showsAdvancedEditingTools: Bool
    @State private var inspectorMode: VideoEditorInspectorMode

    init(
        model: VideoEditorModel,
        playback: VideoEditorPlaybackController,
        title: String,
        initialInspectorSection: VideoEditorInspectorSection? = nil,
        onRegenerateCamera: @escaping () -> Void = {},
        onRefreshPreview: @escaping () -> Void = {},
        onSave: @escaping () -> Void,
        onCancelProcessing: @escaping () -> Void = {},
        onExport: @escaping () -> Void,
        onExportStepDocument: @escaping () -> Void = {},
        onExportNarrationDraft: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.playback = playback
        self.title = title
        self.initialInspectorSection = initialInspectorSection
        self.onRegenerateCamera = onRegenerateCamera
        self.onRefreshPreview = onRefreshPreview
        self.onSave = onSave
        self.onCancelProcessing = onCancelProcessing
        self.onExport = onExport
        self.onExportStepDocument = onExportStepDocument
        self.onExportNarrationDraft = onExportNarrationDraft
        self.onClose = onClose
        _inspectorScrollPosition = State(initialValue: initialInspectorSection)
        _isCaptionCueEditorExpanded = State(
            initialValue: initialInspectorSection == .captions
        )
        _showsAdvancedEditingTools = State(initialValue: initialInspectorSection != nil)
        _inspectorMode = State(
            initialValue: initialInspectorSection == nil ? .quick : .advanced
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.32)
            HStack(spacing: 0) {
                workspace
                Divider().opacity(0.32)
                VideoEditorInspectorView(
                    model: model,
                    playback: playback,
                    inspectorScrollPosition: $inspectorScrollPosition,
                    isCaptionCueEditorExpanded: $isCaptionCueEditorExpanded,
                    isAdvancedCameraExpanded: $isAdvancedCameraExpanded,
                    isCursorDetailExpanded: $isCursorDetailExpanded,
                    isClickDetailExpanded: $isClickDetailExpanded,
                    showsAdvancedEditingTools: $showsAdvancedEditingTools,
                    inspectorMode: $inspectorMode,
                    initialInspectorSection: initialInspectorSection,
                    onRegenerateCamera: onRegenerateCamera,
                    onRefreshPreview: onRefreshPreview,
                    onExport: onExport,
                    onExportStepDocument: onExportStepDocument,
                    onExportNarrationDraft: onExportNarrationDraft
                )
            }
        }
        .frame(minWidth: 1_060, minHeight: 680)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.black.opacity(0.075)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .task(id: playback.isPlaying) {
            guard playback.isPlaying else { return }
            while !Task.isCancelled {
                playback.refreshTime()
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
        .onChange(of: model.plan) { previous, updated in
            guard previous != updated else { return }
            guard playback.isShowingRenderedPreview || playback.canShowRenderedPreview else {
                return
            }
            playback.invalidateRenderedPreview()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LensGlassPalette.recording.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "timeline.selection")
                    .font(.system(size: LensIcon.medium, weight: .semibold))
                    .foregroundStyle(LensGlassPalette.recording)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Label("非破坏性编辑 · 原始录屏与独立轨道不会改写", systemImage: "lock.shield")
                    .font(.system(size: LensType.caption, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(previewStatusTitle, systemImage: previewStatusSymbol)
                .font(.system(size: LensType.micro, weight: .bold))
                .foregroundStyle(previewStatusColor)
                .padding(.horizontal, LensSpacing.s)
                .padding(.vertical, 4)
                .background(previewStatusColor.opacity(0.12), in: Capsule())
                .accessibilityValue(previewStatusTitle)
            Button(action: model.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .help("撤销")
            .accessibilityLabel("撤销")
            Button(action: model.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .help("重做")
            .accessibilityLabel("重做")
            Button(action: model.isProcessing ? onCancelProcessing : onSave) {
                HStack(spacing: 6) {
                    if model.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.isProcessing
                        ? "取消生成"
                        : (model.isDirty ? "立即生成" : "重新生成预览"))
                }
            }
                .buttonStyle(.borderedProminent)
                .tint(model.isProcessing ? LensGlassPalette.warning : LensGlassPalette.accent)
            Button(action: onExport) {
                Label("导出 MP4", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(model.isProcessing)
            .help("按当前质量预设生成并导出 MP4")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: LensIcon.small, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel("关闭视频编辑器")
        }
        .padding(.horizontal, LensSpacing.section)
        .padding(.vertical, LensSpacing.m)
        .lensGlassSurface(role: .chrome, cornerRadius: 0)
    }

    private var previewStatusTitle: String {
        if model.isProcessing { return processingStatusTitle }
        if model.isDirty {
            return model.isPlanPersisted ? "预览待更新" : "未保存"
        }
        return "成片已更新"
    }

    private var processingStatusTitle: String {
        guard let progress = model.processingProgress else { return "正在生成成片" }
        return String(format: "正在生成成片 %d%%", Int((progress * 100).rounded()))
    }

    private var previewStatusSymbol: String {
        if model.isProcessing { return "arrow.triangle.2.circlepath" }
        if model.isDirty { return model.isPlanPersisted ? "clock" : "square.and.arrow.down" }
        return "checkmark.circle.fill"
    }

    private var previewStatusColor: Color {
        if model.isProcessing { return LensGlassPalette.accent }
        if model.isDirty { return LensGlassPalette.warning }
        return LensGlassPalette.success
    }

    private var workspace: some View {
        VStack(spacing: 14) {
            preview
            transport
            VideoEditorTimelineView(model: model, playback: playback)
        }
        .padding(LensSpacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LensGlassMetrics.panelCornerRadius, style: .continuous)
                .fill(.black)
            if playback.player.currentItem == nil {
                VStack(spacing: 10) {
                    if playback.isLoading {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在构建非破坏性预览…")
                    } else {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: 34, weight: .light))
                        Text(playback.errorMessage ?? "预览将在素材加载后出现")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
            } else {
                VideoEditorCanvasPreview(
                    player: playback.player,
                    canvas: playback.isShowingRenderedPreview ? nil : model.plan.canvas,
                    camera: playback.isShowingRenderedPreview ? nil : model.plan.camera,
                    cursor: playback.isShowingRenderedPreview ? nil : model.plan.cursor,
                    interaction: playback.isShowingRenderedPreview
                        ? nil
                        : model.plan.interaction,
                    timeline: model.plan.timeline
                )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(LensSpacing.s)
            }
            GeometryReader { proxy in
                if proxy.size.width > 20, proxy.size.height > 20 {
                    let contentRect = CGRect(
                        x: 8,
                        y: 8,
                        width: max(proxy.size.width - 16, 1),
                        height: max(proxy.size.height - 16, 1)
                    )
                    if !model.videoAnnotations.isEmpty || model.isVideoAnnotationEditing {
                        VideoAnnotationOverlayView(
                            model: model,
                            playback: playback,
                            contentRect: contentRect
                        )
                        .allowsHitTesting(!model.isManualCameraFocusEditing)
                    }
                }
                if model.hasCameraTrack,
                   model.presenterEnabled,
                   proxy.size.width > 20,
                   proxy.size.height > 20 {
                    VideoEditorPlaybackClockView(clock: playback.clock) { currentTime in
                        presenterOverlay(
                            in: proxy.size,
                            currentTimeSeconds: currentTime
                        )
                    }
                    .allowsHitTesting(
                        !model.isVideoAnnotationEditing
                            && !model.isManualCameraFocusEditing
                    )
                }
                if model.isManualCameraFocusEditing,
                   proxy.size.width > 20,
                   proxy.size.height > 20 {
                    let contentRect = CGRect(
                        x: 8,
                        y: 8,
                        width: max(proxy.size.width - 16, 1),
                        height: max(proxy.size.height - 16, 1)
                    )
                    manualCameraFocusOverlay(in: contentRect)
                }
            }
            VStack {
                HStack {
                    Label(
                        playback.isShowingRenderedPreview ? "已生成效果" : "实时编辑",
                        systemImage: playback.isShowingRenderedPreview
                            ? "sparkles.tv"
                            : "bolt.fill"
                    )
                    .font(.system(size: LensType.micro, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, LensSpacing.s)
                    .padding(.vertical, 5)
                    .background(LensGlassPalette.ink.opacity(0.68), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.6))
                    Spacer()
                }
                Spacer()
            }
            .padding(LensSpacing.card)
            .allowsHitTesting(false)
            if let aspectRatio = model.plan.export?.aspectRatio,
               !playback.isShowingRenderedPreview {
                VideoEditorSocialSafeAreaOverlay(aspectRatio: aspectRatio)
                    .padding(LensSpacing.s)
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: LensGlassMetrics.panelCornerRadius, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
        .aspectRatio(previewAspectRatio, contentMode: .fit)
        .frame(maxHeight: 460)
    }

    private var previewAspectRatio: Double {
        guard let aspectRatio = model.plan.export?.aspectRatio else {
            return playback.videoAspectRatio
        }
        switch aspectRatio {
        case .vertical9x16:
            return 9.0 / 16.0
        case .square1x1:
            return 1
        }
    }

    private func manualCameraFocusOverlay(in contentRect: CGRect) -> some View {
        ZStack {
            Rectangle()
                .fill(LensGlassPalette.neutral.opacity(0.001)) // invisible hit-test target; color is irrelevant
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            playback.pause()
                            let added = model.addManualCameraFocus(
                                center: LensPoint(
                                    x: min(max(
                                        value.location.x / max(contentRect.width, 1),
                                        0
                                    ), 1),
                                    y: min(max(
                                        value.location.y / max(contentRect.height, 1),
                                        0
                                    ), 1)
                                ),
                                atOutputTime: playback.currentTimeSeconds
                            )
                            if added { onRefreshPreview() }
                        }
                )

            VStack {
                Label("点击画面设置缩放焦点", systemImage: "scope")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, LensSpacing.inset)
                    .padding(.vertical, 6)
                    .background(LensGlassPalette.ink.opacity(0.78), in: Capsule())
                    .overlay(Capsule().stroke(LensGlassPalette.accent.opacity(0.72), lineWidth: 1))
                    .padding(LensSpacing.m)
                Spacer()
            }

            Image(systemName: "scope")
                .font(.system(size: LensIcon.hero, weight: .light))
                .foregroundStyle(LensGlassPalette.accent.opacity(0.72))
                .allowsHitTesting(false)
        }
        .frame(width: contentRect.width, height: contentRect.height)
        .position(x: contentRect.midX, y: contentRect.midY)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("手动缩放焦点画布")
        .accessibilityHint("点击画面位置，在当前播放头添加缩放")
    }

    private func presenterOverlay(
        in canvasSize: CGSize,
        currentTimeSeconds: Double
    ) -> some View {
        let inset: CGFloat = 8
        let contentSize = CGSize(
            width: max(canvasSize.width - inset * 2, 1),
            height: max(canvasSize.height - inset * 2, 1)
        )
        let aspectRatio = Double(contentSize.width / max(contentSize.height, 1))
        let state = model.presenterState(
            atOutputTime: currentTimeSeconds,
            canvasAspectRatio: aspectRatio
        )
        let layout = model.plan.presenterCamera ?? .init()
        let width = contentSize.width * state.size
        let height = layout.shape == .circle ? width : width * 9 / 16
        let clipShape = PresenterCameraClipShape(
            kind: layout.shape,
            cornerRadius: layout.cornerRadius
        )
        let center = CGPoint(
            x: inset + contentSize.width * state.center.x,
            y: inset + contentSize.height * state.center.y
        )

        return ZStack {
            presenterThumbnail(layout: layout)
                .frame(width: width, height: height)
                .clipShape(clipShape)
                .overlay(clipShape.stroke(LensGlassPalette.accent.opacity(0.94), lineWidth: 2))
                .overlay(clipShape.stroke(.white.opacity(0.42), lineWidth: 0.6).padding(3))
                .contentShape(clipShape)
                .shadow(color: .black.opacity(0.34), radius: 14, y: 7)
                .gesture(presenterDragGesture(
                    current: state,
                    contentSize: contentSize
                ))

            Circle()
                .fill(LensGlassPalette.ink.opacity(0.72))
                .frame(width: 23, height: 23)
                .overlay(Circle().stroke(.white.opacity(0.62), lineWidth: 1))
                .overlay(
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: LensIcon.small, weight: .bold))
                        .foregroundStyle(.white)
                )
                .shadow(color: .black.opacity(0.32), radius: 5, y: 2)
                .offset(x: width / 2 - 3, y: height / 2 - 3)
                .highPriorityGesture(presenterResizeGesture(
                    current: state,
                    layout: layout,
                    contentSize: contentSize
                ))

            HStack(spacing: 4) {
                Image(systemName: model.hasPresenterKeyframe(
                    nearOutputTime: currentTimeSeconds
                ) ? "diamond.fill" : "hand.draw")
                Text(model.hasPresenterKeyframe(nearOutputTime: currentTimeSeconds)
                    ? "关键帧"
                    : "拖动定位")
            }
            .font(.system(size: LensType.micro, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(LensGlassPalette.ink.opacity(0.72), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
            .offset(y: -height / 2 - 15)
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .position(center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("讲解人像，可拖动并缩放")
    }

    @ViewBuilder
    private func presenterThumbnail(
        layout: AutoEditPlan.PresenterCamera
    ) -> some View {
        if let thumbnail = model.presenterThumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .scaleEffect(x: layout.isMirrored ? -1 : 1, y: 1)
        } else {
            ZStack {
                Rectangle().fill(LensGlassPalette.ink.opacity(0.78))
                LinearGradient(
                    colors: [LensGlassPalette.accent.opacity(0.28), LensGlassPalette.accentDeep.opacity(0.24)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.white.opacity(0.86))
            }
        }
    }

    private func presenterDragGesture(
        current: PresenterCameraFrameState,
        contentSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if presenterDragStart == nil {
                    playback.pause()
                    presenterDragStart = current
                    model.beginPresenterInteraction()
                }
                guard let start = presenterDragStart else { return }
                model.updatePresenterInteraction(
                    center: LensPoint(
                        x: start.center.x + value.translation.width / contentSize.width,
                        y: start.center.y + value.translation.height / contentSize.height
                    ),
                    size: start.size,
                    atOutputTime: playback.currentTimeSeconds
                )
            }
            .onEnded { _ in
                model.endPresenterInteraction()
                presenterDragStart = nil
            }
    }

    private func presenterResizeGesture(
        current: PresenterCameraFrameState,
        layout: AutoEditPlan.PresenterCamera,
        contentSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if presenterResizeStart == nil {
                    playback.pause()
                    presenterResizeStart = current
                    model.beginPresenterInteraction()
                }
                guard let start = presenterResizeStart else { return }
                let heightRatio = layout.shape == .circle ? 1.0 : 9.0 / 16.0
                let horizontalDelta = value.translation.width / contentSize.width
                let verticalDelta = value.translation.height
                    / max(contentSize.width * heightRatio, 1)
                model.updatePresenterInteraction(
                    center: start.center,
                    size: start.size + (horizontalDelta + verticalDelta) / 2,
                    atOutputTime: playback.currentTimeSeconds
                )
            }
            .onEnded { _ in
                model.endPresenterInteraction()
                presenterResizeStart = nil
            }
    }

    private var transport: some View {
        HStack(spacing: 11) {
            Button(action: playback.togglePlayback) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(playback.isLoading || playback.durationSeconds <= 0)
            .accessibilityLabel(playback.isPlaying ? "暂停预览" : "播放预览")
            VideoEditorTransportClockControls(playback: playback)
            Text(VideoEditorFormatting.timeText(playback.durationSeconds))
                .font(.system(size: LensType.numeric, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text("成片 \(VideoEditorFormatting.timeText(model.outputDurationSeconds))")
                .font(.system(size: LensType.micro, weight: .bold))
                .foregroundStyle(LensGlassPalette.accent)
                .padding(.horizontal, LensSpacing.s)
                .padding(.vertical, 4)
                .background(LensGlassPalette.accent.opacity(0.11), in: Capsule())
            Button(action: playback.togglePreviewMode) {
                Label(
                    playback.isShowingRenderedPreview ? "已生成效果" : "实时编辑",
                    systemImage: playback.isShowingRenderedPreview ? "sparkles.tv" : "film"
                )
                .font(.system(size: LensType.micro, weight: .bold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(playback.isShowingRenderedPreview ? LensGlassPalette.warning : .secondary)
            .disabled(
                !playback.canShowRenderedPreview
                    || playback.isLoading
                    || model.isManualCameraFocusEditing
            )
            .help(playback.isShowingRenderedPreview
                ? "当前播放上次保存后生成的完整成片；修改参数后会自动切换实时编辑"
                : "当前使用原始素材实时显示运镜、光标和点击；后台成片完成后不会在播放途中强制换源")
        }
        .padding(.horizontal, LensSpacing.m)
        .padding(.vertical, 9)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: LensGlassMetrics.controlCornerRadius))
    }
}

struct VideoEditorPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.setAccessibilityElement(false)
        view.setAccessibilityHidden(true)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player = nil
    }
}

enum VideoEditorCanvasPreviewLayout {
    struct CameraTransform: Equatable {
        let scale: CGFloat
        let offset: CGSize
    }

    static func contentRect(in size: CGSize, margin: Double) -> CGRect {
        let clampedMargin = min(max(margin.isFinite ? margin : 0, 0), 0.25)
        let insetX = size.width * clampedMargin
        let insetY = size.height * clampedMargin
        return CGRect(origin: .zero, size: size).insetBy(dx: insetX, dy: insetY)
    }

    static func cornerRadius(in size: CGSize, amount: Double) -> CGFloat {
        min(size.width, size.height) * min(max(amount.isFinite ? amount : 0, 0), 0.2)
    }

    static func cameraTransform(
        in size: CGSize,
        camera: AutoEditPlan.Camera?,
        sourceTimeSeconds: Double
    ) -> CameraTransform {
        guard let camera, camera.mode != "off" else {
            return CameraTransform(scale: 1, offset: .zero)
        }
        let state = EffectTimeline.effectiveCameraState(
            at: max(sourceTimeSeconds.isFinite ? sourceTimeSeconds : 0, 0),
            camera: camera
        )
        let scale = CGFloat(max(state.scale.isFinite ? state.scale : 1, 1))
        let halfViewport = 0.5 / Double(scale)
        let centerX = min(max(state.center.x, halfViewport), 1 - halfViewport)
        let centerY = min(max(state.center.y, halfViewport), 1 - halfViewport)
        return CameraTransform(
            scale: scale,
            offset: CGSize(
                width: (0.5 - centerX) * size.width * scale,
                height: (0.5 - centerY) * size.height * scale
            )
        )
    }

    static func playerFrame(
        in size: CGSize,
        transform: CameraTransform
    ) -> CGRect {
        CGRect(
            x: (size.width - size.width * transform.scale) / 2
                + transform.offset.width,
            y: (size.height - size.height * transform.scale) / 2
                - transform.offset.height,
            width: size.width * transform.scale,
            height: size.height * transform.scale
        )
    }
}

struct VideoEditorCanvasBackgroundPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let topHex: String
    let bottomHex: String

    static let all: [VideoEditorCanvasBackgroundPreset] = [
        .init(id: "mist", title: "雾灰", topHex: "#D9D6CF", bottomHex: "#9EA9A7"),
        .init(id: "glacier", title: "冰川", topHex: "#F8FBFF", bottomHex: "#CAD8E8"),
        .init(id: "indigo", title: "蓝紫", topHex: "#667EEA", bottomHex: "#764BA2"),
        .init(id: "sunset", title: "日落", topHex: "#F6D365", bottomHex: "#FDA085"),
        .init(id: "graphite", title: "石墨", topHex: "#232526", bottomHex: "#414345"),
        .init(id: "ocean", title: "海洋", topHex: "#00C6FF", bottomHex: "#0072FF"),
        .init(id: "mint", title: "薄荷", topHex: "#11998E", bottomHex: "#38EF7D"),
        .init(id: "aurora", title: "极光", topHex: "#7F00FF", bottomHex: "#00D4FF"),
        .init(id: "cherry", title: "樱粉", topHex: "#F953C6", bottomHex: "#B91D73"),
        .init(id: "peach", title: "蜜桃", topHex: "#FF9966", bottomHex: "#FF5E62"),
        .init(id: "forest", title: "森林", topHex: "#134E5E", bottomHex: "#71B280"),
        .init(id: "midnight", title: "午夜", topHex: "#0F2027", bottomHex: "#2C5364")
    ]

    func matches(_ canvas: AutoEditPlan.Canvas?) -> Bool {
        guard let canvas else { return false }
        return canvas.backgroundTopHex.caseInsensitiveCompare(topHex) == .orderedSame
            && canvas.backgroundBottomHex.caseInsensitiveCompare(bottomHex) == .orderedSame
    }
}

enum VideoEditorCanvasColor {
    static func color(hex: String, fallback: Color) -> Color {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6,
              let integer = UInt32(value, radix: 16) else { return fallback }
        return Color(
            red: Double((integer >> 16) & 0xFF) / 255,
            green: Double((integer >> 8) & 0xFF) / 255,
            blue: Double(integer & 0xFF) / 255
        )
    }
}

private struct VideoEditorPlaybackClockView<Content: View>: View {
    @ObservedObject var clock: VideoEditorPlaybackClock
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        content(clock.currentTimeSeconds)
    }
}

private struct VideoEditorTransportClockControls: View {
    @ObservedObject var playback: VideoEditorPlaybackController
    @ObservedObject private var clock: VideoEditorPlaybackClock

    init(playback: VideoEditorPlaybackController) {
        self.playback = playback
        _clock = ObservedObject(wrappedValue: playback.clock)
    }

    var body: some View {
        Text(VideoEditorFormatting.timeText(clock.currentTimeSeconds))
            .font(.system(size: LensType.numeric, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .trailing)
        Slider(
            value: Binding(
                get: { clock.currentTimeSeconds },
                set: { playback.seek(to: $0) }
            ),
            in: 0...max(playback.durationSeconds, 0.01),
            onEditingChanged: { editing in
                if !editing { playback.settlePlayhead() }
            }
        )
        .accessibilityLabel("预览播放位置")
        .accessibilityValue(
            "\(VideoEditorFormatting.timeText(clock.currentTimeSeconds)) / \(VideoEditorFormatting.timeText(playback.durationSeconds))"
        )
    }
}

struct VideoEditorTimelinePlayhead: NSViewRepresentable {
    let player: AVPlayer
    let durationSeconds: Double

    func makeNSView(context: Context) -> VideoEditorTimelinePlayheadNSView {
        VideoEditorTimelinePlayheadNSView(
            player: player,
            durationSeconds: durationSeconds
        )
    }

    func updateNSView(
        _ view: VideoEditorTimelinePlayheadNSView,
        context: Context
    ) {
        view.configure(player: player, durationSeconds: durationSeconds)
    }

    static func dismantleNSView(
        _ view: VideoEditorTimelinePlayheadNSView,
        coordinator: Void
    ) {
        view.stop()
    }
}

final class VideoEditorTimelinePlayheadNSView: NSView {
    private weak var player: AVPlayer?
    private var durationSeconds: Double
    private var displayTimer: Timer?
    private let playheadLayer = CALayer()
    private var lastX = CGFloat.nan

    init(player: AVPlayer, durationSeconds: Double) {
        self.player = player
        self.durationSeconds = durationSeconds
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        playheadLayer.backgroundColor = NSColor.white.cgColor
        playheadLayer.shadowColor = NSColor.black.cgColor
        playheadLayer.shadowOpacity = 0.45
        playheadLayer.shadowRadius = 2
        layer?.addSublayer(playheadLayer)
        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(displayTick(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        lastX = .nan
        updatePlayhead()
    }

    func configure(player: AVPlayer, durationSeconds: Double) {
        self.player = player
        self.durationSeconds = durationSeconds
        updatePlayhead()
    }

    func stop() {
        displayTimer?.invalidate()
        displayTimer = nil
        player = nil
    }

    @objc private func displayTick(_ timer: Timer) {
        updatePlayhead()
    }

    private func updatePlayhead() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let time = player?.currentTime().seconds ?? 0
        let progress = min(max(
            (time.isFinite ? time : 0) / max(durationSeconds, 0.001),
            0
        ), 1)
        let x = bounds.width * progress
        guard !lastX.isFinite || abs(lastX - x) > 0.02 else { return }
        lastX = x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.frame = CGRect(x: x, y: 0, width: 2, height: bounds.height)
        CATransaction.commit()
    }
}

struct VideoEditorSocialSafeAreaOverlay: View {
    let aspectRatio: AutoEditPlan.Export.AspectRatio

    private var title: String {
        switch aspectRatio {
        case .vertical9x16: "竖屏 9:16"
        case .square1x1: "方形 1:1"
        }
    }

    private var topInset: CGFloat {
        switch aspectRatio {
        case .vertical9x16: 0.12
        case .square1x1: 0.08
        }
    }

    private var bottomInset: CGFloat {
        switch aspectRatio {
        case .vertical9x16: 0.16
        case .square1x1: 0.08
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let safeRect = CGRect(
                x: proxy.size.width * 0.08,
                y: proxy.size.height * topInset,
                width: proxy.size.width * 0.84,
                height: proxy.size.height * max(1 - topInset - bottomInset, 0.2)
            )
            Canvas { context, size in
                context.fill(
                    Path(CGRect(
                        x: 0,
                        y: 0,
                        width: size.width,
                        height: safeRect.minY
                    )),
                    with: .color(LensGlassPalette.warning.opacity(0.08))
                )
                context.fill(
                    Path(CGRect(
                        x: 0,
                        y: safeRect.maxY,
                        width: size.width,
                        height: max(size.height - safeRect.maxY, 0)
                    )),
                    with: .color(LensGlassPalette.warning.opacity(0.08))
                )
                context.stroke(
                    Path(roundedRect: safeRect, cornerRadius: 8),
                    with: .color(.white.opacity(0.72)),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
                context.draw(
                    Text("安全区 · \(title)")
                        .font(.system(size: LensType.micro, weight: .semibold))
                        .foregroundStyle(.white),
                    at: CGPoint(x: safeRect.minX + 42, y: safeRect.minY + 11)
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("社交画幅安全区")
        .accessibilityValue(title)
        .accessibilityHint("字幕和关键内容尽量放在中间虚线框内，橙色区域可能被平台控件遮挡")
    }
}

private struct VideoEditorCanvasPreview: View {
    let player: AVPlayer
    let canvas: AutoEditPlan.Canvas?
    let camera: AutoEditPlan.Camera?
    let cursor: AutoEditPlan.Cursor?
    let interaction: AutoEditPlan.Interaction?
    let timeline: VideoEditTimeline?

    var body: some View {
        GeometryReader { proxy in
            if let canvas, canvas.isEnabled {
                let contentRect = VideoEditorCanvasPreviewLayout.contentRect(
                    in: proxy.size,
                    margin: canvas.margin
                )
                let cornerRadius = VideoEditorCanvasPreviewLayout.cornerRadius(
                    in: proxy.size,
                    amount: canvas.cornerRadius
                )
                let shortestSide = min(proxy.size.width, proxy.size.height)

                LinearGradient(
                    colors: [
                        VideoEditorCanvasColor.color(
                            hex: canvas.backgroundTopHex,
                            fallback: Color(
                            red: 0.85,
                            green: 0.84,
                            blue: 0.81
                        )),
                        VideoEditorCanvasColor.color(
                            hex: canvas.backgroundBottomHex,
                            fallback: Color(
                            red: 0.62,
                            green: 0.66,
                            blue: 0.65
                        ))
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                liveCameraPlayer(in: contentRect.size)
                    .frame(width: contentRect.width, height: contentRect.height)
                    .clipShape(RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    ))
                    .shadow(
                        color: .black.opacity(min(max(canvas.shadowOpacity, 0), 1)),
                        radius: shortestSide * 0.018,
                        y: shortestSide * 0.012
                    )
                    .position(x: contentRect.midX, y: contentRect.midY)
            } else {
                Color.black
                liveCameraPlayer(in: proxy.size)
            }
        }
    }

    private func liveCameraPlayer(in size: CGSize) -> some View {
        ZStack {
            if let camera {
                VideoEditorLiveCameraPlayer(
                    player: player,
                    camera: camera,
                    cursor: cursor,
                    interaction: interaction,
                    timeline: timeline,
                    size: size
                )
            } else {
                VideoEditorPlayerView(player: player)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

private struct VideoEditorLiveCameraPlayer: View {
    let player: AVPlayer
    let camera: AutoEditPlan.Camera
    let cursor: AutoEditPlan.Cursor?
    let interaction: AutoEditPlan.Interaction?
    let timeline: VideoEditTimeline?
    let size: CGSize

    var body: some View {
        VideoEditorRealtimeCameraPlayerView(
            player: player,
            camera: camera,
            cursor: cursor,
            interaction: interaction,
            timeline: timeline
        )
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

private struct VideoEditorRealtimeCameraPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let camera: AutoEditPlan.Camera
    let cursor: AutoEditPlan.Cursor?
    let interaction: AutoEditPlan.Interaction?
    let timeline: VideoEditTimeline?

    func makeNSView(context: Context) -> VideoEditorRealtimeCameraNSView {
        VideoEditorRealtimeCameraNSView(
            player: player,
            camera: camera,
            cursor: cursor,
            interaction: interaction,
            timeline: timeline
        )
    }

    func updateNSView(
        _ view: VideoEditorRealtimeCameraNSView,
        context: Context
    ) {
        view.configure(
            player: player,
            camera: camera,
            cursor: cursor,
            interaction: interaction,
            timeline: timeline
        )
    }

    static func dismantleNSView(
        _ view: VideoEditorRealtimeCameraNSView,
        coordinator: Void
    ) {
        view.stop()
    }
}

private final class VideoEditorRealtimeCameraNSView: NSView {
    private let playerView = AVPlayerView()
    private let cursorOverlayView = VideoEditorCursorOverlayNSView()
    private var camera: AutoEditPlan.Camera
    private var cursor: AutoEditPlan.Cursor?
    private var interaction: AutoEditPlan.Interaction?
    private var timeline: VideoEditTimeline?
    private var displayTimer: Timer?
    private var lastFrame = CGRect.null

    init(
        player: AVPlayer,
        camera: AutoEditPlan.Camera,
        cursor: AutoEditPlan.Cursor?,
        interaction: AutoEditPlan.Interaction?,
        timeline: VideoEditTimeline?
    ) {
        self.camera = camera
        self.cursor = cursor
        self.interaction = interaction
        self.timeline = timeline
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.setAccessibilityElement(false)
        playerView.setAccessibilityHidden(true)
        addSubview(playerView)
        cursorOverlayView.configure(cursor: cursor, interaction: interaction)
        addSubview(cursorOverlayView)

        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(displayTick(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        lastFrame = .null
        updateCameraFrame()
    }

    func configure(
        player: AVPlayer,
        camera: AutoEditPlan.Camera,
        cursor: AutoEditPlan.Cursor?,
        interaction: AutoEditPlan.Interaction?,
        timeline: VideoEditTimeline?
    ) {
        let playerChanged = playerView.player !== player
        let cameraChanged = self.camera != camera
        let cursorChanged = self.cursor != cursor
        let interactionChanged = self.interaction != interaction
        let timelineChanged = self.timeline != timeline

        if playerChanged { playerView.player = player }
        if cameraChanged {
            self.camera = camera
            lastFrame = .null
        }
        if timelineChanged {
            self.timeline = timeline
            lastFrame = .null
        }
        if cursorChanged || interactionChanged {
            self.cursor = cursor
            self.interaction = interaction
            cursorOverlayView.configure(cursor: cursor, interaction: interaction)
        }
        if playerChanged || cameraChanged || timelineChanged
            || cursorChanged || interactionChanged {
            updateCameraFrame()
        }
    }

    func stop() {
        displayTimer?.invalidate()
        displayTimer = nil
        playerView.player = nil
    }

    @objc private func displayTick(_ timer: Timer) {
        updateCameraFrame()
    }

    private func updateCameraFrame() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let outputTime = playerView.player?.currentTime().seconds ?? 0
        let sourceTime = timeline?.position(atOutputTime: outputTime)?.sourceTimeSeconds
            ?? outputTime
        let cameraState = EffectTimeline.effectiveCameraState(
            at: sourceTime,
            camera: camera
        )
        cursorOverlayView.update(
            sourceTime: sourceTime,
            cameraState: cameraState,
            sourcePixelWidth: playerView.player?.currentItem?.presentationSize.width
        )
        let transform = VideoEditorCanvasPreviewLayout.cameraTransform(
            in: bounds.size,
            camera: camera,
            sourceTimeSeconds: sourceTime
        )
        let frame = VideoEditorCanvasPreviewLayout.playerFrame(
            in: bounds.size,
            transform: transform
        )
        let presentation = playerView.player?.currentItem?.presentationSize ?? .zero
        let overlayFrame = CameraPresentationMapping.aspectFitRect(
            for: presentation,
            in: frame
        )
        cursorOverlayView.frame = overlayFrame.width > 1 ? overlayFrame : frame
        guard !frame.approximatelyEquals(lastFrame) else { return }
        lastFrame = frame
        playerView.frame = frame
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 0.02) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

private struct PresenterCameraClipShape: Shape {
    let kind: AutoEditPlan.PresenterCamera.Shape
    let cornerRadius: Double

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .circle:
            Path(ellipseIn: rect)
        case .roundedRectangle:
            Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height)
                * min(max(cornerRadius, 0), 0.5))
        }
    }
}

struct LensInspectorSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var suffix: String = ""
    var onContinuousBegin: (() -> Void)? = nil
    var onContinuousEnd: (() -> Void)? = nil
    var onEditingEnded: (() -> Void)? = nil

    @State private var localValue: Double = 0
    @State private var isDragging: Bool = false
    @State private var lastEmittedTime: CFTimeInterval = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 62, alignment: .leading)
            sliderControl
            Text(String(format: "%.2f%@", isDragging ? localValue : value, suffix))
                .font(.system(size: LensType.micro, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: suffix.isEmpty ? 32 : 40, alignment: .trailing)
        }
        .onAppear {
            localValue = value
        }
        .onChange(of: value) { _, next in
            if !isDragging {
                localValue = next
            }
        }
    }

    @ViewBuilder
    private var sliderControl: some View {
        if let step {
            Slider(
                value: Binding(
                    get: { isDragging ? localValue : value },
                    set: { next in
                        localValue = next
                        throttleOrCommit(next)
                    }
                ),
                in: range,
                step: step,
                onEditingChanged: handleEditingChanged
            )
            .accessibilityLabel(title)
            .accessibilityValue(String(
                format: "%.2f%@",
                isDragging ? localValue : value,
                suffix
            ))
        } else {
            Slider(
                value: Binding(
                    get: { isDragging ? localValue : value },
                    set: { next in
                        localValue = next
                        throttleOrCommit(next)
                    }
                ),
                in: range,
                onEditingChanged: handleEditingChanged
            )
            .accessibilityLabel(title)
            .accessibilityValue(String(
                format: "%.2f%@",
                isDragging ? localValue : value,
                suffix
            ))
        }
    }

    private func throttleOrCommit(_ next: Double) {
        let now = CACurrentMediaTime()
        if now - lastEmittedTime >= 0.033 {
            lastEmittedTime = now
            value = next
        }
    }

    private func handleEditingChanged(_ isEditing: Bool) {
        isDragging = isEditing
        if isEditing {
            localValue = value
            lastEmittedTime = CACurrentMediaTime()
            onContinuousBegin?()
        } else {
            value = localValue
            onContinuousEnd?()
            onEditingEnded?()
        }
    }
}

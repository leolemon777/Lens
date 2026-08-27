import AVKit
import LensCore
import SwiftUI

enum VideoEditorInspectorSection: Hashable {
    case captions
    case export
}

struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var playback: VideoEditorPlaybackController
    let title: String
    let initialInspectorSection: VideoEditorInspectorSection?
    let onRegenerateCamera: () -> Void
    let onRefreshPreview: () -> Void
    let onSave: () -> Void
    let onExport: () -> Void
    let onClose: () -> Void

    @State private var presenterDragStart: PresenterCameraFrameState?
    @State private var presenterResizeStart: PresenterCameraFrameState?
    @State private var inspectorScrollPosition: VideoEditorInspectorSection?
    @State private var isCaptionCueEditorExpanded: Bool
    @State private var isAdvancedCameraExpanded = false
    @State private var isCursorDetailExpanded = false
    @State private var isClickDetailExpanded = false
    @State private var showsAdvancedEditingTools: Bool

    init(
        model: VideoEditorModel,
        playback: VideoEditorPlaybackController,
        title: String,
        initialInspectorSection: VideoEditorInspectorSection? = nil,
        onRegenerateCamera: @escaping () -> Void = {},
        onRefreshPreview: @escaping () -> Void = {},
        onSave: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.playback = playback
        self.title = title
        self.initialInspectorSection = initialInspectorSection
        self.onRegenerateCamera = onRegenerateCamera
        self.onRefreshPreview = onRefreshPreview
        self.onSave = onSave
        self.onExport = onExport
        self.onClose = onClose
        _inspectorScrollPosition = State(initialValue: initialInspectorSection)
        _isCaptionCueEditorExpanded = State(
            initialValue: initialInspectorSection == .captions
        )
        _showsAdvancedEditingTools = State(initialValue: initialInspectorSection != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.32)
            HStack(spacing: 0) {
                workspace
                Divider().opacity(0.32)
                inspector
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
            playback.invalidateRenderedPreview()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.red.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "timeline.selection")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Label("非破坏性编辑 · 原始录屏与独立轨道不会改写", systemImage: "lock.shield")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isDirty {
                Text("未保存")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.12), in: Capsule())
            }
            Button(action: model.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .help("撤销")
            .accessibilityLabel("撤销")
            .keyboardShortcut("z", modifiers: .command)
            Button(action: model.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .help("重做")
            .accessibilityLabel("重做")
            .keyboardShortcut("z", modifiers: [.command, .shift])
            Button(action: onSave) {
                HStack(spacing: 6) {
                    if model.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.isProcessing
                        ? "正在生成"
                        : (model.isDirty ? "保存并重新生成" : "重新生成预览"))
                }
            }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(model.isProcessing)
                .keyboardShortcut("s", modifiers: .command)
            Button(action: onExport) {
                Label("导出 MP4", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(model.isProcessing)
            .help("按当前质量预设生成并导出 MP4")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel("关闭视频编辑器")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .lensGlassSurface(role: .chrome, cornerRadius: 0)
    }

    private var workspace: some View {
        VStack(spacing: 14) {
            preview
            transport
            timeline
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
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
                    .padding(8)
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
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(LensGlassPalette.midnight.opacity(0.68), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.6))
                    Spacer()
                }
                Spacer()
            }
            .padding(14)
            .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
        .aspectRatio(playback.videoAspectRatio, contentMode: .fit)
        .frame(maxHeight: 460)
    }

    private func manualCameraFocusOverlay(in contentRect: CGRect) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.cyan.opacity(0.001))
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(LensGlassPalette.midnight.opacity(0.78), in: Capsule())
                    .overlay(Capsule().stroke(.cyan.opacity(0.72), lineWidth: 1))
                    .padding(12)
                Spacer()
            }

            Image(systemName: "scope")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.cyan.opacity(0.72))
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
                .overlay(clipShape.stroke(.cyan.opacity(0.94), lineWidth: 2))
                .overlay(clipShape.stroke(.white.opacity(0.42), lineWidth: 0.6).padding(3))
                .contentShape(clipShape)
                .shadow(color: .black.opacity(0.34), radius: 14, y: 7)
                .gesture(presenterDragGesture(
                    current: state,
                    contentSize: contentSize
                ))

            Circle()
                .fill(LensGlassPalette.midnight.opacity(0.72))
                .frame(width: 23, height: 23)
                .overlay(Circle().stroke(.white.opacity(0.62), lineWidth: 1))
                .overlay(
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8, weight: .bold))
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
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(LensGlassPalette.midnight.opacity(0.72), in: Capsule())
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
                Rectangle().fill(LensGlassPalette.midnight.opacity(0.78))
                LinearGradient(
                    colors: [.cyan.opacity(0.28), .indigo.opacity(0.24)],
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
            Text(timeText(playback.durationSeconds))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text("成片 \(timeText(model.outputDurationSeconds))")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.cyan)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.cyan.opacity(0.11), in: Capsule())
            Button(action: playback.togglePreviewMode) {
                Label(
                    playback.isShowingRenderedPreview ? "已生成效果" : "实时编辑",
                    systemImage: playback.isShowingRenderedPreview ? "sparkles.tv" : "film"
                )
                .font(.system(size: 9.5, weight: .bold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(playback.isShowingRenderedPreview ? .orange : .secondary)
            .disabled(
                !playback.canShowRenderedPreview
                    || playback.isLoading
                    || model.isManualCameraFocusEditing
            )
            .help(playback.isShowingRenderedPreview
                ? "当前播放上次保存后生成的完整成片；修改参数后会自动切换实时编辑"
                : "当前使用原始素材实时显示运镜、光标和点击；后台成片完成后不会在播放途中强制换源")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("时间线", systemImage: "timeline.selection")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(model.activeSegments.count) 个片段")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                timelineButton("设为入点", symbol: "inset.filled.leadinghalf.rectangle") {
                    model.trimSelectedStart(toOutputTime: playback.currentTimeSeconds)
                }
                timelineButton("分割", symbol: "scissors") {
                    model.split(atOutputTime: playback.currentTimeSeconds)
                }
                timelineButton("设为出点", symbol: "inset.filled.trailinghalf.rectangle") {
                    model.trimSelectedEnd(toOutputTime: playback.currentTimeSeconds)
                }
                timelineButton("移出成片", symbol: "trash") {
                    model.removeSelectedSegment()
                }
                .disabled(!model.canRemoveSelectedSegment)
            }
            GeometryReader { proxy in
                let total = max(model.outputDurationSeconds, 0.001)
                let availableWidth = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    ForEach(Array(model.activeSegments.enumerated()), id: \.element.id) { index, segment in
                        let layout = model.segmentLayouts[index]
                        let segmentWidth = max(
                            availableWidth * layout.outputDurationSeconds / total,
                            38
                        )
                        let segmentStart = availableWidth
                            * layout.outputStartSeconds / total
                        Button {
                            model.selectSegment(segment.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("片段 \(index + 1)")
                                    .font(.system(size: 9.5, weight: .bold))
                                Text(String(
                                    format: "%.1f–%.1f s · %.2gx",
                                    segment.sourceStartSeconds,
                                    segment.sourceEndSeconds,
                                    segment.playbackRate
                                ))
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .opacity(0.74)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .background(
                                LinearGradient(
                                    colors: index.isMultiple(of: 2)
                                        ? [.cyan.opacity(0.82), .blue.opacity(0.76)]
                                        : [.indigo.opacity(0.82), .purple.opacity(0.74)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(
                                        model.selectedSegmentID == segment.id
                                            ? .white.opacity(0.95)
                                            : .white.opacity(0.18),
                                        lineWidth: model.selectedSegmentID == segment.id ? 2 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(width: segmentWidth, height: 58)
                        .offset(x: segmentStart)
                        .zIndex(model.selectedSegmentID == segment.id ? 2 : Double(index % 2))
                        .accessibilityLabel("片段 \(index + 1)")
                        .accessibilityValue(String(
                            format: "源时间 %.1f 到 %.1f 秒，%.2g 倍速",
                            segment.sourceStartSeconds,
                            segment.sourceEndSeconds,
                            segment.playbackRate
                        ))
                    }
                    ForEach(model.resolvedTransitions, id: \.fromSegmentID) { transition in
                        let center = availableWidth
                            * (transition.outputStartSeconds
                                + transition.durationSeconds / 2) / total
                        Image(systemName: transition.kind == .crossDissolve
                            ? "circle.lefthalf.filled"
                            : "circle.bottomhalf.filled")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.black.opacity(0.58), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 0.7))
                            .offset(x: center - 10, y: 19)
                            .zIndex(4)
                            .help(transition.kind == .crossDissolve
                                ? String(format: "交叉叠化 · %.2f 秒", transition.durationSeconds)
                                : String(format: "淡入黑场 · %.2f 秒", transition.durationSeconds))
                    }
                    ForEach(model.videoAnnotationOutputBands) { band in
                        let start = availableWidth * band.range.startSeconds / total
                        let width = max(
                            availableWidth
                                * (band.range.endSeconds - band.range.startSeconds) / total,
                            5
                        )
                        Button {
                            playback.seek(to: band.range.startSeconds + 0.02)
                            model.selectVideoAnnotation(band.annotationID)
                        } label: {
                            Capsule()
                                .fill(
                                    model.selectedVideoAnnotationID == band.annotationID
                                        ? Color.yellow
                                        : Color.orange.opacity(0.92)
                                )
                                .overlay(Capsule().stroke(.white.opacity(0.55), lineWidth: 0.6))
                        }
                        .buttonStyle(.plain)
                        .frame(width: width, height: 6)
                        .offset(x: start, y: 23)
                        .zIndex(5)
                        .help("视频标注 · \(captionTimeText(band.range.startSeconds))")
                        .accessibilityLabel("视频标注")
                        .accessibilityValue("\(captionTimeText(band.range.startSeconds)) 开始")
                    }
                    ForEach(
                        Array(model.manualCameraFocusOutputTimes.enumerated()),
                        id: \.offset
                    ) { _, focusTime in
                        let progress = min(max(focusTime / total, 0), 1)
                        let markerCenter = min(max(
                            availableWidth * progress,
                            7
                        ), max(availableWidth - 7, 7))
                        Button {
                            playback.seek(to: focusTime)
                        } label: {
                            Image(systemName: "scope")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.cyan)
                                .shadow(color: .black.opacity(0.45), radius: 2)
                                .frame(width: 14, height: 58)
                        }
                        .buttonStyle(.plain)
                        .offset(x: markerCenter - 7)
                        .help("手动缩放 · \(captionTimeText(focusTime))")
                        .accessibilityLabel("手动缩放关键帧")
                        .accessibilityValue(captionTimeText(focusTime))
                    }
                    ForEach(
                        Array(model.presenterKeyframeOutputTimes.enumerated()),
                        id: \.offset
                    ) { _, keyframeTime in
                        let progress = min(max(keyframeTime / total, 0), 1)
                        let markerCenter = min(max(
                            availableWidth * progress,
                            7
                        ), max(availableWidth - 7, 7))
                        Button {
                            playback.seek(to: keyframeTime)
                        } label: {
                            Image(systemName: "diamond.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.yellow)
                                .shadow(color: .black.opacity(0.45), radius: 2)
                                .frame(width: 14, height: 58)
                        }
                        .buttonStyle(.plain)
                        .offset(x: markerCenter - 7)
                        .help("讲解人像关键帧 · \(captionTimeText(keyframeTime))")
                        .accessibilityLabel("讲解人像关键帧")
                        .accessibilityValue(captionTimeText(keyframeTime))
                    }
                    VideoEditorTimelinePlayhead(
                        player: playback.player,
                        durationSeconds: total
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 58)
            .clipped()

            if let selected = model.selectedSegment {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("所选片段速度")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker("速度", selection: Binding(
                            get: { selected.playbackRate },
                            set: { model.setSelectedPlaybackRate($0) }
                        )) {
                            Text("0.5×").tag(0.5)
                            Text("1×").tag(1.0)
                            Text("1.5×").tag(1.5)
                            Text("2×").tag(2.0)
                            Text("3×").tag(3.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                        Spacer()
                        Text("源素材 \(timeText(model.sourceDurationSeconds))")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("到下一片段")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker("转场", selection: Binding(
                            get: { model.selectedTransitionKind },
                            set: { model.setSelectedTransitionKind($0) }
                        )) {
                            Text("直接切换").tag(VideoEditTransition.Kind.cut)
                            Text("交叉叠化").tag(VideoEditTransition.Kind.crossDissolve)
                            Text("淡入黑场").tag(VideoEditTransition.Kind.dipToBlack)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                        .disabled(!model.canTransitionFromSelectedSegment)
                        if model.canTransitionFromSelectedSegment,
                           model.selectedTransitionKind != .cut {
                            let resolvedDuration = model.selectedResolvedTransitionDuration
                                ?? model.selectedTransitionDuration
                            let wasClamped = abs(
                                resolvedDuration - model.selectedTransitionDuration
                            ) > 0.005
                            Slider(
                                value: Binding(
                                    get: { model.selectedTransitionDuration },
                                    set: { model.setSelectedTransitionDuration($0) }
                                ),
                                in: 0.15...1.2
                            )
                            .frame(width: 112)
                            .accessibilityLabel("转场时长")
                            .accessibilityValue(String(
                                format: "%.2f 秒%@",
                                resolvedDuration,
                                wasClamped ? "，已限幅" : ""
                            ))
                            Text(String(
                                format: wasClamped ? "%.2f s · 已限幅" : "%.2f s",
                                resolvedDuration
                            ))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(wasClamped ? .orange : .cyan)
                        }
                        Spacer()
                        if !model.canTransitionFromSelectedSegment {
                            Text("末尾片段无需转场")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(13)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }

    private var inspector: some View {
        ScrollView {
            VStack(spacing: 12) {
                inspectorSection("画面", symbol: "rectangle.inset.filled") {
                    Label(
                        playback.isShowingRenderedPreview
                            ? "当前是上次生成的成片；调整后自动切到实时预览"
                            : "画布正在实时预览",
                        systemImage: playback.isShowingRenderedPreview
                            ? "clock.arrow.circlepath"
                            : "bolt.fill"
                    )
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(
                        playback.isShowingRenderedPreview ? Color.secondary : Color.cyan
                    )
                    Toggle("背景画布", isOn: Binding(
                        get: { model.canvasEnabled },
                        set: { model.setCanvasEnabled($0) }
                    ))
                    valueSlider(
                        "留白",
                        value: Binding(
                            get: { model.plan.canvas?.margin ?? 0.055 },
                            set: { model.setCanvasMargin($0) }
                        ),
                        range: 0...0.18
                    )
                    valueSlider(
                        "圆角",
                        value: Binding(
                            get: { model.plan.canvas?.cornerRadius ?? 0.026 },
                            set: { model.setCanvasCornerRadius($0) }
                        ),
                        range: 0...0.12
                    )
                    valueSlider(
                        "阴影",
                        value: Binding(
                            get: { model.plan.canvas?.shadowOpacity ?? 0.24 },
                            set: { model.setCanvasShadowOpacity($0) }
                        ),
                        range: 0...0.65
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("背景")
                            Spacer()
                            Text(selectedCanvasPresetTitle)
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(
                            columns: [GridItem(
                                .adaptive(minimum: 28, maximum: 28),
                                spacing: 10
                            )],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(VideoEditorCanvasBackgroundPreset.all) { preset in
                                canvasPresetButton(
                                    preset,
                                    selected: preset.matches(model.plan.canvas)
                                ) {
                                    model.setCanvasPreset(
                                        topHex: preset.topHex,
                                        bottomHex: preset.bottomHex
                                    )
                                }
                            }
                        }
                    }
                }

                inspectorSection("运镜与交互", symbol: "camera.metering.center.weighted") {
                    Toggle("自动运镜", isOn: Binding(
                        get: { model.cameraMotionEnabled },
                        set: {
                            model.setCameraMotionEnabled($0)
                            onRefreshPreview()
                        }
                    ))
                    Toggle("点击自动推近", isOn: Binding(
                        get: { model.plan.camera.clickToZoom },
                        set: {
                            model.setClickToZoomEnabled($0)
                            onRegenerateCamera()
                        }
                    ))
                    Toggle("无点击时跟随光标", isOn: Binding(
                        get: { model.plan.camera.followPointer },
                        set: {
                            model.setCameraFollowPointerEnabled($0)
                            onRegenerateCamera()
                        }
                    ))
                    valueSlider(
                        "推近倍率",
                        value: Binding(
                            get: { model.plan.camera.resolvedZoomScale },
                            set: {
                                model.setAutomaticZoomScale($0)
                                onRegenerateCamera()
                            }
                        ),
                        range: 1...3,
                        step: 0.05,
                        suffix: "×"
                    )
                    Picker(
                        "生成强度",
                        selection: Binding(
                            get: { model.plan.camera.generationStrength },
                            set: {
                                model.setAutomaticCameraGenerationStrength($0)
                                onRegenerateCamera()
                            }
                        )
                    ) {
                        Text("克制").tag(AutoEditPlan.Camera.GenerationStrength.restrained)
                        Text("适中").tag(AutoEditPlan.Camera.GenerationStrength.balanced)
                        Text("积极").tag(AutoEditPlan.Camera.GenerationStrength.active)
                    }
                    .pickerStyle(.segmented)
                    Button(action: onRegenerateCamera) {
                        HStack(spacing: 6) {
                            if model.isRegeneratingCamera || model.isProcessing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                            }
                            Text(cameraGenerationButtonTitle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRegeneratingCamera || model.isProcessing)
                    .help("点击后把目标平滑带到视觉中心；无点击演示才跟随光标")
                    Text(automaticCameraPlanSummary)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    DisclosureGroup(isExpanded: $isAdvancedCameraExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            valueSlider(
                                "运动模糊",
                                value: Binding(
                                    get: { model.plan.camera.motionBlurStrength },
                                    set: {
                                        model.setCameraMotionBlurStrength($0)
                                        onRefreshPreview()
                                    }
                                ),
                                range: 0...1
                            )
                            Divider().opacity(0.28)
                            Label("手动点选镜头（不改变自动运镜）", systemImage: "scope")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                            valueSlider(
                                "点选倍率",
                                value: $model.manualCameraScale,
                                range: 1.2...3
                            )
                            valueSlider(
                                "点选停留",
                                value: $model.manualCameraHoldSeconds,
                                range: 0.3...4
                            )
                            HStack(spacing: 6) {
                                Button {
                                    if model.isManualCameraFocusEditing {
                                        model.cancelManualCameraFocusEditing()
                                    } else {
                                        playback.showRawPreview()
                                        model.activateManualCameraFocusEditing()
                                    }
                                } label: {
                                    Label(
                                        model.isManualCameraFocusEditing
                                            ? "取消点选"
                                            : "点选缩放位置",
                                        systemImage: model.isManualCameraFocusEditing
                                            ? "xmark.circle"
                                            : "scope"
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(model.isManualCameraFocusEditing ? .orange : .cyan)
                                if model.manualCameraFocusCount > 0 {
                                    Button("清除 \(model.manualCameraFocusCount) 处") {
                                        model.clearManualCameraFocuses()
                                        onRefreshPreview()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            Text(model.isManualCameraFocusEditing
                                ? "已切到原始画面；点击预览即在当前播放头添加缩放。"
                                : "有点击时，镜头只以被点击目标构图并稳定停留；没有点击时，才会响应明确的光标移动。")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 7)
                    } label: {
                        Label("高级运镜", systemImage: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }

                inspectorSection("光标与点击", symbol: "cursorarrow.rays") {
                    Toggle("重绘光标", isOn: Binding(
                        get: { model.cursorEnabled },
                        set: {
                            model.setCursorEnabled($0)
                            onRefreshPreview()
                        }
                    ))

                    DisclosureGroup(isExpanded: $isCursorDetailExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("实际样式")
                                    .frame(width: 62, alignment: .leading)
                                Picker("实际样式", selection: Binding(
                                    get: { model.plan.cursor.appearance },
                                    set: {
                                        model.setCursorAppearance($0)
                                        onRefreshPreview()
                                    }
                                )) {
                                    ForEach(cursorAppearanceOptions, id: \.value) { option in
                                        Text(option.title).tag(option.value)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            Text(cursorAppearanceDescription)
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.secondary)

                            valueSlider(
                                "光标大小",
                                value: Binding(
                                    get: { model.plan.cursor.scale },
                                    set: { model.setCursorScale($0) }
                                ),
                                range: 0.7...2.2,
                                onEditingEnded: onRefreshPreview
                            )
                            HStack(spacing: 8) {
                                Text("移动特效")
                                    .frame(width: 62, alignment: .leading)
                                Picker("移动特效", selection: Binding(
                                    get: { model.plan.cursor.motionEffect },
                                    set: {
                                        model.setCursorMotionEffect($0)
                                        onRefreshPreview()
                                    }
                                )) {
                                    ForEach(cursorMotionEffectOptions, id: \.value) { option in
                                        Text(option.title).tag(option.value)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            valueSlider(
                                "特效强度",
                                value: Binding(
                                    get: { model.plan.cursor.motionEffectStrength },
                                    set: { model.setCursorMotionEffectStrength($0) }
                                ),
                                range: 0.1...1,
                                onEditingEnded: onRefreshPreview
                            )
                            .disabled(model.plan.cursor.motionEffect == .none)
                            .opacity(model.plan.cursor.motionEffect == .none ? 0.45 : 1)
                            HStack(spacing: 10) {
                                Text("特效颜色")
                                    .frame(width: 62, alignment: .leading)
                                ForEach(cursorAccentColors, id: \.hex) { option in
                                    Button {
                                        model.setCursorAccentColorHex(option.hex)
                                        onRefreshPreview()
                                    } label: {
                                        Circle()
                                            .fill(VideoEditorCanvasColor.color(
                                                hex: option.hex,
                                                fallback: .cyan
                                            ))
                                            .frame(width: 18, height: 18)
                                            .overlay(Circle().stroke(
                                                .white.opacity(0.35),
                                                lineWidth: 0.8
                                            ))
                                            .overlay {
                                                if model.plan.cursor.accentColorHex == option.hex {
                                                    Circle().stroke(.cyan, lineWidth: 2)
                                                        .frame(width: 23, height: 23)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .help(option.name)
                                }
                            }
                            HStack(spacing: 8) {
                                Text("平滑窗口")
                                    .frame(width: 62, alignment: .leading)
                                Slider(
                                    value: Binding(
                                        get: {
                                            model.plan.cursor.resolvedSmoothingWindowMilliseconds
                                        },
                                        set: {
                                            model.setCursorSmoothingWindowMilliseconds($0)
                                        }
                                    ),
                                    in: 0...120,
                                    onEditingChanged: { isEditing in
                                        if !isEditing { onRefreshPreview() }
                                    }
                                )
                                .accessibilityLabel("光标平滑窗口")
                                .accessibilityValue(String(
                                    format: "%.0f 毫秒",
                                    model.plan.cursor.resolvedSmoothingWindowMilliseconds
                                ))
                                Text(String(
                                    format: "%.0fms",
                                    model.plan.cursor.resolvedSmoothingWindowMilliseconds
                                ))
                                .font(.system(
                                    size: 8.5,
                                    weight: .medium,
                                    design: .monospaced
                                ))
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                            }
                            Toggle("静止时隐藏", isOn: Binding(
                                get: { model.plan.cursor.hidesWhenIdle },
                                set: {
                                    model.setCursorHidesWhenIdle($0)
                                    onRefreshPreview()
                                }
                            ))
                        }
                        .padding(.top, 7)
                    } label: {
                        Label("光标细节", systemImage: "cursorarrow.motionlines")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .disabled(!model.cursorEnabled)
                    .opacity(model.cursorEnabled ? 1 : 0.48)

                    Toggle("点击反馈", isOn: Binding(
                        get: { model.clickPulseEnabled },
                        set: {
                            model.setClickPulseEnabled($0)
                            onRefreshPreview()
                        }
                    ))

                    DisclosureGroup(isExpanded: $isClickDetailExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("点击效果")
                                    .frame(width: 62, alignment: .leading)
                                Picker("点击效果", selection: Binding(
                                    get: {
                                        model.plan.interaction?.clickEffect ?? .ripple
                                    },
                                    set: {
                                        model.setClickEffect($0)
                                        onRefreshPreview()
                                    }
                                )) {
                                    ForEach(clickEffectOptions, id: \.value) { option in
                                        Text(option.title).tag(option.value)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            valueSlider(
                                "效果强度",
                                value: Binding(
                                    get: {
                                        model.plan.interaction?.clickEffectStrength ?? 1
                                    },
                                    set: { model.setClickEffectStrength($0) }
                                ),
                                range: 0.1...1,
                                onEditingEnded: onRefreshPreview
                            )
                            valueSlider(
                                "效果大小",
                                value: Binding(
                                    get: { model.plan.interaction?.clickPulseScale ?? 1.25 },
                                    set: { model.setClickPulseScale($0) }
                                ),
                                range: 0.5...2,
                                onEditingEnded: onRefreshPreview
                            )
                            valueSlider(
                                "效果时长",
                                value: Binding(
                                    get: { model.plan.interaction?.clickPulseDuration ?? 0.62 },
                                    set: { model.setClickPulseDuration($0) }
                                ),
                                range: 0.15...1.2,
                                onEditingEnded: onRefreshPreview
                            )
                            HStack(spacing: 10) {
                                Text("效果颜色")
                                    .frame(width: 62, alignment: .leading)
                                ForEach(clickPulseColors, id: \.hex) { option in
                                    Button {
                                        model.setClickPulseColorHex(option.hex)
                                        onRefreshPreview()
                                    } label: {
                                        Circle()
                                            .fill(VideoEditorCanvasColor.color(
                                                hex: option.hex,
                                                fallback: .cyan
                                            ))
                                            .frame(width: 18, height: 18)
                                            .overlay(Circle().stroke(
                                                .white.opacity(0.35),
                                                lineWidth: 0.8
                                            ))
                                            .overlay {
                                                if model.plan.interaction?.clickPulseColorHex
                                                    == option.hex {
                                                    Circle().stroke(.cyan, lineWidth: 2)
                                                        .frame(width: 23, height: 23)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .help(option.name)
                                }
                            }
                        }
                        .padding(.top, 7)
                    } label: {
                        Label("点击特效细节", systemImage: "cursorarrow.click.2")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .disabled(!model.clickPulseEnabled)
                    .opacity(model.clickPulseEnabled ? 1 : 0.48)
                }

                Button {
                    showsAdvancedEditingTools.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(showsAdvancedEditingTools ? "收起更多工具" : "更多编辑工具")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("视频标注 · 讲解人像 · 字幕 · 导出预设")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: showsAdvancedEditingTools
                            ? "chevron.up"
                            : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsAdvancedEditingTools
                    ? "收起更多编辑工具"
                    : "展开更多编辑工具")

                if showsAdvancedEditingTools {
                    inspectorSection("视频标注", symbol: "pencil.and.outline") {
                    HStack(spacing: 6) {
                        Button {
                            model.activateVideoAnnotationSelection()
                        } label: {
                            Label("选择", systemImage: "cursorarrow")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.isVideoAnnotationSelectionMode ? .cyan : .secondary)
                        Button {
                            if model.isVideoAnnotationEditing {
                                model.finishVideoAnnotationEditing()
                            } else {
                                model.activateVideoAnnotationTool(
                                    model.selectedVideoAnnotationTool
                                )
                            }
                        } label: {
                            Label(
                                model.isVideoAnnotationEditing ? "完成" : "画布编辑",
                                systemImage: model.isVideoAnnotationEditing
                                    ? "checkmark.circle.fill"
                                    : "hand.draw"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(model.isVideoAnnotationEditing ? .green : .cyan)
                    }

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3),
                        spacing: 5
                    ) {
                        ForEach(ScreenshotAnnotationKind.allCases, id: \.self) { tool in
                            annotationToolButton(tool)
                        }
                    }

                    HStack(spacing: 7) {
                        Text("颜色")
                        Spacer()
                        ForEach(videoAnnotationColors, id: \.name) { item in
                            Button {
                                model.setVideoAnnotationColor(item.color)
                            } label: {
                                Circle()
                                    .fill(item.color.swiftUIColor)
                                    .frame(width: 17, height: 17)
                                    .overlay(Circle().stroke(
                                        model.selectedVideoAnnotationColor == item.color
                                            ? Color.primary
                                            : Color.white.opacity(0.30),
                                        lineWidth: model.selectedVideoAnnotationColor == item.color
                                            ? 2
                                            : 1
                                    ))
                                    .padding(2)
                            }
                            .buttonStyle(.plain)
                            .help(item.name)
                            .accessibilityLabel("\(item.name)视频标注颜色")
                            .accessibilityHint("选择视频标注颜色")
                            .accessibilityAddTraits(
                                model.selectedVideoAnnotationColor == item.color
                                    ? .isSelected
                                    : []
                            )
                        }
                    }

                    if model.selectedVideoAnnotationTool == .text
                        || model.selectedVideoAnnotation?.annotation.kind == .text {
                        HStack(spacing: 6) {
                            TextField("标注文字", text: $model.videoAnnotationTextDraft)
                                .textFieldStyle(.roundedBorder)
                            if model.selectedVideoAnnotation?.annotation.kind == .text {
                                Button("应用", action: model.applyVideoAnnotationTextDraft)
                                    .buttonStyle(.borderless)
                            }
                        }
                    }

                    valueSlider(
                        model.selectedVideoAnnotation == nil ? "默认时长" : "显示时长",
                        value: Binding(
                            get: {
                                model.selectedVideoAnnotation?.sourceDurationSeconds
                                    ?? model.defaultVideoAnnotationDurationSeconds
                            },
                            set: { model.setSelectedVideoAnnotationDuration($0) }
                        ),
                        range: 0.05...30
                    )

                    if let selected = model.selectedVideoAnnotation {
                        valueSlider(
                            "淡入淡出",
                            value: Binding(
                                get: { selected.fadeDurationSeconds },
                                set: { model.setSelectedVideoAnnotationFadeDuration($0) }
                            ),
                            range: 0...0.8
                        )
                        if selected.annotation.kind == .blur
                            || selected.annotation.kind == .pixelate {
                            valueSlider(
                                "效果强度",
                                value: Binding(
                                    get: { selected.annotation.style.intensity },
                                    set: { model.setSelectedVideoAnnotationIntensity($0) }
                                ),
                                range: 0.01...0.12
                            )
                        } else if selected.annotation.kind != .highlight
                            && selected.annotation.kind != .step
                            && selected.annotation.kind != .text {
                            valueSlider(
                                "线条粗细",
                                value: Binding(
                                    get: { selected.annotation.style.lineWidth },
                                    set: { model.setSelectedVideoAnnotationLineWidth($0) }
                                ),
                                range: 0.002...0.04
                            )
                        }
                        HStack {
                            Text(String(
                                format: "源素材 %.2f–%.2f s",
                                selected.sourceStartSeconds,
                                selected.sourceEndSeconds
                            ))
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button("删除") {
                                model.deleteSelectedVideoAnnotation()
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }

                    Text(model.isVideoAnnotationEditing
                        ? "在预览中拖动绘制；选择工具可移动并拖拽控制点缩放。"
                        : "标注使用源素材时间，剪切、变速与重排后仍会自动对齐。")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                    inspectorSection("讲解人像", symbol: "person.crop.circle") {
                    Toggle("显示摄像头", isOn: Binding(
                        get: { model.presenterEnabled },
                        set: { model.setPresenterEnabled($0) }
                    ))
                    .disabled(!model.hasCameraTrack)
                    if model.hasCameraTrack {
                        HStack(spacing: 6) {
                            Text("形状")
                            Spacer()
                            choiceButton(
                                "圆形",
                                selected: model.plan.presenterCamera?.shape != .roundedRectangle
                            ) {
                                model.setPresenterShape(.circle)
                            }
                            choiceButton(
                                "圆角矩形",
                                selected: model.plan.presenterCamera?.shape == .roundedRectangle
                            ) {
                                model.setPresenterShape(.roundedRectangle)
                            }
                        }
                        HStack(spacing: 5) {
                            Text("位置")
                            Spacer()
                            ForEach([
                                ("左上", AutoEditPlan.PresenterCamera.Anchor.topLeading),
                                ("右上", AutoEditPlan.PresenterCamera.Anchor.topTrailing),
                                ("左下", AutoEditPlan.PresenterCamera.Anchor.bottomLeading),
                                ("右下", AutoEditPlan.PresenterCamera.Anchor.bottomTrailing)
                            ], id: \.0) { item in
                                choiceButton(
                                    item.0,
                                    selected: model.plan.presenterCamera?.position == nil
                                        && model.plan.presenterCamera?.anchor == item.1
                                ) {
                                    model.setPresenterAnchor(item.1)
                                }
                            }
                        }
                        valueSlider(
                            "大小",
                            value: Binding(
                                get: { model.plan.presenterCamera?.size ?? 0.19 },
                                set: { model.setPresenterSize($0) }
                            ),
                            range: 0.10...0.36
                        )
                        Toggle("镜像", isOn: Binding(
                            get: { model.plan.presenterCamera?.isMirrored != false },
                            set: { model.setPresenterMirrored($0) }
                        ))
                        Toggle("自动避让字幕与点击焦点", isOn: Binding(
                            get: { model.presenterAvoidanceEnabled },
                            set: { model.setPresenterAvoidanceEnabled($0) }
                        ))
                        Text("可直接在画布拖动人像，右下角控制点调整大小。")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 7) {
                            let hasKeyframe = model.hasPresenterKeyframe(
                                nearOutputTime: playback.currentTimeSeconds
                            )
                            Button {
                                if let time = model.previousPresenterKeyframeOutputTime(
                                    before: playback.currentTimeSeconds
                                ) {
                                    playback.seek(to: time)
                                }
                            } label: {
                                Image(systemName: "backward.end.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.previousPresenterKeyframeOutputTime(
                                before: playback.currentTimeSeconds
                            ) == nil)
                            .accessibilityLabel("上一个讲解人像关键帧")
                            Button {
                                if let time = model.nextPresenterKeyframeOutputTime(
                                    after: playback.currentTimeSeconds
                                ) {
                                    playback.seek(to: time)
                                }
                            } label: {
                                Image(systemName: "forward.end.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.nextPresenterKeyframeOutputTime(
                                after: playback.currentTimeSeconds
                            ) == nil)
                            .accessibilityLabel("下一个讲解人像关键帧")
                            Button(hasKeyframe ? "更新当前关键帧" : "添加当前关键帧") {
                                model.upsertPresenterKeyframe(
                                    atOutputTime: playback.currentTimeSeconds
                                )
                            }
                            .buttonStyle(.bordered)
                            if hasKeyframe {
                                Button("删除") {
                                    model.removePresenterKeyframe(
                                        nearOutputTime: playback.currentTimeSeconds
                                    )
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                            Spacer()
                            Text("\(model.presenterKeyframeCount) 帧")
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .disabled(!model.presenterEnabled)
                        if let easing = model.presenterKeyframeEasing(
                            nearOutputTime: playback.currentTimeSeconds
                        ) {
                            Picker("关键帧过渡", selection: Binding(
                                get: { easing },
                                set: {
                                    model.setPresenterKeyframeEasing(
                                        $0,
                                        atOutputTime: playback.currentTimeSeconds
                                    )
                                }
                            )) {
                                Text("柔和弹性").tag("spring-gentle")
                                Text("平滑").tag("spring-smooth")
                                Text("线性").tag("linear")
                                Text("渐入").tag("ease-in")
                                Text("渐出").tag("ease-out")
                            }
                            .pickerStyle(.menu)
                        }
                    } else {
                        Text("这条录屏没有摄像头原始轨。")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    }
                }

                inspectorSection("声音", symbol: "waveform") {
                    Toggle("启用混音", isOn: Binding(
                        get: { model.audioEnabled },
                        set: {
                            model.setAudioEnabled($0)
                            onRefreshPreview()
                        }
                    ))
                    valueSlider(
                        "系统声音",
                        value: Binding(
                            get: { model.plan.audio?.systemVolume ?? 1 },
                            set: { model.setSystemVolume($0) }
                        ),
                        range: 0...1.5,
                        onEditingEnded: onRefreshPreview
                    )
                    if model.hasMicrophoneTrack {
                        valueSlider(
                            "麦克风",
                            value: Binding(
                                get: { model.plan.audio?.microphoneVolume ?? 1 },
                                set: { model.setMicrophoneVolume($0) }
                            ),
                            range: 0...1.5,
                            onEditingEnded: onRefreshPreview
                        )
                        Toggle("降低环境噪声", isOn: Binding(
                            get: { model.microphoneNoiseReductionEnabled },
                            set: {
                                model.setMicrophoneNoiseReductionEnabled($0)
                                onRefreshPreview()
                            }
                        ))
                        if model.microphoneNoiseReductionEnabled {
                            valueSlider(
                                "降噪强度",
                                value: Binding(
                                    get: { model.plan.audio?.noiseReductionAmount ?? 0.55 },
                                    set: { model.setNoiseReductionAmount($0) }
                                ),
                                range: 0...1,
                                onEditingEnded: onRefreshPreview
                            )
                        }
                        Toggle("统一人声与系统响度", isOn: Binding(
                            get: { model.loudnessNormalizationEnabled },
                            set: {
                                model.setLoudnessNormalizationEnabled($0)
                                onRefreshPreview()
                            }
                        ))
                        if model.loudnessNormalizationEnabled {
                            Picker("人声目标响度", selection: Binding(
                                get: { model.plan.audio?.targetLoudnessLUFS ?? -16 },
                                set: {
                                    model.setTargetLoudnessLUFS($0)
                                    onRefreshPreview()
                                }
                            )) {
                                Text("响亮 · −14 LUFS").tag(-14.0)
                                Text("标准 · −16 LUFS").tag(-16.0)
                                Text("舒缓 · −18 LUFS").tag(-18.0)
                                Text("保守 · −20 LUFS").tag(-20.0)
                            }
                            .pickerStyle(.menu)
                        }
                        Toggle("讲话时自动压低系统声", isOn: Binding(
                            get: { model.plan.audio?.ducksSystemUnderNarration != false },
                            set: {
                                model.setDuckingEnabled($0)
                                onRefreshPreview()
                            }
                        ))
                        Text("降噪与响度处理仅作用于生成的预览，原始麦克风轨保持不变。")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                if showsAdvancedEditingTools {
                    inspectorSection("字幕", symbol: "captions.bubble") {
                    Toggle("烧录字幕", isOn: Binding(
                        get: { model.captionsEnabled },
                        set: {
                            model.setCaptionsEnabled($0)
                            onRefreshPreview()
                        }
                    ))
                    .disabled(!model.hasTranscript)
                    if model.hasTranscript {
                        HStack(spacing: 5) {
                            Text("样式")
                            Spacer()
                            choiceButton(
                                "玻璃",
                                selected: (model.plan.captions?.style ?? .glass) == .glass
                            ) {
                                model.setCaptionStyle(.glass)
                                onRefreshPreview()
                            }
                            choiceButton(
                                "简洁",
                                selected: model.plan.captions?.style == .clean
                            ) {
                                model.setCaptionStyle(.clean)
                                onRefreshPreview()
                            }
                            choiceButton(
                                "高对比",
                                selected: model.plan.captions?.style == .highContrast
                            ) {
                                model.setCaptionStyle(.highContrast)
                                onRefreshPreview()
                            }
                        }
                        HStack(spacing: 5) {
                            Text("位置")
                            Spacer()
                            ForEach([
                                ("顶部", AutoEditPlan.Captions.Position.top),
                                ("居中", AutoEditPlan.Captions.Position.center),
                                ("底部", AutoEditPlan.Captions.Position.bottom)
                            ], id: \.0) { item in
                                choiceButton(
                                    item.0,
                                    selected: (model.plan.captions?.position ?? .bottom) == item.1
                                ) {
                                    model.setCaptionPosition(item.1)
                                    onRefreshPreview()
                                }
                            }
                        }
                        valueSlider(
                            "字号",
                            value: Binding(
                                get: { model.plan.captions?.fontScale ?? 1 },
                                set: { model.setCaptionFontScale($0) }
                            ),
                            range: 0.75...1.5,
                            onEditingEnded: onRefreshPreview
                        )
                        Text("时码基于原始录屏；剪切、变速、重排后会自动映射到成片。")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)

                        DisclosureGroup(isExpanded: $isCaptionCueEditorExpanded) {
                            LazyVStack(spacing: 8) {
                                ForEach(
                                    Array(model.captionSourceCues.enumerated()),
                                    id: \.offset
                                ) { index, cue in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 5) {
                                            Button {
                                                model.selectCaptionCue(at: index)
                                                if let time = model.primaryCaptionOutputTime(at: index) {
                                                    playback.seek(to: time)
                                                }
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "play.fill")
                                                        .font(.system(size: 6, weight: .bold))
                                                    Text(String(
                                                        format: "%@ – %@",
                                                        captionTimeText(cue.sourceStartSeconds),
                                                        captionTimeText(cue.sourceEndSeconds)
                                                    ))
                                                    .font(.system(
                                                        size: 8,
                                                        weight: .semibold,
                                                        design: .monospaced
                                                    ))
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(
                                                model.selectedCaptionCueIndex == index
                                                    ? Color.cyan
                                                    : Color.secondary
                                            )
                                            .accessibilityLabel("播放第 \(index + 1) 条字幕")
                                            .accessibilityValue(String(
                                                format: "%@ 到 %@",
                                                captionTimeText(cue.sourceStartSeconds),
                                                captionTimeText(cue.sourceEndSeconds)
                                            ))
                                            Spacer(minLength: 2)
                                            Text("入")
                                                .font(.system(size: 7.5, weight: .medium))
                                                .foregroundStyle(.tertiary)
                                            TextField("", value: Binding(
                                                get: {
                                                    let cues = model.captionSourceCues
                                                    return cues.indices.contains(index)
                                                        ? cues[index].sourceStartSeconds
                                                        : 0
                                                },
                                                set: { model.setCaptionCueStart($0, at: index) }
                                            ), format: .number.precision(.fractionLength(2)))
                                            .multilineTextAlignment(.trailing)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 45)
                                            .onSubmit(onRefreshPreview)
                                            Text("出")
                                                .font(.system(size: 7.5, weight: .medium))
                                                .foregroundStyle(.tertiary)
                                            TextField("", value: Binding(
                                                get: {
                                                    let cues = model.captionSourceCues
                                                    return cues.indices.contains(index)
                                                        ? cues[index].sourceEndSeconds
                                                        : 0
                                                },
                                                set: { model.setCaptionCueEnd($0, at: index) }
                                            ), format: .number.precision(.fractionLength(2)))
                                            .multilineTextAlignment(.trailing)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 45)
                                            .onSubmit(onRefreshPreview)
                                        }
                                        TextField("留空可隐藏这条字幕", text: Binding(
                                            get: {
                                                let cues = model.captionSourceCues
                                                return cues.indices.contains(index)
                                                    ? cues[index].text
                                                    : ""
                                            },
                                            set: { model.setCaptionCueText($0, at: index) }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit(onRefreshPreview)
                                        HStack(spacing: 10) {
                                            Button("在播放头分割") {
                                                model.selectCaptionCue(at: index)
                                                model.splitCaptionCue(
                                                    at: index,
                                                    atOutputTime: playback.currentTimeSeconds
                                                )
                                                onRefreshPreview()
                                            }
                                            .disabled(!model.canSplitCaptionCue(
                                                at: index,
                                                atOutputTime: playback.currentTimeSeconds
                                            ))
                                            Button("与下一条合并") {
                                                model.selectCaptionCue(at: index)
                                                model.mergeCaptionCueWithNext(at: index)
                                                onRefreshPreview()
                                            }
                                            .disabled(index + 1 >= model.captionSourceCues.count)
                                            Spacer()
                                            Button(role: .destructive) {
                                                model.deleteCaptionCue(at: index)
                                                onRefreshPreview()
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .help("删除这条自定义字幕；原始转写仍会保留")
                                            .accessibilityLabel("删除第 \(index + 1) 条字幕")
                                            .accessibilityHint("原始转写仍会保留")
                                        }
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(7)
                                    .background(
                                        model.selectedCaptionCueIndex == index
                                            ? Color.cyan.opacity(0.08)
                                            : Color.primary.opacity(0.035),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(
                                                model.selectedCaptionCueIndex == index
                                                    ? Color.cyan.opacity(0.35)
                                                    : Color.primary.opacity(0.045),
                                                lineWidth: 0.7
                                            )
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selectCaptionCue(at: index) }
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("校对文字 · \(model.captionSourceCues.count) 条")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        if model.plan.captions?.customCues != nil {
                            Button("恢复本机转写原文") {
                                model.restoreAutomaticCaptionText()
                                onRefreshPreview()
                            }
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Text("先回到 Lens 库点击「转写」，本机识别后即可编辑和烧录。")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                    .id(VideoEditorInspectorSection.captions)

                    inspectorSection("导出", symbol: "square.and.arrow.up") {
                    Picker("质量预设", selection: Binding(
                        get: { model.exportPreset },
                        set: { model.setExportPreset($0) }
                    )) {
                        Text("原画").tag(AutoEditPlan.Export.Preset.source)
                        Text("平衡").tag(AutoEditPlan.Export.Preset.balanced)
                        Text("轻量").tag(AutoEditPlan.Export.Preset.compact)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Text(exportPresetDescription)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Label(
                        "MP4 · H.264 · 适合即时分享",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.cyan)
                }
                    .id(VideoEditorInspectorSection.export)
                }

                Button("恢复到打开时的方案", action: model.resetToAutomaticPlan)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .scrollTargetLayout()
        }
        .scrollPosition(id: $inspectorScrollPosition, anchor: .top)
        .defaultScrollAnchor(initialInspectorSection == nil ? .top : .bottom)
        .frame(width: 292)
        .lensGlassSurface(role: .chrome, cornerRadius: 0)
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
            Divider().opacity(0.3)
            content()
                .font(.system(size: 10.5, weight: .medium))
        }
        .padding(12)
        .lensGlassSurface(role: .card, cornerRadius: 14)
    }

    private func annotationToolButton(
        _ tool: ScreenshotAnnotationKind
    ) -> some View {
        let selected = model.isVideoAnnotationEditing
            && !model.isVideoAnnotationSelectionMode
            && model.selectedVideoAnnotationTool == tool
        return Button {
            model.activateVideoAnnotationTool(tool)
        } label: {
            Label(tool.editorTitle, systemImage: tool.editorSymbol)
                .font(.system(size: 8.5, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .background(
                    selected ? Color.cyan.opacity(0.78) : Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .help(tool.editorTitle)
    }

    private var videoAnnotationColors: [(name: String, color: LensColor)] {
        [
            ("红色", .red),
            ("橙色", .orange),
            ("黄色", .yellow),
            ("蓝色", .blue),
            ("白色", .white)
        ]
    }

    private var clickPulseColors: [(name: String, hex: String)] {
        [
            ("青色", "#00D9FF"),
            ("珊瑚", "#FF684D"),
            ("紫色", "#A855F7"),
            ("黄色", "#FACC15"),
            ("白色", "#FFFFFF")
        ]
    }

    private var cursorAccentColors: [(name: String, hex: String)] {
        [
            ("冰蓝", "#5BD6FF"),
            ("珊瑚", "#FF684D"),
            ("紫色", "#A855F7"),
            ("青柠", "#A3E635"),
            ("白色", "#FFFFFF")
        ]
    }

    private var cursorAppearanceOptions: [(
        value: AutoEditPlan.Cursor.Appearance,
        title: String
    )] {
        [
            (.recorded, "跟随系统"),
            (.macOS, "macOS 箭头"),
            (.highContrast, "高对比"),
            (.minimalDot, "极简圆点")
        ]
    }

    private var cursorMotionEffectOptions: [(
        value: AutoEditPlan.Cursor.MotionEffect,
        title: String
    )] {
        [
            (.none, "无"),
            (.halo, "柔光"),
            (.trail, "平滑拖尾"),
            (.spotlight, "聚光")
        ]
    }

    private var clickEffectOptions: [(
        value: AutoEditPlan.Interaction.ClickEffect,
        title: String
    )] {
        [
            (.ripple, "双层波纹"),
            (.pulse, "触点脉冲"),
            (.spotlight, "聚光点击")
        ]
    }

    private var cursorAppearanceDescription: String {
        switch model.plan.cursor.appearance {
        case .recorded:
            model.plan.cursor.shapeKeyframes.isEmpty
                ? "这条旧录屏没有形态轨道，将安全回退为 macOS 箭头。"
                : "按录制时状态还原箭头、手形、文本和缩放光标。"
        case .macOS:
            "始终使用系统箭头，适合风格统一的产品演示。"
        case .highContrast:
            "白色高对比箭头，在深色和复杂画面上都清楚。"
        case .minimalDot:
            "用强调色圆点替代箭头，适合简洁的教程成片。"
        }
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil,
        suffix: String = "",
        onEditingEnded: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 62, alignment: .leading)
            if let step {
                Slider(
                    value: value,
                    in: range,
                    step: step,
                    onEditingChanged: { isEditing in
                        if !isEditing { onEditingEnded?() }
                    }
                )
                .accessibilityLabel(title)
                .accessibilityValue(String(
                    format: "%.2f%@",
                    value.wrappedValue,
                    suffix
                ))
            } else {
                Slider(
                    value: value,
                    in: range,
                    onEditingChanged: { isEditing in
                        if !isEditing { onEditingEnded?() }
                    }
                )
                .accessibilityLabel(title)
                .accessibilityValue(String(
                    format: "%.2f%@",
                    value.wrappedValue,
                    suffix
                ))
            }
            Text(String(format: "%.2f%@", value.wrappedValue, suffix))
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: suffix.isEmpty ? 32 : 40, alignment: .trailing)
        }
    }

    private var selectedCanvasPresetTitle: String {
        VideoEditorCanvasBackgroundPreset.all.first {
            $0.matches(model.plan.canvas)
        }?.title ?? "自定义"
    }

    private var cameraGenerationButtonTitle: String {
        if model.isRegeneratingCamera { return "正在分析点击与光标" }
        if model.isProcessing { return "镜头已更新 · 正在生成预览" }
        return "重新分析点击与光标"
    }

    private var automaticCameraPlanSummary: String {
        let automaticFrames = model.plan.camera.keyframes.filter {
            switch $0.reason {
            case .manualAnchor, .manualFocus, .manualHold, .manualReturn:
                false
            default:
                true
            }
        }
        let clickFocuses = automaticFrames.filter { $0.reason == .clickFocus }.count
        let pointerFrames = automaticFrames.filter { $0.reason == .pointerFollow }.count
        if clickFocuses == 0, pointerFrames == 0 {
            return "当前没有符合条件的点击或明确光标移动"
        }
        return "已生成 \(clickFocuses) 个点击聚焦 · \(pointerFrames) 个光标跟随点"
    }

    private func canvasPresetButton(
        _ preset: VideoEditorCanvasBackgroundPreset,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [
                            VideoEditorCanvasColor.color(
                                hex: preset.topHex,
                                fallback: .gray
                            ),
                            VideoEditorCanvasColor.color(
                                hex: preset.bottomHex,
                                fallback: .black
                            )
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(.white.opacity(0.34), lineWidth: 0.8))
                if selected {
                    Circle()
                        .stroke(.cyan, lineWidth: 2)
                        .frame(width: 29, height: 29)
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.48), in: Circle())
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help("\(preset.title)渐变")
        .accessibilityLabel("\(preset.title)背景预设")
        .accessibilityValue(selected ? "已选择" : "")
    }

    private func timelineButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(.borderless)
    }

    private func choiceButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    selected ? Color.cyan.opacity(0.76) : Color.primary.opacity(0.055),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func timeText(_ seconds: Double) -> String {
        let value = max(seconds.isFinite ? seconds : 0, 0)
        let total = Int(value.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func captionTimeText(_ seconds: Double) -> String {
        let value = max(seconds.isFinite ? seconds : 0, 0)
        let minutes = Int(value / 60)
        return String(format: "%d:%04.1f", minutes, value - Double(minutes * 60))
    }

    private var exportPresetDescription: String {
        switch model.exportPreset {
        case .source:
            "保留源帧率与最高画质，适合归档和二次剪辑。"
        case .balanced:
            "最高 30 fps，在清晰度、生成速度和文件体积之间取平衡。"
        case .compact:
            "最高 24 fps 并压缩体积，适合消息与网页快速发送。"
        }
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
        Text(timeText(clock.currentTimeSeconds))
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
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
            "\(timeText(clock.currentTimeSeconds)) / \(timeText(playback.durationSeconds))"
        )
    }

    private func timeText(_ seconds: Double) -> String {
        let value = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct VideoEditorTimelinePlayhead: NSViewRepresentable {
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

private final class VideoEditorTimelinePlayheadNSView: NSView {
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
        cursorOverlayView.frame = bounds
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
        if playerView.player !== player { playerView.player = player }
        self.camera = camera
        self.timeline = timeline
        cursorOverlayView.configure(cursor: cursor, interaction: interaction)
        lastFrame = .null
        updateCameraFrame()
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

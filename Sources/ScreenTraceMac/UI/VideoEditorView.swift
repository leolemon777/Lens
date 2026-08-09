import AVKit
import Combine
import ScreenTraceCore
import SwiftUI

struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var playback: VideoEditorPlaybackController
    let title: String
    let onSave: () -> Void
    let onClose: () -> Void

    @State private var presenterDragStart: PresenterCameraFrameState?
    @State private var presenterResizeStart: PresenterCameraFrameState?

    private let playbackTimer = Timer.publish(
        every: 0.1,
        on: .main,
        in: .common
    ).autoconnect()

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
        .onReceive(playbackTimer) { _ in playback.refreshTime() }
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
            Button(action: model.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .help("重做")
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
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
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
                VideoPlayer(player: playback.player)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(8)
            }
            GeometryReader { proxy in
                if model.hasCameraTrack,
                   model.presenterEnabled,
                   proxy.size.width > 20,
                   proxy.size.height > 20 {
                    presenterOverlay(in: proxy.size)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
        .aspectRatio(playback.videoAspectRatio, contentMode: .fit)
        .frame(maxHeight: 460)
    }

    private func presenterOverlay(in canvasSize: CGSize) -> some View {
        let inset: CGFloat = 8
        let contentSize = CGSize(
            width: max(canvasSize.width - inset * 2, 1),
            height: max(canvasSize.height - inset * 2, 1)
        )
        let aspectRatio = Double(contentSize.width / max(contentSize.height, 1))
        let state = model.presenterState(
            atOutputTime: playback.currentTimeSeconds,
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
                .fill(.ultraThinMaterial)
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
                    nearOutputTime: playback.currentTimeSeconds
                ) ? "diamond.fill" : "hand.draw")
                Text(model.hasPresenterKeyframe(nearOutputTime: playback.currentTimeSeconds)
                    ? "关键帧"
                    : "拖动定位")
            }
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
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
                Rectangle().fill(.ultraThinMaterial)
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
                    center: TracePoint(
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
            Text(timeText(playback.currentTimeSeconds))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { playback.currentTimeSeconds },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.durationSeconds, 0.01)
            )
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
                    }
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2)
                        .shadow(color: .black.opacity(0.45), radius: 2)
                        .offset(x: availableWidth * min(
                            max(playback.currentTimeSeconds / total, 0),
                            1
                        ))
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 58)

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
                    HStack {
                        Text("背景")
                        Spacer()
                        presetButton(colors: [.gray, .teal]) {
                            model.setCanvasPreset(topHex: "#D9D6CF", bottomHex: "#9EA9A7")
                        }
                        presetButton(colors: [.indigo, .purple]) {
                            model.setCanvasPreset(topHex: "#667EEA", bottomHex: "#764BA2")
                        }
                        presetButton(colors: [.orange, .pink]) {
                            model.setCanvasPreset(topHex: "#F6D365", bottomHex: "#FDA085")
                        }
                        presetButton(colors: [.black, .gray]) {
                            model.setCanvasPreset(topHex: "#232526", bottomHex: "#414345")
                        }
                    }
                }

                inspectorSection("运镜与交互", symbol: "camera.metering.center.weighted") {
                    Toggle("自动运镜", isOn: Binding(
                        get: { model.cameraMotionEnabled },
                        set: { model.setCameraMotionEnabled($0) }
                    ))
                    valueSlider(
                        "缩放强度",
                        value: Binding(
                            get: { model.plan.camera.zoomIntensity },
                            set: { model.setZoomIntensity($0) }
                        ),
                        range: 0...1
                    )
                    Toggle("重绘光标", isOn: Binding(
                        get: { model.cursorEnabled },
                        set: { model.setCursorEnabled($0) }
                    ))
                    valueSlider(
                        "光标大小",
                        value: Binding(
                            get: { model.plan.cursor.scale },
                            set: { model.setCursorScale($0) }
                        ),
                        range: 0.7...2.2
                    )
                    Toggle("点击反馈", isOn: Binding(
                        get: { model.clickPulseEnabled },
                        set: { model.setClickPulseEnabled($0) }
                    ))
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

                inspectorSection("声音", symbol: "waveform") {
                    Toggle("启用混音", isOn: Binding(
                        get: { model.audioEnabled },
                        set: { model.setAudioEnabled($0) }
                    ))
                    valueSlider(
                        "系统声音",
                        value: Binding(
                            get: { model.plan.audio?.systemVolume ?? 1 },
                            set: { model.setSystemVolume($0) }
                        ),
                        range: 0...1.5
                    )
                    if model.hasMicrophoneTrack {
                        valueSlider(
                            "麦克风",
                            value: Binding(
                                get: { model.plan.audio?.microphoneVolume ?? 1 },
                                set: { model.setMicrophoneVolume($0) }
                            ),
                            range: 0...1.5
                        )
                        Toggle("讲话时自动压低系统声", isOn: Binding(
                            get: { model.plan.audio?.ducksSystemUnderNarration != false },
                            set: { model.setDuckingEnabled($0) }
                        ))
                    }
                }

                inspectorSection("字幕", symbol: "captions.bubble") {
                    Toggle("烧录字幕", isOn: Binding(
                        get: { model.captionsEnabled },
                        set: { model.setCaptionsEnabled($0) }
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
                            }
                            choiceButton(
                                "简洁",
                                selected: model.plan.captions?.style == .clean
                            ) {
                                model.setCaptionStyle(.clean)
                            }
                            choiceButton(
                                "高对比",
                                selected: model.plan.captions?.style == .highContrast
                            ) {
                                model.setCaptionStyle(.highContrast)
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
                                }
                            }
                        }
                        valueSlider(
                            "字号",
                            value: Binding(
                                get: { model.plan.captions?.fontScale ?? 1 },
                                set: { model.setCaptionFontScale($0) }
                            ),
                            range: 0.75...1.5
                        )
                        Text("保存后会按当前剪辑时间线重新对齐并烧录。")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)

                        DisclosureGroup {
                            LazyVStack(spacing: 8) {
                                ForEach(
                                    Array(model.captionSourceCues.enumerated()),
                                    id: \.offset
                                ) { index, cue in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(String(
                                            format: "%@ – %@",
                                            captionTimeText(cue.sourceStartSeconds),
                                            captionTimeText(cue.sourceEndSeconds)
                                        ))
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
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
                                    }
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("校对文字 · \(model.captionSourceCues.count) 条")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        if model.plan.captions?.customCues != nil {
                            Button("恢复本机转写原文", action: model.restoreAutomaticCaptionText)
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Text("先回到屏迹库点击「转写」，本机识别后即可编辑和烧录。")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Button("恢复到打开时的方案", action: model.resetToAutomaticPlan)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .frame(width: 292)
        .background(.thinMaterial)
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
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 62, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private func presetButton(
        colors: [Color],
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(LinearGradient(
                    colors: colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
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

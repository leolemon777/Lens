import LensCore
import SwiftUI

struct VideoEditorTimelineView: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var playback: VideoEditorPlaybackController
    @State private var timelineZoom = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: LensSpacing.s) {
            HStack(spacing: LensSpacing.s) {
                Label("时间线", systemImage: "timeline.selection")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(model.activeSegments.count) 个片段")
                    .font(.system(size: LensType.micro, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Slider(value: $timelineZoom, in: 1...4, step: 0.25)
                    .frame(width: 92)
                    .accessibilityLabel("时间线缩放")
                    .accessibilityValue(String(format: "%.1f 倍", timelineZoom))
                Text(String(format: "%.1f×", timelineZoom))
                    .font(.system(size: LensType.micro, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
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
                let viewportWidth = max(proxy.size.width, 1)
                let availableWidth = viewportWidth * timelineZoom
                ScrollView(.horizontal, showsIndicators: timelineZoom > 1.01) {
                    ZStack(alignment: .leading) {
                        timelineWaveform(width: availableWidth)
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let progress = min(max(
                                            value.location.x / availableWidth,
                                            0
                                        ), 1)
                                        playback.seek(to: progress * total, coalescing: true)
                                    }
                                    .onEnded { _ in
                                        playback.settlePlayhead()
                                    }
                            )
                    ForEach(Array(model.activeSegments.enumerated()), id: \.element.id) { index, segment in
                        let layout = model.segmentLayouts[index]
                        let segmentWidth = max(
                            availableWidth * layout.outputDurationSeconds / total,
                            38
                        )
                        let segmentStart = availableWidth
                            * layout.outputStartSeconds / total
                        timelineSegmentCell(
                            index: index,
                            segment: segment,
                            segmentWidth: segmentWidth,
                            segmentStart: segmentStart
                        )
                        if model.selectedSegmentID == segment.id {
                            timelineTrimHandle(
                                x: segmentStart,
                                isStart: true,
                                total: total,
                                availableWidth: availableWidth
                            )
                            timelineTrimHandle(
                                x: segmentStart + segmentWidth - 6,
                                isStart: false,
                                total: total,
                                availableWidth: availableWidth
                            )
                        }
                    }
                    ForEach(model.resolvedTransitions, id: \.fromSegmentID) { transition in
                        let center = availableWidth
                            * (transition.outputStartSeconds
                                + transition.durationSeconds / 2) / total
                        Image(systemName: transition.kind == .crossDissolve
                            ? "circle.lefthalf.filled"
                            : "circle.bottomhalf.filled")
                            .font(.system(size: LensIcon.small, weight: .bold))
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
                                        ? Color.orange // lens-token-exempt: 标注带是内容色，不是 chrome
                                        : Color.orange.opacity(0.55) // lens-token-exempt: 未选中标注带，同上
                                )
                                .overlay(Capsule().stroke(.white.opacity(0.55), lineWidth: 0.6))
                        }
                        .buttonStyle(.plain)
                        .frame(width: width, height: 6)
                        .offset(x: start, y: 23)
                        .zIndex(5)
                        .help("视频标注 · \(VideoEditorFormatting.captionTimeText(band.range.startSeconds))")
                        .accessibilityLabel("视频标注")
                        .accessibilityValue("\(VideoEditorFormatting.captionTimeText(band.range.startSeconds)) 开始")
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
                                .font(.system(size: LensIcon.small, weight: .bold))
                                .foregroundStyle(LensGlassPalette.accent)
                                .shadow(color: .black.opacity(0.45), radius: 2)
                                .frame(width: 14, height: 58)
                        }
                        .buttonStyle(.plain)
                        .offset(x: markerCenter - 7)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onEnded { value in
                                    let next = min(max(
                                        (markerCenter + value.translation.width)
                                            / availableWidth,
                                        0
                                    ), 1) * total
                                    model.moveManualCameraFocus(
                                        fromOutputTime: focusTime,
                                        toOutputTime: next
                                    )
                                }
                        )
                        .help("手动缩放 · \(VideoEditorFormatting.captionTimeText(focusTime))")
                        .accessibilityLabel("手动缩放关键帧")
                        .accessibilityValue(VideoEditorFormatting.captionTimeText(focusTime))
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
                                .font(.system(size: LensIcon.small, weight: .bold))
                                .foregroundStyle(.yellow) // lens-token-exempt: 关键帧标记需与同一时间线的缩放 scope 图标区分，非通用强调色
                                .shadow(color: .black.opacity(0.45), radius: 2)
                                .frame(width: 14, height: 58)
                        }
                        .buttonStyle(.plain)
                        .offset(x: markerCenter - 7)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onEnded { value in
                                    let next = min(max(
                                        (markerCenter + value.translation.width)
                                            / availableWidth,
                                        0
                                    ), 1) * total
                                    model.movePresenterKeyframe(
                                        fromOutputTime: keyframeTime,
                                        toOutputTime: next
                                    )
                                }
                        )
                        .help("讲解人像关键帧 · \(VideoEditorFormatting.captionTimeText(keyframeTime))")
                        .accessibilityLabel("讲解人像关键帧")
                        .accessibilityValue(VideoEditorFormatting.captionTimeText(keyframeTime))
                    }
                    VideoEditorTimelinePlayhead(
                        player: playback.player,
                        durationSeconds: total
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    }
                    .frame(width: availableWidth, height: 58)
                }
            }
            .frame(height: 58)
            .clipped()

            if let selected = model.selectedSegment {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("所选片段速度")
                            .font(.system(size: LensType.micro, weight: .semibold))
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
                        Text("源素材 \(VideoEditorFormatting.timeText(model.sourceDurationSeconds))")
                            .font(.system(size: LensType.micro, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("到下一片段")
                            .font(.system(size: LensType.micro, weight: .semibold))
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
                            .font(.system(size: LensType.micro, weight: .semibold, design: .monospaced))
                            .foregroundStyle(wasClamped ? LensGlassPalette.warning : LensGlassPalette.accent)
                        }
                        Spacer()
                        if !model.canTransitionFromSelectedSegment {
                            Text("末尾片段无需转场")
                                .font(.system(size: LensType.micro, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(LensSpacing.m)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: LensGlassMetrics.cardCornerRadius))
    }

    @ViewBuilder
    private func timelineWaveform(width: CGFloat) -> some View {
        let peaks = playback.waveformPeaks
        if !peaks.isEmpty {
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(peaks.enumerated()), id: \.offset) { _, peak in
                    Capsule()
                        .fill(LensGlassPalette.accent.opacity(0.22))
                        .frame(
                            width: max(width / CGFloat(peaks.count) - 0.5, 0.6),
                            height: max(CGFloat(peak) * 46, 2)
                        )
                }
            }
            .frame(width: width, height: 58)
            .allowsHitTesting(false)
        }
    }

    private func timelineSegmentCell(
        index: Int,
        segment: VideoEditSegment,
        segmentWidth: CGFloat,
        segmentStart: CGFloat
    ) -> some View {
        let selected = model.selectedSegmentID == segment.id
        let colors: [Color] = index.isMultiple(of: 2)
            ? [LensGlassPalette.accent.opacity(0.82), LensGlassPalette.accentDeep.opacity(0.76)]
            : [LensGlassPalette.accentDeep.opacity(0.82), LensGlassPalette.accent.opacity(0.60)]
        return Button {
            model.selectSegment(segment.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("片段 \(index + 1)")
                    .font(.system(size: LensType.micro, weight: .bold))
                Text(String(
                    format: "%.1f–%.1f s · %.2gx",
                    segment.sourceStartSeconds,
                    segment.sourceEndSeconds,
                    segment.playbackRate
                ))
                .font(.system(size: LensType.micro, weight: .medium, design: .rounded))
                .opacity(0.74)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: LensGlassMetrics.badgeCornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LensGlassMetrics.badgeCornerRadius)
                    .stroke(
                        selected ? .white.opacity(0.95) : .white.opacity(0.18),
                        lineWidth: selected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(width: segmentWidth, height: 58)
        .offset(x: segmentStart)
        .zIndex(selected ? 2 : Double(index % 2))
        .accessibilityLabel("片段 \(index + 1)")
        .accessibilityValue(String(
            format: "源时间 %.1f 到 %.1f 秒，%.2g 倍速",
            segment.sourceStartSeconds,
            segment.sourceEndSeconds,
            segment.playbackRate
        ))
    }

    private func timelineTrimHandle(
        x: CGFloat,
        isStart: Bool,
        total: Double,
        availableWidth: CGFloat
    ) -> some View {
        RoundedRectangle(cornerRadius: 1.5) // lens-token-exempt: trim handle geometry, not chrome
            .fill(.white)
            .frame(width: 6, height: 28)
            .shadow(color: .black.opacity(0.35), radius: 1)
            .offset(x: x, y: 15)
            .zIndex(8)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let progress = min(max(
                            (x + 3 + value.translation.width) / availableWidth,
                            0
                        ), 1)
                        playback.seek(to: progress * total, coalescing: true)
                    }
                    .onEnded { value in
                        let progress = min(max(
                            (x + 3 + value.translation.width) / availableWidth,
                            0
                        ), 1)
                        let time = progress * total
                        if isStart {
                            model.trimSelectedStart(toOutputTime: time)
                        } else {
                            model.trimSelectedEnd(toOutputTime: time)
                        }
                        playback.settlePlayhead()
                    }
            )
            .accessibilityLabel(isStart ? "入点手柄" : "出点手柄")
            .accessibilityHint("拖动以修剪所选片段")
    }

    private func timelineButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: LensType.micro, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityHint(timelineButtonHint(for: title))
    }

    private func timelineButtonHint(for title: String) -> String {
        switch title {
        case "设为入点":
            "把当前播放头设为所选片段的开始"
        case "分割":
            "在当前播放头位置分割所选片段"
        case "设为出点":
            "把当前播放头设为所选片段的结束"
        case "移出成片":
            "从成片中移出所选片段，原始录制仍保留"
        default:
            "编辑当前时间线"
        }
    }

}

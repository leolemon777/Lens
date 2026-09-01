import Foundation
import SwiftUI

enum RecordingStorageLevel: Equatable {
    case unknown
    case healthy
    case warning
    case critical
}

@MainActor
final class RecordingControlModel: ObservableObject {
    @Published var isPaused = false
    @Published var startedAt = Date()
    @Published var pausedAt: Date?
    @Published var accumulatedPause: TimeInterval = 0
    @Published var sourceTitle = "屏幕录制"
    @Published var capturesSystemAudio = true
    @Published var capturesMicrophone = false
    @Published var capturesCamera = false
    @Published var isTransitioning = false
    private(set) var systemAudioLevel: Double = 0
    private(set) var microphoneAudioLevel: Double = 0
    private(set) var eventCaptureHealth: EventCaptureHealth = .checking
    private(set) var capturePerformance: CapturePerformanceSnapshot?
    @Published private(set) var availableStorageBytes: Int64?
    @Published private(set) var storageLevel: RecordingStorageLevel = .unknown

    static let warningStorageBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    static let criticalStorageBytes: Int64 = 1 * 1_024 * 1_024 * 1_024

    func reset(
        sourceTitle: String = "屏幕录制",
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = false,
        capturesCamera: Bool = false
    ) {
        isPaused = false
        startedAt = Date()
        pausedAt = nil
        accumulatedPause = 0
        self.sourceTitle = sourceTitle
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.capturesCamera = capturesCamera
        isTransitioning = false
        systemAudioLevel = 0
        microphoneAudioLevel = 0
        eventCaptureHealth = .checking
        capturePerformance = nil
        availableStorageBytes = nil
        storageLevel = .unknown
    }

    func updateAudioLevels(system: Double, microphone: Double) {
        updateLiveStatus(
            system: system,
            microphone: microphone,
            eventHealth: eventCaptureHealth,
            performance: capturePerformance
        )
    }

    func updateEventCaptureHealth(_ health: EventCaptureHealth) {
        updateLiveStatus(
            system: systemAudioLevel,
            microphone: microphoneAudioLevel,
            eventHealth: health,
            performance: capturePerformance
        )
    }

    func updateCapturePerformance(_ snapshot: CapturePerformanceSnapshot?) {
        updateLiveStatus(
            system: systemAudioLevel,
            microphone: microphoneAudioLevel,
            eventHealth: eventCaptureHealth,
            performance: snapshot
        )
    }

    func updateLiveStatus(
        system: Double,
        microphone: Double,
        eventHealth: EventCaptureHealth,
        performance: CapturePerformanceSnapshot?
    ) {
        let system = min(max(system.isFinite ? system : 0, 0), 1)
        let microphone = min(max(microphone.isFinite ? microphone : 0, 0), 1)
        guard systemAudioLevel != system
                || microphoneAudioLevel != microphone
                || eventCaptureHealth != eventHealth
                || capturePerformance != performance else { return }
        objectWillChange.send()
        systemAudioLevel = system
        microphoneAudioLevel = microphone
        eventCaptureHealth = eventHealth
        capturePerformance = performance
    }

    @discardableResult
    func updateAvailableStorageBytes(_ bytes: Int64?) -> RecordingStorageLevel {
        let normalized = bytes.map { max($0, 0) }
        availableStorageBytes = normalized
        storageLevel = Self.storageLevel(for: normalized)
        return storageLevel
    }

    static func storageLevel(for availableBytes: Int64?) -> RecordingStorageLevel {
        guard let availableBytes else { return .unknown }
        if availableBytes <= criticalStorageBytes { return .critical }
        if availableBytes <= warningStorageBytes { return .warning }
        return .healthy
    }

    var storageLabel: String {
        guard let availableStorageBytes else { return "磁盘 --" }
        return "磁盘 \(Self.byteFormatter.string(fromByteCount: availableStorageBytes))"
    }

    var storageHelp: String {
        switch storageLevel {
        case .unknown:
            "暂时无法读取项目磁盘的可用空间"
        case .healthy:
            "项目磁盘可用空间充足"
        case .warning:
            "项目磁盘可用空间不足 5 GB，请尽快结束录制"
        case .critical:
            "项目磁盘可用空间不足 1 GB，Lens 将安全停止录制"
        }
    }

    var pauseActionTitle: String {
        isPaused ? "继续录制" : "暂停录制"
    }

    var recordingStateTitle: String {
        isPaused ? "已暂停" : "正在录制"
    }

    var systemAudioAccessibilityValue: String {
        capturesSystemAudio
            ? "录制中，电平 \(Self.audioLevelPercentage(systemAudioLevel))"
            : "已关闭"
    }

    var microphoneAccessibilityValue: String {
        "单独分轨录制中，电平 \(Self.audioLevelPercentage(microphoneAudioLevel))"
    }

    var storageAccessibilityValue: String {
        "\(storageLabel)，\(storageHelp)"
    }

    var eventCaptureHelp: String {
        switch eventCaptureHealth {
        case .checking:
            "正在检查智能光标与点击事件"
        case .waitingForActivity:
            "等待光标活动，原始录屏正常进行"
        case let .healthy(pointerCount, clickCount):
            "智能跟踪正常：\(pointerCount) 个光标点，\(clickCount) 个点击事件"
        case let .degraded(failure):
            failure.userFacingDescription
        }
    }

    var frameRateLabel: String {
        guard let capturePerformance else { return "FPS --" }
        if let measured = capturePerformance.measuredWrittenFramesPerSecond
            ?? capturePerformance.measuredReceivedFramesPerSecond {
            return String(format: "%.0f FPS", measured)
        }
        return "\(capturePerformance.requestedFramesPerSecond) FPS"
    }

    var frameRateHelp: String {
        guard let capturePerformance else { return "正在等待屏幕帧" }
        guard let received = capturePerformance.measuredReceivedFramesPerSecond else {
            return "目标 \(capturePerformance.requestedFramesPerSecond) FPS，正在取样"
        }
        if let written = capturePerformance.measuredWrittenFramesPerSecond {
            return String(
                format: "目标 %d FPS，写入 %.1f FPS，采集 %.1f FPS，共 %d 帧，丢帧 %d",
                capturePerformance.requestedFramesPerSecond,
                written,
                received,
                capturePerformance.writtenFrameCount,
                capturePerformance.droppedFrameCount
            )
        }
        return String(
            format: "目标 %d FPS，采集 %.1f FPS，已写入 %d 帧，丢帧 %d",
            capturePerformance.requestedFramesPerSecond,
            received,
            capturePerformance.writtenFrameCount,
            capturePerformance.droppedFrameCount
        )
    }

    func elapsedAccessibilityValue(at date: Date) -> String {
        Self.formatDuration(elapsed(at: date))
    }

    private static func audioLevelPercentage(_ level: Double) -> String {
        "\(Int((min(max(level, 0), 1) * 100).rounded()))%"
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    func setPaused(_ paused: Bool, at date: Date = Date()) {
        guard paused != isPaused else { return }
        if !paused {
            if let pausedAt {
                accumulatedPause += date.timeIntervalSince(pausedAt)
            }
            pausedAt = nil
            isPaused = false
        } else {
            pausedAt = date
            isPaused = true
        }
    }

    func elapsed(at date: Date) -> TimeInterval {
        let effectiveNow = pausedAt ?? date
        return max(0, effectiveNow.timeIntervalSince(startedAt) - accumulatedPause)
    }
}

struct RecordingControlView: View {
    @ObservedObject var model: RecordingControlModel
    let onHide: () -> Void
    let onPauseToggle: () -> Void
    let onDiscardAndRestart: () -> Void
    let onStop: () -> Void
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isPaused ? .orange : .red)
                .frame(width: 10, height: 10)
                .shadow(color: (model.isPaused ? Color.orange : .red).opacity(0.6), radius: 6)
                .accessibilityHidden(true)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.elapsedAccessibilityValue(at: context.date))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(width: 64, alignment: .leading)
                    .accessibilityLabel(model.recordingStateTitle)
                    .accessibilityValue(
                        "时长 \(model.elapsedAccessibilityValue(at: context.date))"
                    )
            }

            Divider().frame(height: 20)

            Text(model.sourceTitle)
                .font(.system(size: LensType.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 58, maxWidth: 92, alignment: .leading)
                .accessibilityLabel("录制来源")
                .accessibilityValue(model.sourceTitle)

            compactStatusIndicators

            Button {
                showsDetails.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: LensIcon.small, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(showsDetails ? 0.12 : 0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("查看声音、帧率、磁盘和重录选项")
            .accessibilityLabel("录制详情")
            .accessibilityValue(showsDetails ? "已展开" : "已收起")
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                recordingDetails
            }

            Button(action: onHide) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("隐藏浮标；录制仍会继续")
            .accessibilityLabel("隐藏录屏浮标")
            .accessibilityHint("录制继续；按 Fn 加空格或从菜单栏恢复")

            Button {
                onPauseToggle()
            } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isTransitioning)
            .opacity(model.isTransitioning ? 0.38 : 1)
            .help(model.isPaused ? "继续并写入新分片" : "暂停并安全完成当前分片")
            .accessibilityLabel(model.pauseActionTitle)
            .accessibilityHint(model.isPaused ? "继续并写入新分片" : "暂停并安全完成当前分片")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: LensIcon.small, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.red, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isTransitioning)
            .opacity(model.isTransitioning ? 0.5 : 1)
            .help("停止")
            .accessibilityLabel("停止录制")
            .accessibilityHint("安全完成当前分片并生成预览")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .lensGlassSurface(role: .panel, cornerRadius: LensGlassMetrics.panelCornerRadius)
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
    }

    private var compactStatusIndicators: some View {
        HStack(spacing: 2) {
            Image(systemName: model.capturesSystemAudio
                ? "speaker.wave.2.fill"
                : "speaker.slash.fill")
                .foregroundStyle(model.capturesSystemAudio ? .green : .secondary)
                .opacity(model.capturesSystemAudio ? 1 : 0.45)
                .help(model.capturesSystemAudio ? "正在录制系统声音" : "系统声音已关闭")
                .accessibilityLabel("系统声音")
                .accessibilityValue(model.systemAudioAccessibilityValue)

            if model.capturesMicrophone {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.green)
                    .help("麦克风正在单独分轨录制")
                    .accessibilityLabel("麦克风")
                    .accessibilityValue(model.microphoneAccessibilityValue)
            }

            if model.capturesCamera {
                Image(systemName: "video.fill")
                    .foregroundStyle(.green)
                    .help("摄像头正在单独分轨录制")
                    .accessibilityLabel("摄像头")
                    .accessibilityValue("单独分轨录制中")
            }

            Image(systemName: eventCaptureSymbol)
                .foregroundStyle(eventCaptureColor)
                .help(model.eventCaptureHelp)
                .accessibilityLabel("光标与点击跟踪")
                .accessibilityValue(model.eventCaptureHelp)
        }
        // Sizes the Image(systemName:) status glyphs above, not text.
        .font(.system(size: LensIcon.small, weight: .semibold))
        .frame(height: 24)
    }

    private var recordingDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("录制详情")
                .font(.headline)

            Divider()

            HStack(spacing: 10) {
                Label("录制来源", systemImage: "rectangle.dashed.badge.record")
                Spacer(minLength: 18)
                Text(model.sourceTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Label("系统声音", systemImage: "speaker.wave.2.fill")
                Spacer(minLength: 18)
                AudioLevelBars(level: model.capturesSystemAudio ? model.systemAudioLevel : 0)
                Text(model.capturesSystemAudio ? "录制中" : "已关闭")
                    .foregroundStyle(model.capturesSystemAudio ? .green : .secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("系统声音")
            .accessibilityValue(model.systemAudioAccessibilityValue)

            if model.capturesMicrophone {
                HStack(spacing: 10) {
                    Label("麦克风", systemImage: "mic.fill")
                    Spacer(minLength: 18)
                    AudioLevelBars(level: model.microphoneAudioLevel)
                    Text("分轨录制")
                        .foregroundStyle(.green)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("麦克风")
                .accessibilityValue(model.microphoneAccessibilityValue)
            }

            if model.capturesCamera {
                HStack(spacing: 10) {
                    Label("摄像头", systemImage: "video.fill")
                    Spacer(minLength: 18)
                    Text("分轨录制")
                        .foregroundStyle(.green)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("摄像头")
                .accessibilityValue("单独分轨录制中")
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Label("智能跟踪", systemImage: eventCaptureSymbol)
                    Spacer(minLength: 18)
                    Circle()
                        .fill(eventCaptureColor)
                        .frame(width: 7, height: 7)
                }
                Text(model.eventCaptureHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("光标与点击跟踪")
            .accessibilityValue(model.eventCaptureHelp)

            HStack(spacing: 10) {
                Label("录制帧率", systemImage: "speedometer")
                Spacer(minLength: 18)
                Text(model.frameRateLabel)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .foregroundStyle(frameRateColor)
            }
            .help(model.frameRateHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("实时录制帧率")
            .accessibilityValue(model.frameRateHelp)

            HStack(spacing: 10) {
                Label("可用空间", systemImage: storageSymbol)
                Spacer(minLength: 18)
                Text(model.storageLabel.replacingOccurrences(of: "磁盘 ", with: ""))
                    .foregroundStyle(storageColor)
            }
            .help(model.storageHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("项目磁盘可用空间")
            .accessibilityValue(model.storageAccessibilityValue)

            Divider()

            Button(role: .destructive) {
                showsDetails = false
                onDiscardAndRestart()
            } label: {
                Label("丢弃并重新录制", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(model.isTransitioning)
            .opacity(model.isTransitioning ? 0.38 : 1)
            .accessibilityHint("停止当前录制，移到废纸篓后按相同来源重新开始")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(16)
        .frame(width: 310)
    }

    private var storageColor: Color {
        switch model.storageLevel {
        case .unknown: .secondary
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    private var storageSymbol: String {
        switch model.storageLevel {
        case .unknown, .healthy: "internaldrive.fill"
        case .warning: "internaldrive.fill.trianglebadge.exclamationmark"
        case .critical: "externaldrive.fill.badge.exclamationmark"
        }
    }

    private var eventCaptureColor: Color {
        switch model.eventCaptureHealth {
        case .checking, .waitingForActivity: .secondary
        case .healthy: .green
        case .degraded: .orange
        }
    }

    private var eventCaptureSymbol: String {
        switch model.eventCaptureHealth {
        case .checking: "ellipsis.circle.fill"
        case .waitingForActivity: "cursorarrow.motionlines"
        case .healthy: "cursorarrow.rays"
        case .degraded: "cursorarrow.slash"
        }
    }

    private var frameRateColor: Color {
        guard let performance = model.capturePerformance,
              performance.writtenFrameCount >= 15,
              let meetingTarget = performance.isMeetingRequestedFrameRate else {
            return .secondary
        }
        return meetingTarget ? .green : .orange
    }
}

private struct AudioLevelBars: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lensReduceMotionOverride) private var reduceMotionOverride

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                let threshold = Double(index + 1) / 3
                RoundedRectangle(cornerRadius: 1.2, style: .continuous) // lens-token-exempt: 音量条端点的极细装饰性圆角，非 UI 表面，套用 token 会变成胶囊形
                    .frame(width: 2.5, height: CGFloat(4 + index * 3))
                    .opacity(level >= threshold ? 0.95 : 0.2)
            }
        }
        .frame(height: 10, alignment: .bottom)
        .animation(
            LensMotionPolicy.meterAnimation(
                reduceMotion: reduceMotionOverride ?? reduceMotion
            ),
            value: level
        )
    }
}

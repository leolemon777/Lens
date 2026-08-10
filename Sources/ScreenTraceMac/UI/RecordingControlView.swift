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
    @Published var systemAudioLevel: Double = 0
    @Published var microphoneAudioLevel: Double = 0
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
        availableStorageBytes = nil
        storageLevel = .unknown
    }

    func updateAudioLevels(system: Double, microphone: Double) {
        systemAudioLevel = min(max(system, 0), 1)
        microphoneAudioLevel = min(max(microphone, 0), 1)
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
            "项目磁盘可用空间不足 1 GB，屏迹将安全停止录制"
        }
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
    let onPauseToggle: () -> Void
    let onDiscardAndRestart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.isPaused ? .orange : .red)
                .frame(width: 10, height: 10)
                .shadow(color: (model.isPaused ? Color.orange : .red).opacity(0.6), radius: 6)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.format(model.elapsed(at: context.date)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(width: 64, alignment: .leading)
            }

            Divider().frame(height: 20)

            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                AudioLevelBars(level: model.capturesSystemAudio ? model.systemAudioLevel : 0)
            }
            .foregroundStyle(model.capturesSystemAudio ? .green : .secondary)
            .opacity(model.capturesSystemAudio ? 1 : 0.35)
            .frame(width: 44)
            .help(model.capturesSystemAudio ? "正在录制系统声音" : "系统声音已关闭")

            if model.capturesMicrophone {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                    AudioLevelBars(level: model.microphoneAudioLevel)
                }
                    .foregroundStyle(.green)
                    .frame(width: 38)
                    .help("麦克风正在单独分轨录制")
            }

            if model.capturesCamera {
                Image(systemName: "video.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 24)
                    .help("摄像头正在单独分轨录制")
            }

            HStack(spacing: 4) {
                Image(systemName: storageSymbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(model.storageLabel)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(storageColor)
            .frame(minWidth: 68)
            .help(model.storageHelp)

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

            Button(action: onDiscardAndRestart) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isTransitioning)
            .opacity(model.isTransitioning ? 0.38 : 1)
            .help("丢弃并重新录制")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.red, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isTransitioning)
            .opacity(model.isTransitioning ? 0.5 : 1)
            .help("停止")

            Text(model.sourceTitle)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .traceGlassPanel(cornerRadius: 24)
        .padding(28)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
}

private struct AudioLevelBars: View {
    let level: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                let threshold = Double(index + 1) / 3
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .frame(width: 2.5, height: CGFloat(4 + index * 3))
                    .opacity(level >= threshold ? 0.95 : 0.2)
            }
        }
        .frame(height: 10, alignment: .bottom)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

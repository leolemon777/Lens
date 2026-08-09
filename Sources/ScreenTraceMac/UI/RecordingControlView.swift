import SwiftUI

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
    }

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

            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.capturesSystemAudio ? .green : .secondary)
                .opacity(model.capturesSystemAudio ? 1 : 0.35)
                .frame(width: 30)
                .help(model.capturesSystemAudio ? "正在录制系统声音" : "系统声音已关闭")

            if model.capturesMicrophone {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 24)
                    .help("麦克风正在单独分轨录制")
            }

            if model.capturesCamera {
                Image(systemName: "video.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 24)
                    .help("摄像头正在单独分轨录制")
            }

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
}

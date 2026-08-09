import SwiftUI

@MainActor
final class RecordingControlModel: ObservableObject {
    @Published var isPaused = false
    @Published var startedAt = Date()
    @Published var pausedAt: Date?
    @Published var accumulatedPause: TimeInterval = 0
    @Published var sourceTitle = "屏幕录制"

    func reset(sourceTitle: String = "屏幕录制") {
        isPaused = false
        startedAt = Date()
        pausedAt = nil
        accumulatedPause = 0
        self.sourceTitle = sourceTitle
    }

    func togglePause() {
        if isPaused {
            if let pausedAt {
                accumulatedPause += Date().timeIntervalSince(pausedAt)
            }
            pausedAt = nil
            isPaused = false
        } else {
            pausedAt = Date()
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
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .shadow(color: .red.opacity(0.6), radius: 6)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.format(model.elapsed(at: context.date)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(width: 64, alignment: .leading)
            }

            Divider().frame(height: 20)

            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 30)
                .help("正在录制系统声音")

            Button {
                model.togglePause()
            } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.38)
            .help("暂停将在分轨写入器接入后开放")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.red, in: Circle())
            }
            .buttonStyle(.plain)
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

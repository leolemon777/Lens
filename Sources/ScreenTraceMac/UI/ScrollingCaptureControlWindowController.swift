import AppKit
import SwiftUI

@MainActor
final class ScrollingCaptureControlModel: ObservableObject {
    @Published private(set) var acceptedFrames = 0
    @Published private(set) var outputHeight = 0
    @Published private(set) var status = "正在捕获第一屏…"
    @Published var isFinalizing = false

    func reset() {
        acceptedFrames = 0
        outputHeight = 0
        status = "正在捕获第一屏…"
        isFinalizing = false
    }

    func update(
        disposition: ScrollingFrameAppendDisposition,
        acceptedFrames: Int,
        outputHeight: Int
    ) {
        self.acceptedFrames = acceptedFrames
        self.outputHeight = outputHeight
        switch disposition {
        case .first, .appended:
            status = "缓慢向下滚动，屏迹会自动去重并拼接"
        case .duplicate:
            status = "画面已对齐，继续向下滚动"
        case .rejected:
            status = "暂未找到稳定重叠，请慢一点滚动"
        case .limitReached:
            status = "已达到本次长截图的安全上限"
        }
    }

    func beginFinalizing() {
        isFinalizing = true
        status = "正在保留源帧并生成无缝图片…"
    }
}

struct ScrollingCaptureControlView: View {
    @ObservedObject var model: ScrollingCaptureControlModel
    let onCancel: () -> Void
    let onFinish: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.orange.opacity(0.16))
                    .frame(width: 38, height: 38)
                if model.isFinalizing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.and.down.text.horizontal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(model.isFinalizing ? "正在生成长截图" : "长截图捕获中")
                        .font(.system(size: 12.5, weight: .semibold))
                    if model.acceptedFrames > 0 {
                        Text("\(model.acceptedFrames) 帧 · \(model.outputHeight) px")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(model.status)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("取消", action: onCancel)
                .buttonStyle(.borderless)
                .disabled(model.isFinalizing)
            Button(action: onFinish) {
                Label("完成", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(model.acceptedFrames == 0 || model.isFinalizing)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .traceGlassPanel(cornerRadius: 23)
        .padding(26)
    }
}

@MainActor
final class ScrollingCaptureSessionController {
    private let model = ScrollingCaptureControlModel()
    private let panel: NSPanel
    private var assembler: VerticalScrollingCaptureAssembler?
    private var captureOperation: (() async throws -> CGImage)?
    private var captureTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var generation = 0

    var onCompleted: ((ScrollingCaptureAssembly, Error?) -> Void)?
    var onFailed: ((Error) -> Void)?
    var onCancelled: (() -> Void)?

    var isActive: Bool { assembler != nil }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 104),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    func begin(capture: @escaping () async throws -> CGImage) {
        cancel(notify: false)
        generation += 1
        let generation = generation
        assembler = VerticalScrollingCaptureAssembler()
        captureOperation = capture
        model.reset()
        positionPanel()
        panel.orderFrontRegardless()

        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await captureNextFrame(generation: generation)
                while !Task.isCancelled, self.generation == generation {
                    try await Task.sleep(for: .milliseconds(520))
                    try Task.checkCancellation()
                    try await captureNextFrame(generation: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation else { return }
                if self.assembler?.acceptedFrameCount ?? 0 > 0 {
                    finish(finalCapture: false, warning: error)
                } else {
                    fail(error, generation: generation)
                }
            }
        }
    }

    func finish() {
        finish(finalCapture: true, warning: nil)
    }

    func showExisting() {
        guard isActive else { return }
        positionPanel()
        panel.orderFrontRegardless()
    }

    func cancel() {
        cancel(notify: true)
    }

    private func captureNextFrame(generation: Int) async throws {
        guard self.generation == generation,
              let captureOperation,
              let assembler else {
            throw CancellationError()
        }
        let image = try await captureOperation()
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        let disposition = try assembler.append(image)
        model.update(
            disposition: disposition,
            acceptedFrames: assembler.acceptedFrameCount,
            outputHeight: assembler.outputHeight
        )
        if disposition == .limitReached {
            finish(finalCapture: false, warning: nil)
        }
    }

    private func finish(finalCapture: Bool, warning: Error?) {
        guard let assembler, !model.isFinalizing else { return }
        model.beginFinalizing()
        let generation = generation
        let activeCaptureTask = captureTask
        activeCaptureTask?.cancel()
        captureTask = nil
        let captureOperation = captureOperation

        finalizationTask = Task { @MainActor [weak self] in
            await activeCaptureTask?.value
            guard let self, self.generation == generation else { return }
            var completionWarning = warning
            if finalCapture, let captureOperation {
                do {
                    let finalImage = try await captureOperation()
                    let disposition = try assembler.append(finalImage)
                    model.update(
                        disposition: disposition,
                        acceptedFrames: assembler.acceptedFrameCount,
                        outputHeight: assembler.outputHeight
                    )
                    model.beginFinalizing()
                } catch {
                    completionWarning = completionWarning ?? error
                }
            }
            do {
                let result = try assembler.render()
                let completion = onCompleted
                clearSession(generation: generation)
                completion?(result, completionWarning)
            } catch {
                fail(error, generation: generation)
            }
        }
    }

    private func fail(_ error: Error, generation: Int) {
        guard self.generation == generation else { return }
        let failure = onFailed
        clearSession(generation: generation)
        failure?(error)
    }

    private func cancel(notify: Bool) {
        let wasActive = isActive
        let cancellation = onCancelled
        generation += 1
        captureTask?.cancel()
        finalizationTask?.cancel()
        captureTask = nil
        finalizationTask = nil
        assembler = nil
        captureOperation = nil
        panel.orderOut(nil)
        model.reset()
        if notify, wasActive { cancellation?() }
    }

    private func clearSession(generation: Int) {
        guard self.generation == generation else { return }
        self.generation += 1
        captureTask = nil
        finalizationTask = nil
        assembler = nil
        captureOperation = nil
        panel.orderOut(nil)
        model.reset()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: ScrollingCaptureControlView(
            model: model,
            onCancel: { [weak self] in self?.cancel() },
            onFinish: { [weak self] in self?.finish() }
        ))
    }

    private func positionPanel() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - panel.frame.width / 2,
            y: screen.visibleFrame.minY + 24
        ))
    }
}

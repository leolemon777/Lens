import AppKit
import Foundation
import LensCore

/// Main-actor presentation input for a completed render. Media execution and
/// publication have already finished before this boundary is called.
struct RecordingRenderPresentationInput: Sendable {
    let saved: SavedLens
    let updated: SavedLens
    let plan: AutoEditPlan
    let pipelineResult: RecordingRenderPipelineResult
    let cameraURL: URL?
    let microphoneURL: URL?
    let elapsedMilliseconds: Double
    let presenterWasRendered: Bool
}

/// Keeps render outcome copy and UI delivery out of AppDelegate's task
/// orchestration. All dependencies are injectable so the outcome can be
/// checked without starting an encoder or opening a window.
@MainActor
final class RecordingRenderPresentation {
    typealias ReloadLibrary = @MainActor @Sendable () -> Void
    typealias DeliveryImageProvider = @MainActor @Sendable (SavedLens) -> NSImage
    typealias QuickAccessUpdater = @MainActor @Sendable (
        SavedLens,
        NSImage?,
        String,
        QuickAccessDeliveryState
    ) -> Void
    typealias ToastPresenter = @MainActor @Sendable (
        String,
        String,
        String
    ) -> Void
    typealias DiagnosticRecorder = @MainActor @Sendable (
        String,
        DiagnosticLevel,
        [String: String]
    ) -> Void

    private let reloadLibrary: ReloadLibrary
    private let deliveryImage: DeliveryImageProvider
    private let updateQuickAccess: QuickAccessUpdater
    private let showToast: ToastPresenter
    private let recordDiagnostic: DiagnosticRecorder

    init(
        reloadLibrary: @escaping ReloadLibrary,
        deliveryImage: @escaping DeliveryImageProvider,
        updateQuickAccess: @escaping QuickAccessUpdater,
        showToast: @escaping ToastPresenter,
        recordDiagnostic: @escaping DiagnosticRecorder
    ) {
        self.reloadLibrary = reloadLibrary
        self.deliveryImage = deliveryImage
        self.updateQuickAccess = updateQuickAccess
        self.showToast = showToast
        self.recordDiagnostic = recordDiagnostic
    }

    @discardableResult
    func present(_ input: RecordingRenderPresentationInput) -> AutoEditPlan {
        let verification = input.pipelineResult.renderedEffectVerification
        let renderedSeconds = max(input.elapsedMilliseconds, 0) / 1_000
        let confirmation = verification.isVerified
            ? String(format: "成片已可发送 · %.1f 秒", renderedSeconds)
            : "成片已生成 · 建议复核"
        reloadLibrary()
        updateQuickAccess(
            input.updated,
            deliveryImage(input.updated),
            confirmation,
            verification.isVerified ? .ready : .needsReview
        )

        let presetTitle = RecordingExperiencePreset(rawValue: input.plan.preset)?.title
            ?? "自然成片"
        if !verification.isVerified {
            showToast(
                "\(presetTitle)预览需复核",
                reviewDetail(for: input),
                "exclamationmark.magnifyingglass"
            )
        }
        recordDiagnostic(
            "preview.completed",
            .info,
            [
                "durationMilliseconds": String(
                    format: "%.0f",
                    max(input.elapsedMilliseconds, 0)
                ),
                "renderEncodePassCount": String(
                    max(input.pipelineResult.renderEncodePassCount, 0)
                ),
                "renderMilliseconds": String(
                    format: "%.0f",
                    max(input.pipelineResult.renderElapsedMilliseconds, 0)
                ),
                "renderPeakPhysicalFootprintBytes": String(
                    input.pipelineResult.renderPeakPhysicalFootprintBytes
                )
            ]
        )
        return input.plan
    }

    func presentCancellation(for saved: SavedLens, isCurrent: Bool) {
        recordDiagnostic("preview.cancelled", .warning, [:])
        guard isCurrent else { return }
        updateQuickAccess(
            saved,
            deliveryImage(saved),
            "成片生成已取消 · 原片可用",
            .cancelled
        )
    }

    func presentFailure(
        for saved: SavedLens,
        isCurrent: Bool,
        metadata: [String: String]
    ) {
        recordDiagnostic("preview.failed", .error, metadata)
        guard isCurrent else { return }
        updateQuickAccess(
            saved,
            deliveryImage(saved),
            "原始录屏已保留 · 成片稍后重试",
            .failed
        )
        showToast(
            "原始录屏已保留",
            "自动成片暂未完成，稍后可以重新处理",
            "exclamationmark.arrow.triangle.2.circlepath"
        )
    }

    private func reviewDetail(
        for input: RecordingRenderPresentationInput
    ) -> String {
        let verification = input.pipelineResult.renderedEffectVerification
        var completedEffects = input.pipelineResult.healthReport.completedSmartEffects
        completedEffects = Array(NSOrderedSet(array: completedEffects))
            .compactMap { $0 as? String }
        let unverifiedEffects = verification.effects.compactMap {
            $0.state == .failed || $0.state == .inconclusive
                ? $0.effect.title
                : nil
        }
        var notes: [String] = []
        if !unverifiedEffects.isEmpty {
            notes.append("\(unverifiedEffects.joined(separator: "、"))未通过媒体验证")
        }
        if !verification.isFrameRateVerified {
            notes.append("成片帧率未达交付门槛")
        }
        if input.pipelineResult.microphoneWasMixed,
           input.pipelineResult.voiceProcessingFellBack {
            notes.append("旁白降噪失败，已保留原声混音")
        }

        let includesCamera = input.saved.manifest.assets.contains { $0.role == .camera }
        let includesMicrophone = input.saved.manifest.assets.contains {
            $0.role == .microphone
        }
        var preservedTracks: [String] = []
        if includesCamera {
            if input.cameraURL == nil {
                notes.append("摄像头原始轨缺失")
            } else if !input.presenterWasRendered {
                preservedTracks.append("摄像头")
            }
        }
        if includesMicrophone {
            if input.microphoneURL == nil {
                notes.append("麦克风原始轨缺失")
            } else if !input.pipelineResult.microphoneWasMixed {
                preservedTracks.append("麦克风")
            }
        }

        if !preservedTracks.isEmpty {
            let reason = input.pipelineResult.audioMixErrorDescription == nil
                ? "未叠加"
                : "混音未完成"
            let effects = completedEffects.isEmpty
                ? "基础预览已完成"
                : "\(completedEffects.joined(separator: "、"))已完成"
            let note = notes.isEmpty ? "" : "；\(notes.joined(separator: "、"))"
            return "\(effects)；\(preservedTracks.joined(separator: "、"))原始轨已保留（\(reason)）\(note)"
        }
        if completedEffects.isEmpty {
            if !notes.isEmpty {
                return "预览已生成；\(notes.joined(separator: "、"))，原始轨已保留"
            }
            return "基础预览已完成；本次未请求智能效果，原始轨已保留"
        }
        let note = notes.isEmpty ? "" : "；\(notes.joined(separator: "、"))"
        return "\(completedEffects.joined(separator: "、"))已完成，全部原始轨仍完整保留\(note)"
    }
}

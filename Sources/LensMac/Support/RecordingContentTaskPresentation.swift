import Foundation
import LensCore

/// User-facing outcomes for transcription and local organization. Keeping the
/// copy, safe metadata, and reload timing here leaves AppDelegate responsible
/// for task ownership and persistence rather than presentation details.
@MainActor
final class RecordingContentTaskPresentation {
    typealias ReloadLibrary = @MainActor @Sendable () -> Void
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
    typealias FailureRecorder = @MainActor @Sendable (
        String,
        [String: String]
    ) -> Void

    private let reloadLibrary: ReloadLibrary
    private let showToast: ToastPresenter
    private let recordDiagnostic: DiagnosticRecorder
    private let recordFailure: FailureRecorder

    init(
        reloadLibrary: @escaping ReloadLibrary,
        showToast: @escaping ToastPresenter,
        recordDiagnostic: @escaping DiagnosticRecorder,
        recordFailure: @escaping FailureRecorder
    ) {
        self.reloadLibrary = reloadLibrary
        self.showToast = showToast
        self.recordDiagnostic = recordDiagnostic
        self.recordFailure = recordFailure
    }

    func transcriptionCompleted(_ document: TranscriptDocument) {
        recordDiagnostic(
            "transcription.completed",
            .info,
            ["count": String(document.segments.count)]
        )
        reloadLibrary()
        let text = document.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        showToast(
            text.isEmpty ? "没有识别到讲解" : "本机转写已完成",
            text.isEmpty
                ? "录屏与原始音轨保持不变"
                : "\(document.segments.count) 个时间片段 · 已加入本地搜索",
            text.isEmpty ? "text.magnifyingglass" : "captions.bubble.fill"
        )
    }

    func transcriptionCancelled() {
        recordDiagnostic("transcription.cancelled", .warning, [:])
        showToast("转写已取消", "录屏与原始音轨保持不变", "xmark.circle")
    }

    func transcriptionFailed(
        _ metadata: [String: String],
        detail: String
    ) {
        recordFailure("transcription.failed", metadata)
        showToast(
            "原始录屏仍然安全",
            "本机转写未完成：\(detail)",
            "exclamationmark.arrow.triangle.2.circlepath"
        )
    }

    func organizationCompleted(
        _ insights: LensInsightsDocument,
        announcesResult: Bool
    ) {
        recordDiagnostic(
            "organization.completed",
            .info,
            ["count": String(insights.chapters.count)]
        )
        reloadLibrary()
        guard announcesResult else { return }
        var details: [String] = []
        if !insights.tags.isEmpty {
            details.append(insights.tags.prefix(3).joined(separator: "、"))
        }
        if !insights.chapters.isEmpty {
            details.append("\(insights.chapters.count) 个章节")
        }
        if !insights.sensitiveFindings.isEmpty {
            details.append("\(insights.sensitiveFindings.count) 项敏感信息提示")
        }
        showToast(
            "本地整理已完成",
            details.isEmpty ? "标题与内容索引已更新" : details.joined(separator: " · "),
            "sparkles.rectangle.stack.fill"
        )
    }

    func organizationAlreadyRunning() {
        showToast(
            "这条 Lens 正在整理",
            "完成后会自动更新标题、摘要、标签和章节",
            "sparkles"
        )
    }

    func organizationFailed(
        _ metadata: [String: String],
        detail: String,
        announcesResult: Bool
    ) {
        recordFailure("organization.failed", metadata)
        guard announcesResult else { return }
        showToast(
            "原始内容仍然安全",
            "本地整理未完成：\(detail)",
            "exclamationmark.arrow.triangle.2.circlepath"
        )
    }
}

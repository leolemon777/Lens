import AppKit
import LensCore
import SwiftUI

enum QuickAccessDeliveryState: Equatable {
    case ready
    case processing
    case failed
    case needsReview
    case interrupted

    @MainActor
    static func inferred(
        for lens: SavedLens,
        confirmationTitle: String
    ) -> Self {
        guard lens.manifest.kind == .recording else { return .ready }
        if confirmationTitle.contains("稍后重试") {
            return .failed
        }
        if confirmationTitle.contains("建议复核")
            || QuickAccessFileTransfer.previewNeedsReview(for: lens) {
            return .needsReview
        }
        switch lens.manifest.state {
        case .processing:
            return .processing
        case .interrupted:
            return .interrupted
        default:
            return .ready
        }
    }
}

/// Live progress for the recording currently shown in Quick Access. A plain
/// reference type (not part of `QuickAccessView`'s value-type state) so
/// `QuickAccessWindowController` can keep publishing updates into an
/// already-presented panel without re-triggering its entrance animation the
/// way constructing a whole new `QuickAccessView` would.
@MainActor
final class QuickAccessProgressModel: ObservableObject {
    @Published var fraction: Double?
    private(set) var startedAt = Date()

    func reset() {
        fraction = nil
        startedAt = Date()
    }
}

/// One capture held in the recent-captures stack. Only the thumbnail
/// (already the existing 118×72 preview size) is retained — never the
/// full-resolution original — so keeping the last several captures alive
/// stays cheap.
struct QuickAccessStackEntry: Identifiable, Equatable {
    var id: UUID { lens.manifest.id }
    let lens: SavedLens
    let thumbnail: NSImage
    let confirmationTitle: String
    let deliveryState: QuickAccessDeliveryState

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.confirmationTitle == rhs.confirmationTitle
            && lhs.deliveryState == rhs.deliveryState
            && lhs.thumbnail === rhs.thumbnail
    }
}

/// Backs the "recent captures" stack: most-recent-first, capped at
/// `capacity`. A plain `ObservableObject` (not `QuickAccessView`'s value
/// state) for the same reason `QuickAccessProgressModel` is — the
/// controller needs to keep publishing into an already-presented panel.
@MainActor
final class QuickAccessStackModel: ObservableObject {
    static let capacity = 5

    @Published private(set) var entries: [QuickAccessStackEntry] = []
    @Published var isExpanded = false

    /// Inserts a genuinely new capture at the front (trimming the oldest
    /// past `capacity`), or updates an existing entry in place without
    /// reordering when `entry.id` already matches one being tracked — a
    /// recording's processing state changing must not make it jump back to
    /// the front as if it had just been captured again.
    func upsert(_ entry: QuickAccessStackEntry) -> Bool {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            return false
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
        return true
    }

    /// Removes one entry (its own "close"); returns whether the stack is
    /// now empty, so the caller can hide the whole panel.
    @discardableResult
    func remove(id: UUID) -> Bool {
        entries.removeAll { $0.id == id }
        if entries.isEmpty {
            isExpanded = false
        }
        return entries.isEmpty
    }
}

struct QuickAccessView: View {
    let lens: SavedLens
    let image: NSImage
    let dragFileURL: URL?
    let dragSuggestedName: String?
    let confirmationTitle: String
    let deliveryState: QuickAccessDeliveryState
    @ObservedObject var progressModel: QuickAccessProgressModel
    @ObservedObject var stackModel: QuickAccessStackModel
    let onToggleExpansion: () -> Void
    let onCopyStackEntry: (UUID) -> Void
    let onRemoveStackEntry: (UUID) -> Void
    let onCopy: () -> Void
    let onAnnotate: () -> Void
    let onEdit: () -> Void
    let onReveal: () -> Void
    let onPin: () -> Void
    let onConversationInbox: () -> Void
    let onShare: () -> Void
    let onRetry: (() -> Void)?
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRecording: Bool { lens.manifest.kind == .recording }
    private var isProcessing: Bool {
        isRecording && deliveryState == .processing
    }
    private var isProcessingFailed: Bool {
        isRecording && deliveryState == .failed
    }
    private var isPreviewNeedsReview: Bool {
        isRecording && deliveryState == .needsReview
    }
    private var isInterrupted: Bool {
        isRecording && deliveryState == .interrupted
    }

    /// Additional captures beyond the one shown by the primary card.
    private var stackedEntries: [QuickAccessStackEntry] {
        Array(stackModel.entries.dropFirst())
    }

    /// Hero-card width. Deliberately narrower and taller than the old 508pt
    /// strip: the capture itself is the anchor now, and the title and actions
    /// stack beneath it instead of stretching beside a tiny thumbnail.
    private var cardWidth: CGFloat { 320 }
    private var heroWidth: CGFloat { cardWidth - 20 }

    /// Aspect-true hero height, clamped so extreme captures (tall scrolling
    /// shots, thin strips) neither balloon the panel nor vanish into a sliver.
    private var heroHeight: CGFloat {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return 168 }
        let aspectHeight = heroWidth * size.height / size.width
        return min(max(aspectHeight, 104), 192)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            primaryCard
            if stackModel.isExpanded, !stackedEntries.isEmpty {
                stackedEntriesList
            }
        }
        .padding(28)
    }

    private var primaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            draggablePreview
                .padding(.top, 10)
                .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 7) {
                statusTitleRow
                Text(detailText)
                    .font(.system(size: LensType.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isProcessing {
                    progressRow
                }
                actionBar
                    .padding(.top, 3)
            }
            .padding(12)
        }
        .frame(width: cardWidth)
        // Keeps control glows (the filled primary button's shadow) inside the
        // card outline instead of bleeding past its edge onto the desktop.
        .clipShape(RoundedRectangle(
            cornerRadius: LensGlassMetrics.panelCornerRadius,
            style: .continuous
        ))
        .lensGlassSurface(role: .panel, cornerRadius: LensGlassMetrics.panelCornerRadius)
    }

    private var statusTitleRow: some View {
        HStack(spacing: 7) {
            if isProcessing {
                ProgressView(value: progressModel.fraction ?? 0)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .accessibilityLabel("成片生成中")
                    .accessibilityValue(progressCaption)
            } else {
                Image(systemName: isProcessingFailed || isPreviewNeedsReview || isInterrupted
                      ? "exclamationmark.triangle.fill"
                      : "checkmark.circle.fill")
                    .font(.system(size: LensIcon.medium, weight: .semibold))
                    .foregroundStyle(
                        isProcessingFailed || isPreviewNeedsReview || isInterrupted
                            ? LensGlassPalette.warning
                            : LensGlassPalette.success
                    )
                    .accessibilityHidden(true)
            }
            Text(confirmationTitle)
                .font(.system(size: LensType.title, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ProgressView(value: progressModel.fraction ?? 0)
                .progressViewStyle(.linear)
            Text(progressCaption)
                .font(.system(size: LensType.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("成片生成进度")
        .accessibilityValue(progressCaption)
    }

    /// Lives on the hero image's top-right corner: a dark glass chip that
    /// stays legible over any capture content instead of a plain circle
    /// floating in the card's dead space.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: LensIcon.small, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.46), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.22), radius: 5, y: 1)
        .help("关闭")
        .accessibilityLabel("关闭快速操作")
        .keyboardShortcut(.cancelAction)
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 7) {
            if isRecording {
                // Primary: retry takes over the primary slot when the
                // render actually failed — that is the one action
                // the user needs most in that state.
                if isProcessingFailed, let onRetry {
                    primaryQuickButton("重试成片", symbol: "arrow.clockwise", action: onRetry)
                } else {
                    primaryQuickButton(
                        isProcessing ? "查看原片" : "编辑",
                        symbol: "timeline.selection",
                        action: onEdit
                    )
                }
                quickButton("复制文件", symbol: "doc.on.doc", action: onCopy)
                if dragFileURL != nil {
                    quickButton("分享", symbol: "square.and.arrow.up", action: onShare)
                        .help("打开 macOS 系统分享面板发送当前视频，不会自动上传")
                        .accessibilityHint("打开 macOS 系统分享面板发送当前视频，不会自动上传")
                }
                overflowMenu {
                    Button(action: onReveal) {
                        Label("显示", systemImage: "folder")
                    }
                }
            } else {
                primaryQuickButton("复制", symbol: "doc.on.doc", action: onCopy)
                quickButton("标注", symbol: "pencil.tip", action: onAnnotate)
                quickButton("贴图", symbol: "pin", action: onPin)
                overflowMenu {
                    if dragFileURL != nil {
                        Button(action: onShare) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .help("打开 macOS 系统分享面板发送当前 PNG，不会自动上传")
                        .accessibilityHint("打开 macOS 系统分享面板发送当前 PNG，不会自动上传")
                    }
                    Button(action: onReveal) {
                        Label("显示", systemImage: "folder")
                    }
                    Button(action: onConversationInbox) {
                        Label("对话", systemImage: "terminal")
                    }
                    .help("保存到对话文件夹并复制路径，方便在终端里发给 AI")
                    .accessibilityHint("保存到对话文件夹并复制路径")
                }
            }
        }
    }

    /// Compact rows for every capture beyond the primary card — thumbnail,
    /// independent drag/copy/close, no annotate/share/edit clutter. This is
    /// deliberately a lighter action set than the primary card's; "轻量堆栈"
    /// means the stack itself stays light, not that every entry replicates
    /// the full action row.
    private var stackedEntriesList: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(stackedEntries) { entry in
                stackedEntryRow(entry)
            }
        }
        .padding(8)
        .frame(width: cardWidth, alignment: .trailing)
        .lensGlassSurface(role: .panel, cornerRadius: LensGlassMetrics.panelCornerRadius)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder
    private func stackedEntryThumbnail(_ entry: QuickAccessStackEntry) -> some View {
        let thumbnail = Image(nsImage: entry.thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: 52, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
            .accessibilityHidden(true)
        if let fileURL = QuickAccessFileTransfer.bestFileURL(for: entry.lens) {
            thumbnail.onDrag {
                QuickAccessFileTransfer.itemProvider(
                    fileURL: fileURL,
                    suggestedName: QuickAccessFileTransfer.suggestedFileName(
                        for: entry.lens,
                        fileURL: fileURL
                    ),
                    fallbackImage: entry.thumbnail
                )
            }
            .help(entry.lens.manifest.kind == .recording ? "拖到聊天或 Finder 中发送视频" : "拖到 Finder、聊天或文档中发送 PNG")
        } else {
            thumbnail
        }
    }

    private func stackedEntryRow(_ entry: QuickAccessStackEntry) -> some View {
        let entryIsRecording = entry.lens.manifest.kind == .recording
        return HStack(spacing: 8) {
            stackedEntryThumbnail(entry)
            Text(entry.confirmationTitle)
                .font(.system(size: LensType.micro, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: { onCopyStackEntry(entry.id) }) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(entryIsRecording ? "复制文件" : "复制")
            .accessibilityLabel("复制：\(entry.confirmationTitle)")
            Button(action: { onRemoveStackEntry(entry.id) }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("从堆栈中移除")
            .accessibilityLabel("移除：\(entry.confirmationTitle)")
        }
        .accessibilityElement(children: .contain)
    }

    /// "38% · 约剩 12 秒", extrapolated from elapsed time and completed
    /// fraction. The first 10% is withheld per-recording setup and pass
    /// count vary enough that an early estimate would visibly jump once
    /// more data comes in.
    private var progressCaption: String {
        guard let fraction = progressModel.fraction else { return "0%" }
        let percent = Int((fraction * 100).rounded())
        guard fraction >= 0.1, fraction < 1 else { return "\(percent)%" }
        let elapsed = Date().timeIntervalSince(progressModel.startedAt)
        guard elapsed > 0.5 else { return "\(percent)%" }
        let remaining = max(elapsed / fraction - elapsed, 0)
        return "\(percent)% · 约剩 \(Int(remaining.rounded())) 秒"
    }

    private var detailText: String {
        if isRecording {
            let deliveryHint: String
            if isProcessing {
                deliveryHint = "原始文件可拖出 · 成片生成中"
            } else if isPreviewNeedsReview {
                deliveryHint = "原始文件可拖出 · 建议打开编辑器复核"
            } else if isProcessingFailed {
                deliveryHint = "原始文件可拖出 · 可重试成片"
            } else if isInterrupted {
                deliveryHint = "原始文件可拖出 · 录屏曾中断，建议检查恢复状态"
            } else {
                deliveryHint = "成片可拖进聊天"
            }
            if let seconds = lens.manifest.durationSeconds {
                return String(format: "%.0f 秒 · %@", seconds, deliveryHint)
            }
            return deliveryHint
        }
        if let dimensions = lens.manifest.dimensions {
            return "\(dimensions.width) × \(dimensions.height) · 可拖进聊天"
        }
        return "可拖进聊天"
    }

    @ViewBuilder
    private var draggablePreview: some View {
        let heroShape = RoundedRectangle(
            cornerRadius: LensGlassMetrics.cardCornerRadius,
            style: .continuous
        )
        let preview = Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: heroWidth, height: heroHeight)
            .clipShape(heroShape)
            .overlay(heroShape.stroke(.white.opacity(0.2), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if stackedEntries.count > 0 {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            onToggleExpansion()
                        }
                    } label: {
                        Text("+\(stackedEntries.count)")
                            .font(.system(size: LensType.micro, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(LensGlassPalette.midnight)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(LensGlassPalette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .shadow(color: .black.opacity(0.28), radius: 4, y: 1)
                    .padding(8)
                    .help(stackModel.isExpanded ? "收起最近捕获" : "展开最近捕获")
                    .accessibilityLabel(
                        stackModel.isExpanded
                            ? "收起，还有 \(stackedEntries.count) 项最近捕获"
                            : "展开 \(stackedEntries.count) 项最近捕获"
                    )
                }
            }
            .overlay(alignment: .topTrailing) {
                closeButton
                    .padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: LensIcon.small, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.58), in: Circle())
                    .accessibilityHidden(true)
            }
            .contentShape(heroShape)
            .accessibilityLabel(isRecording ? "刚刚保存的录屏预览" : "刚刚保存的截图预览")

        if let dragFileURL {
            preview
                .onDrag {
                    QuickAccessFileTransfer.itemProvider(
                        fileURL: dragFileURL,
                        suggestedName: dragSuggestedName,
                        fallbackImage: image
                    )
                } preview: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .help(isRecording ? "拖到聊天或 Finder 中发送视频" : "拖到 Finder、聊天或文档中发送 PNG")
                .accessibilityHint(isRecording
                    ? "按住并拖动预览可发送视频文件"
                    : "按住并拖动预览可发送 PNG 文件")
        } else {
            preview
        }
    }

    /// The one action most people take on any given card — copy, or edit for
    /// a recording, or retry when the render actually failed. Rendered as the
    /// card's single filled accent pill so it reads as the default choice
    /// without anyone needing to read all the labels first.
    private func primaryQuickButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: LensType.caption, weight: .semibold))
                .foregroundStyle(LensGlassPalette.midnight)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
        }
        .buttonStyle(LensGlassButtonStyle(
            tint: LensGlassPalette.accent,
            isFilled: true,
            cornerRadius: LensGlassMetrics.controlCornerRadius
        ))
    }

    private func quickButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: LensType.caption, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(LensGlassButtonStyle(tint: LensGlassPalette.neutral, cornerRadius: LensGlassMetrics.controlCornerRadius))
    }

    /// Everything that isn't the primary or the two secondary actions lives
    /// here, so the card never shows more than three buttons at once. Every
    /// item keeps its own `.help`/accessibility text — collapsing into a
    /// menu must not make an action harder to identify with VoiceOver.
    private func overflowMenu<Content: View>(@ViewBuilder items: () -> Content) -> some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: LensIcon.small, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(LensGlassButtonStyle(tint: LensGlassPalette.neutral, cornerRadius: LensGlassMetrics.controlCornerRadius))
        .fixedSize()
        .help("更多操作")
        .accessibilityLabel("更多操作")
    }
}

@MainActor
enum QuickAccessFileTransfer {
    static func bestFileURL(for entry: LensLibraryEntry) -> URL? {
        let lens = SavedLens(
            packageURL: entry.packageURL,
            rawAssetURL: entry.primaryAssetURL,
            manifest: entry.manifest
        )
        return bestFileURL(for: lens)
    }

    static func bestFileURL(for lens: SavedLens) -> URL? {
        let preferredRole: LensAsset.Role = lens.manifest.kind == .recording
            ? .renderedVideo
            : .renderedScreenshot
        // A stale rendered asset must never be presented as the current result
        // while a recording is being regenerated. The raw file is durable and
        // immediately shareable; the rendered file becomes preferred again
        // only after the manifest returns to ready.
        let preferredCandidates = lens.manifest.state == .ready
            && !previewNeedsReview(for: lens)
            ? lens.manifest.assets
                .filter { $0.role == preferredRole }
                .map { lens.packageURL.appendingPathComponent($0.relativePath) }
            : []
        let candidates = preferredCandidates + [lens.rawAssetURL]
        return candidates.first { candidate in
            isRegularFileInsidePackage(candidate, packageURL: lens.packageURL)
        }
    }

    static func previewNeedsReview(for lens: SavedLens) -> Bool {
        guard lens.manifest.kind == .recording else {
            return false
        }
        guard let healthAsset = lens.manifest.assets.first(where: {
            $0.role == .recordingHealth
        }) else {
            // Legacy recording packages may have a rendered file but no
            // verification report. That file cannot be authorized as the
            // current shareable result; Quick Access will fall back to raw.
            return true
        }
        let healthURL = lens.packageURL.appendingPathComponent(healthAsset.relativePath)
        guard isRegularFileInsidePackage(healthURL, packageURL: lens.packageURL),
              let data = try? Data(contentsOf: healthURL) else {
            return true
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let report = try decoder.decode(RecordingHealthReport.self, from: data)
            return report.renderedEffectVerification?.isVerified == false
        } catch {
            // A corrupt health report cannot authorize a polished preview. The
            // raw recording remains the only trustworthy delivery candidate.
            return true
        }
    }

    static func suggestedFileName(for lens: SavedLens, fileURL: URL) -> String {
        suggestedFileName(
            createdAt: lens.manifest.createdAt,
            identifier: lens.manifest.id,
            fileURL: fileURL
        )
    }

    static func suggestedFileName(for entry: LensLibraryEntry, fileURL: URL) -> String {
        suggestedFileName(
            createdAt: entry.manifest.createdAt,
            identifier: entry.manifest.id,
            fileURL: fileURL
        )
    }

    private static func suggestedFileName(
        createdAt: Date,
        identifier: UUID,
        fileURL: URL
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: createdAt)
        let identifier = String(identifier.uuidString.prefix(8))
        let fileExtension = fileURL.pathExtension.isEmpty ? "png" : fileURL.pathExtension.lowercased()
        return "Lens-\(timestamp)-\(identifier).\(fileExtension)"
    }

    static func itemProvider(
        fileURL: URL,
        suggestedName: String?,
        fallbackImage: NSImage
    ) -> NSItemProvider {
        if let provider = NSItemProvider(contentsOf: fileURL) {
            provider.suggestedName = suggestedName ?? fileURL.lastPathComponent
            return provider
        }
        return NSItemProvider(object: fallbackImage)
    }

    private static func isRegularFileInsidePackage(_ candidate: URL, packageURL: URL) -> Bool {
        let resolvedPackage = packageURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let packagePrefix = resolvedPackage.path.hasSuffix("/")
            ? resolvedPackage.path
            : resolvedPackage.path + "/"
        guard resolvedCandidate.path.hasPrefix(packagePrefix) else { return false }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: resolvedCandidate.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
    }
}

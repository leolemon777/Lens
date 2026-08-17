import AppKit
import ScreenTraceCore
import SwiftUI

struct TraceLibraryView: View {
    @ObservedObject var model: TraceLibraryModel
    let onOpen: (TraceLibraryEntry) -> Void
    let onReveal: (TraceLibraryEntry) -> Void
    let onCopy: (TraceLibraryEntry) -> Void
    let onAnnotate: (TraceLibraryEntry) -> Void
    let onTranscribe: (TraceLibraryEntry) -> Void
    let onOrganize: (TraceLibraryEntry) -> Void
    let onSaveInsights: (TraceLibraryEntry, TraceInsightsCustomization?) -> Void
    let onDelete: (TraceLibraryEntry) -> Void
    let onDeleteAll: () -> Void
    let onOpenFolder: () -> Void
    let onClose: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 270), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            filterBar
            Divider().opacity(0.35)
            content
        }
        .frame(minWidth: 860, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(.cyan.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("屏迹库")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(model.entries.count) 条本地记录 · 截图 \(model.screenshotCount) · 录屏 \(model.recordingCount)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索标题、标签、OCR 或转写", text: $model.query)
                    .textFieldStyle(.plain)
                    .frame(width: 220)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            Button(action: model.reload) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 27, height: 27)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("刷新")
            .accessibilityLabel("刷新屏迹库")
            Button(action: onOpenFolder) {
                Image(systemName: "folder")
                    .frame(width: 27, height: 27)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("在 Finder 中打开")
            .accessibilityLabel("在 Finder 中打开屏迹文件夹")
            Button(action: onDeleteAll) {
                Label("全部删除", systemImage: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 27)
                    .background(.red.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(model.entries.allSatisfy { !model.canDelete($0) })
            .help("把全部可删除项目移到废纸篓")
            .accessibilityLabel("全部删除屏迹记录")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 27, height: 27)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel("关闭屏迹库")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .traceGlassSurface(role: .chrome, cornerRadius: 0)
    }

    private var filterBar: some View {
        HStack {
            Picker("类型", selection: $model.filter) {
                Text("全部").tag(TraceLibraryFilter.all)
                Text("截图").tag(TraceLibraryFilter.screenshots)
                Text("录屏").tag(TraceLibraryFilter.recordings)
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("正在更新索引…")
                    .foregroundStyle(.secondary)
            } else if model.visibleEntries.count != model.entries.count {
                Text("找到 \(model.visibleEntries.count) 条")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .traceGlassSurface(role: .chrome, cornerRadius: 0)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.entries.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在读取本地屏迹…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleEntries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.visibleEntries) { entry in
                        TraceLibraryCard(
                            entry: entry,
                            onOpen: { onOpen(entry) },
                            onReveal: { onReveal(entry) },
                            onCopy: { onCopy(entry) },
                            onAnnotate: { onAnnotate(entry) },
                            onTranscribe: { onTranscribe(entry) },
                            onOrganize: { onOrganize(entry) },
                            onSaveInsights: { onSaveInsights(entry, $0) },
                            onDelete: { onDelete(entry) },
                            canDelete: model.canDelete(entry),
                            isTranscribing: model.isTranscribing(entry.id),
                            isOrganizing: model.isOrganizing(entry.id)
                        )
                    }
                }
                .padding(18)
            }
            .background(Color.black.opacity(0.035))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.entries.isEmpty ? "sparkles.rectangle.stack" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.entries.isEmpty ? "还没有屏迹" : "没有匹配的记录")
                .font(.system(size: 14, weight: .semibold))
            Text(model.entries.isEmpty ? "完成一次截图或录屏后，它会自动出现在这里。" : "尝试更换关键词或类型筛选。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TraceLibraryCard: View {
    let entry: TraceLibraryEntry
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopy: () -> Void
    let onAnnotate: () -> Void
    let onTranscribe: () -> Void
    let onOrganize: () -> Void
    let onSaveInsights: (TraceInsightsCustomization?) -> Void
    let onDelete: () -> Void
    let canDelete: Bool
    let isTranscribing: Bool
    let isOrganizing: Bool

    @State private var showsInsights = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(height: 132)
                .clipped()
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: entry.manifest.kind == .screenshot ? "photo" : "video.fill")
                        .foregroundStyle(entry.manifest.kind == .screenshot ? .cyan : .red)
                    Text(displayTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    stateBadge
                }
                HStack(spacing: 7) {
                    Text(entry.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if entry.ocrText?.isEmpty == false {
                        Label("OCR", systemImage: "text.viewfinder")
                    }
                    if entry.transcriptText?.isEmpty == false {
                        Label("转写", systemImage: "captions.bubble.fill")
                    }
                    if entry.insights != nil {
                        Label("已整理", systemImage: "sparkles")
                    }
                    if let count = entry.insights?.sensitiveFindings.count, count > 0 {
                        Label("\(count) 项敏感", systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                    if let capture = entry.manifest.captureSource {
                        Label(capture.mode.libraryTitle, systemImage: capture.mode.librarySymbol)
                    }
                    if let duration = entry.manifest.durationSeconds {
                        Text(durationText(duration))
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)

                if let summary = entry.insights?.resolvedSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let tags = entry.insights?.resolvedTags, !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(tags.prefix(3)), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.cyan.opacity(0.09), in: Capsule())
                        }
                    }
                }

                HStack(spacing: 7) {
                    cardButton(
                        entry.manifest.kind == .screenshot ? "打开" : "编辑",
                        symbol: entry.manifest.kind == .screenshot
                            ? "arrow.up.right.square"
                            : "timeline.selection",
                        action: onOpen
                    )
                    if entry.manifest.kind == .screenshot {
                        cardButton("复制", symbol: "doc.on.doc", action: onCopy)
                        cardButton("标注", symbol: "pencil.tip", action: onAnnotate)
                    } else {
                        Button(action: onTranscribe) {
                            HStack(spacing: 4) {
                                if isTranscribing {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "waveform.badge.magnifyingglass")
                                }
                                Text(entry.transcriptText?.isEmpty == false ? "重转写" : "转写")
                            }
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(.primary.opacity(0.055), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isTranscribing)
                    }
                    Spacer(minLength: 0)
                    organizationButton
                    Button(action: onReveal) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("在 Finder 中显示")
                    .accessibilityLabel("在 Finder 中显示：\(displayTitle)")
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(canDelete ? 0.90 : 0.35))
                    .disabled(!canDelete)
                    .help(canDelete ? "移到废纸篓" : "正在录制或处理，暂时不能删除")
                    .accessibilityLabel("删除：\(displayTitle)")
                }
            }
            .padding(11)
        }
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(count: 2, perform: onOpen)
        .popover(isPresented: $showsInsights, arrowEdge: .trailing) {
            if let insights = entry.insights {
                TraceInsightsPopover(
                    insights: insights,
                    isOrganizing: isOrganizing,
                    onRegenerate: onOrganize,
                    onSaveCustomization: onSaveInsights
                )
            }
        }
    }

    private var displayTitle: String {
        let suggested = entry.insights?.resolvedTitle
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return suggested.isEmpty ? entry.manifest.title : suggested
    }

    private var organizationButton: some View {
        Button {
            if entry.insights == nil {
                onOrganize()
            } else {
                showsInsights.toggle()
            }
        } label: {
            if isOrganizing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: entry.insights == nil ? "sparkles" : "sparkles.rectangle.stack.fill")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(entry.insights == nil ? Color.secondary : Color.cyan)
        .disabled(isOrganizing)
        .help(entry.insights == nil ? "本地智能整理" : "查看整理结果")
        .accessibilityLabel(entry.insights == nil
            ? "整理：\(displayTitle)"
            : "查看整理结果：\(displayTitle)")
    }

    @ViewBuilder
    private var preview: some View {
        if entry.manifest.kind == .screenshot {
            TraceLibraryThumbnailView(url: entry.displayAssetURL)
        } else {
            ZStack {
                LinearGradient(
                    colors: [.black.opacity(0.88), .indigo.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: entry.manifest.state == .interrupted ? "exclamationmark.arrow.triangle.2.circlepath" : "play.circle.fill")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
    }

    private var stateBadge: some View {
        Text(stateTitle)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(stateColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(stateColor.opacity(0.12), in: Capsule())
    }

    private var stateTitle: String {
        switch entry.manifest.state {
        case .capturing: "录制中"
        case .processing: "智能处理中"
        case .ready: "就绪"
        case .interrupted: "已中断"
        case .failed: "失败"
        }
    }

    private var stateColor: Color {
        switch entry.manifest.state {
        case .ready: .green
        case .capturing, .processing: .orange
        case .interrupted, .failed: .red
        }
    }

    private func cardButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(.primary.opacity(0.055), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func durationText(_ duration: Double) -> String {
        let total = max(Int(duration.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

@MainActor
private final class TraceLibraryThumbnailCache {
    static let shared = TraceLibraryThumbnailCache()

    private let images = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func insert(_ image: NSImage, for url: URL) {
        images.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height))
    }
}

private struct TraceLibraryThumbnailView: View {
    let url: URL

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.72), .cyan.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            if let cached = TraceLibraryThumbnailCache.shared.image(for: url) {
                image = cached
                return
            }
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled,
                  let data,
                  let loaded = NSImage(data: data) else { return }
            TraceLibraryThumbnailCache.shared.insert(loaded, for: url)
            image = loaded
        }
    }
}

struct TraceInsightsPopover: View {
    let insights: TraceInsightsDocument
    let isOrganizing: Bool
    let onRegenerate: () -> Void
    let onSaveCustomization: (TraceInsightsCustomization?) -> Void

    @State private var isEditing = false
    @State private var titleDraft: String
    @State private var summaryDraft: String
    @State private var tagsDraft: String

    init(
        insights: TraceInsightsDocument,
        isOrganizing: Bool,
        onRegenerate: @escaping () -> Void,
        onSaveCustomization: @escaping (TraceInsightsCustomization?) -> Void
    ) {
        self.insights = insights
        self.isOrganizing = isOrganizing
        self.onRegenerate = onRegenerate
        self.onSaveCustomization = onSaveCustomization
        _titleDraft = State(initialValue: insights.resolvedTitle)
        _summaryDraft = State(initialValue: insights.resolvedSummary)
        _tagsDraft = State(initialValue: insights.resolvedTags.joined(separator: "、"))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地智能整理")
                            .font(.system(size: 13, weight: .semibold))
                        Label("只读取当前项目 · 未上传", systemImage: "lock.shield.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        if insights.customization != nil {
                            Label("含人工校正", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.cyan)
                        }
                    }
                    Spacer()
                    if isOrganizing { ProgressView().controlSize(.small) }
                }

                if isEditing {
                    customizationEditor
                }

                if !insights.resolvedTitle.isEmpty {
                    insightSection("标题建议", symbol: "text.quote") {
                        Text(insights.resolvedTitle)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                if !insights.resolvedSummary.isEmpty {
                    insightSection("摘要", symbol: "text.alignleft") {
                        Text(insights.resolvedSummary)
                            .font(.system(size: 10.5, weight: .medium))
                            .textSelection(.enabled)
                    }
                }
                if !insights.resolvedTags.isEmpty {
                    insightSection("标签", symbol: "tag.fill") {
                        FlowTags(tags: insights.resolvedTags)
                    }
                }
                if !insights.keyPoints.isEmpty {
                    insightSection("要点", symbol: "checklist") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(insights.keyPoints.enumerated()), id: \.offset) { _, point in
                                Label(point, systemImage: "circle.fill")
                                    .labelStyle(InsightBulletLabelStyle())
                            }
                        }
                        .font(.system(size: 10, weight: .medium))
                    }
                }
                if !insights.chapters.isEmpty {
                    insightSection("章节", symbol: "list.number") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(insights.chapters, id: \.index) { chapter in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(chapter.title)
                                            .font(.system(size: 10, weight: .semibold))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(time(chapter.startSeconds))–\(time(chapter.endSeconds))")
                                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(chapter.summary)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
                if !insights.sensitiveFindings.isEmpty {
                    insightSection("敏感信息提示", symbol: "exclamationmark.shield.fill") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(
                                Array(insights.sensitiveFindings.enumerated()),
                                id: \.offset
                            ) { _, finding in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(finding.kind.presentationTitle)
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(finding.redactedPreview)
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Text(finding.locationTitle)
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    if finding.occurrenceCount > 1 {
                                        Text("×\(finding.occurrenceCount)")
                                            .font(.system(size: 8.5, weight: .bold))
                                    }
                                }
                            }
                        }
                        .foregroundStyle(.orange)
                    }
                }

                if isEditing {
                    HStack {
                        Button("取消") {
                            resetDrafts()
                            isEditing = false
                        }
                        Spacer()
                        Button("保存校正") {
                            onSaveCustomization(TraceInsightsCustomization(
                                title: titleDraft,
                                summary: summaryDraft,
                                tags: parsedTags
                            ))
                            isEditing = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button {
                            isEditing = true
                        } label: {
                            Label("校正", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isOrganizing)
                        if insights.customization != nil {
                            Button {
                                onSaveCustomization(nil)
                                resetDraftsToGeneratedValues()
                            } label: {
                                Label("恢复自动", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isOrganizing)
                        }
                        Button(action: onRegenerate) {
                            Label("重新整理", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isOrganizing)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 380, height: 520)
        .traceGlassSurface(role: .window, cornerRadius: 20)
        .onChange(of: insights) { _, updated in
            guard !isEditing else { return }
            titleDraft = updated.resolvedTitle
            summaryDraft = updated.resolvedSummary
            tagsDraft = updated.resolvedTags.joined(separator: "、")
        }
    }

    private var customizationEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("人工校正", systemImage: "pencil.and.list.clipboard")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("标题", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $summaryDraft)
                .font(.system(size: 10.5, weight: .medium))
                .frame(minHeight: 70)
                .padding(5)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            TextField("标签，用逗号或顿号分隔", text: $tagsDraft)
                .textFieldStyle(.roundedBorder)
            Text("只改整理层；OCR、转写和原始媒体不会改变。")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.cyan.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var parsedTags: [String] {
        tagsDraft.components(
            separatedBy: CharacterSet(charactersIn: ",，、;；\n")
        )
    }

    private func resetDrafts() {
        titleDraft = insights.resolvedTitle
        summaryDraft = insights.resolvedSummary
        tagsDraft = insights.resolvedTags.joined(separator: "、")
    }

    private func resetDraftsToGeneratedValues() {
        titleDraft = insights.suggestedTitle
        summaryDraft = insights.summary
        tagsDraft = insights.tags.joined(separator: "、")
    }

    private func insightSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private func time(_ seconds: Double) -> String {
        let value = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct FlowTags: View {
    let tags: [String]

    private let columns = [
        GridItem(.adaptive(minimum: 68, maximum: 150), spacing: 5)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            ForEach(tags, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.cyan.opacity(0.10), in: Capsule())
                    .lineLimit(1)
            }
        }
    }
}

private struct InsightBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .font(.system(size: 4))
                .foregroundStyle(.cyan)
            configuration.title
        }
    }
}

private extension TraceSensitiveDataKind {
    var presentationTitle: String {
        switch self {
        case .emailAddress: "邮箱"
        case .phoneNumber: "电话"
        case .paymentCard: "卡号"
        case .governmentIdentifier: "证件号"
        case .credential: "凭据"
        }
    }
}

private extension TraceSensitiveFinding {
    var locationTitle: String {
        let sourceTitle = switch source {
        case .metadata: "元数据"
        case .ocr: "OCR"
        case .transcript: "转写"
        }
        guard let startSeconds else { return sourceTitle }
        let value = max(Int(startSeconds.rounded(.down)), 0)
        return String(format: "%@ %d:%02d", sourceTitle, value / 60, value % 60)
    }
}

private extension RecordingCaptureMode {
    var libraryTitle: String {
        switch self {
        case .region: "区域"
        case .window: "窗口"
        case .display: "屏幕"
        }
    }

    var librarySymbol: String {
        switch self {
        case .region: "viewfinder"
        case .window: "macwindow"
        case .display: "display"
        }
    }
}

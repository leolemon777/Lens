import AppKit
import ImageIO
import LensCore
import SwiftUI

extension Notification.Name {
    static let lensThumbnailDidChange = Notification.Name("LensThumbnailDidChange")
}

struct LensLibraryView: View {
    @ObservedObject var model: LensLibraryModel
    let onOpen: (LensLibraryEntry) -> Void
    let onReveal: (LensLibraryEntry) -> Void
    let onCopy: (LensLibraryEntry) -> Void
    let onAnnotate: (LensLibraryEntry) -> Void
    let onShowOCR: (LensLibraryEntry) -> Void
    let onTranscribe: (LensLibraryEntry) -> Void
    let onOrganize: (LensLibraryEntry) -> Void
    let onSaveInsights: (LensLibraryEntry, LensInsightsCustomization?) -> Void
    let onDelete: (LensLibraryEntry) -> Void
    let onRepair: (LensLibraryEntry) -> Void
    let onDeleteAll: () -> Void
    let onOpenFolder: () -> Void
    let onClose: () -> Void
    let onStartCapture: () -> Void

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
            LensBrandMark(diameter: 38)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lens 库")
                    .font(.system(size: LensType.title, weight: .semibold))
                Text("\(model.entries.count) 条本地记录 · 截图 \(model.screenshotCount) · 录屏 \(model.recordingCount)")
                    .font(.system(size: LensType.caption, weight: .medium))
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
                    .accessibilityLabel("搜索 Lens 库")
                    .accessibilityHint("按标题、标签、OCR 或转写搜索，结果会优先显示相关标题")
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
            .padding(.horizontal, LensSpacing.inset)
            .padding(.vertical, 7)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            Button(action: model.reload) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 27, height: 27)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("刷新")
            .accessibilityLabel("刷新 Lens 库")
            Button(action: onOpenFolder) {
                Image(systemName: "folder")
                    .frame(width: 27, height: 27)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("在 Finder 中打开")
            .accessibilityLabel("在 Finder 中打开 Lens 文件夹")
            Menu {
                Button(role: .destructive, action: onDeleteAll) {
                    Label("删除全部可删除记录", systemImage: "trash")
                }
                .disabled(model.entries.allSatisfy { !model.canDelete($0) })
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 27, height: 27)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .help("更多 Lens 库操作")
            .accessibilityLabel("Lens 库更多操作")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: LensIcon.small, weight: .bold))
                    .frame(width: 27, height: 27)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel("关闭 Lens 库")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, LensSpacing.section)
        .padding(.vertical, 13)
        .lensGlassSurface(role: .chrome, cornerRadius: LensGlassMetrics.chromeCornerRadius)
    }

    private var filterBar: some View {
        HStack {
            Picker("类型", selection: $model.filter) {
                Text("全部").tag(LensLibraryFilter.all)
                Text("截图").tag(LensLibraryFilter.screenshots)
                Text("录屏").tag(LensLibraryFilter.recordings)
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            Spacer()
            if model.isLoading || model.isFiltering {
                ProgressView()
                    .controlSize(.small)
                Text(model.isLoading ? "正在更新索引…" : "正在筛选…")
                    .foregroundStyle(.secondary)
            } else if let progress = model.recoveryScanProgress {
                ProgressView(value: progress.fractionCompleted)
                    .frame(width: 92)
                    .controlSize(.small)
                Text("正在检查录屏 \(progress.completed)/\(progress.total)…")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    if model.visibleEntries.count != model.entries.count {
                        Text("找到 \(model.visibleEntries.count) 条")
                            .foregroundStyle(.secondary)
                    }
                    if LensLibrarySearch.usesIntentExpansion(for: model.query) {
                        Label("本地智能匹配", systemImage: "sparkles")
                            .foregroundStyle(LensGlassPalette.accent)
                            .help("使用本地同义词匹配，不会上传素材内容")
                            .accessibilityLabel("本地智能匹配")
                            .accessibilityHint("使用本地同义词匹配，不会上传素材内容")
                    }
                }
            }
        }
        .font(.system(size: LensType.caption, weight: .medium))
        .padding(.horizontal, LensSpacing.section)
        .padding(.vertical, 9)
        .lensGlassSurface(role: .chrome, cornerRadius: LensGlassMetrics.chromeCornerRadius)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.entries.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在读取本地 Lens…")
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
                        LensLibraryCard(
                            entry: entry,
                            onOpen: { onOpen(entry) },
                            onReveal: { onReveal(entry) },
                            onCopy: { onCopy(entry) },
                            onAnnotate: { onAnnotate(entry) },
                            onShowOCR: { onShowOCR(entry) },
                            onTranscribe: { onTranscribe(entry) },
                            onOrganize: { onOrganize(entry) },
                            onSaveInsights: { onSaveInsights(entry, $0) },
                            onDelete: { onDelete(entry) },
                            canDelete: model.canDelete(entry),
                            isTranscribing: model.isTranscribing(entry.id),
                            transcriptionProgress: model.transcriptionProgress(for: entry.id),
                            isOrganizing: model.isOrganizing(entry.id),
                            recovery: model.recoveryAssessment(for: entry.id),
                            isRepairing: model.isRepairing(entry.id),
                            onRepair: { onRepair(entry) }
                        )
                    }
                }
                .padding(LensSpacing.section)
            }
            .background(Color.black.opacity(0.035))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.entries.isEmpty ? "sparkles.rectangle.stack" : "magnifyingglass")
                .font(.system(size: LensIcon.hero, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.entries.isEmpty ? "还没有 Lens" : "没有匹配的记录")
                .font(.system(size: LensType.body, weight: .semibold))
            Text(model.entries.isEmpty ? "完成一次截图或录屏后，它会自动出现在这里。" : "尝试更换关键词或类型筛选。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if model.entries.isEmpty {
                Button("开始一次捕获", action: onStartCapture)
                    .buttonStyle(.borderedProminent)
                    .tint(LensGlassPalette.accent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("清除筛选") {
                    model.query = ""
                    model.filter = .all
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LensLibraryCard: View {
    let entry: LensLibraryEntry
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopy: () -> Void
    let onAnnotate: () -> Void
    let onShowOCR: () -> Void
    let onTranscribe: () -> Void
    let onOrganize: () -> Void
    let onSaveInsights: (LensInsightsCustomization?) -> Void
    let onDelete: () -> Void
    let canDelete: Bool
    let isTranscribing: Bool
    let transcriptionProgress: LensLibraryTranscriptionProgress?
    let isOrganizing: Bool
    let recovery: RecordingRecoveryAssessment?
    let isRepairing: Bool
    let onRepair: () -> Void

    @State private var showsInsights = false
    @State private var isHovering = false
    @FocusState private var focusedSecondaryAction: SecondaryAction?

    private enum SecondaryAction: Hashable {
        case copy, share, annotate, ocr, transcribe
    }

    /// Hover alone would strand keyboard/VoiceOver users behind actions
    /// that never appear, so focus reveals the same set while the collapsed
    /// row keeps a tiny semantic footprint for the accessibility tree.
    private var showsSecondaryActions: Bool {
        isHovering || focusedSecondaryAction != nil
    }

    /// Damage found by comparing the project against its own files. The wording
    /// separates the two outcomes on purpose: a recording that holds more
    /// picture can be rebuilt, while a side track that outlived a dead screen
    /// stream has nothing left to merge and only warrants telling the user.
    @ViewBuilder
    private func recoveryNotice(_ recovery: RecordingRecoveryAssessment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(recovery.canRebuildLongerRecording
                     ? "有 \(durationText(recovery.recoverableScreenSeconds)) 画面没有并入成片"
                     : "录制期间屏幕画面提前结束")
                    .font(.system(size: LensType.micro, weight: .semibold))
            } icon: {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            }
            .foregroundStyle(LensGlassPalette.warning)

            Text(recoveryDetail(recovery))
                .font(.system(size: LensType.micro, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if recovery.canRebuildLongerRecording {
                Button(action: onRepair) {
                    Text(isRepairing ? "正在并入…" : "并入并重新生成")
                        .font(.system(size: LensType.micro, weight: .semibold))
                }
                .disabled(isRepairing)
                .help("原始分片会保留，不会被覆盖")
                .accessibilityLabel(isRepairing ? "正在并入并重新生成" : "并入并重新生成")
                .accessibilityHint("原始分片会保留，不会被覆盖")
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LensGlassPalette.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func recoveryDetail(_ recovery: RecordingRecoveryAssessment) -> String {
        if recovery.canRebuildLongerRecording {
            return "成片现在是 \(durationText(recovery.presentedScreenSeconds))，"
                + "磁盘上实际有 \(durationText(recovery.availableScreenSeconds))。"
                + "并入后原始分片仍然保留。"
        }
        let outlived = recovery.findings.compactMap { finding -> String? in
            guard case let .sideTrackOutlivesScreen(role, _, screen, track) = finding
            else { return nil }
            let name = role == .camera ? "摄像头" : (role == .microphone ? "麦克风" : "系统声音")
            return "\(name)录到 \(durationText(track))，画面只有 \(durationText(screen))"
        }
        if !outlived.isEmpty {
            return outlived.joined(separator: "；") + "。这部分没有对应画面可以合成，原始文件仍在项目里。"
        }
        let missing = recovery.findings.compactMap { finding -> String? in
            guard case let .missingDeclaredAsset(path, _) = finding else { return nil }
            return path
        }
        return missing.isEmpty
            ? "项目内容与记录不一致。"
            : "项目记录的文件已不在磁盘上：\(missing.joined(separator: "、"))。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(height: 132)
                .clipped()
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: entry.manifest.kind == .screenshot ? "photo" : "video.fill")
                        .foregroundStyle(
                            entry.manifest.kind == .screenshot
                                ? LensGlassPalette.neutral
                                : LensGlassPalette.recording
                        )
                    Text(displayTitle)
                        .font(.system(size: LensType.caption, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    stateBadge
                }
                // A card is only 210–270pt wide, which the timestamp plus every
                // badge routinely overruns — the badges then collide instead of
                // truncating. Drop badges from least to most informative until a
                // variant fits, so the row stays legible at any card width.
                ViewThatFits(in: .horizontal) {
                    metadataRow(badgeLimit: .max)
                    metadataRow(badgeLimit: 2)
                    metadataRow(badgeLimit: 1)
                    metadataRow(badgeLimit: 0)
                }
                .font(.system(size: LensType.micro, weight: .medium))
                .foregroundStyle(.secondary)

                if let summary = entry.insights?.resolvedSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: LensType.micro, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let tags = entry.insights?.resolvedTags, !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(tags.prefix(3)), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: LensType.micro, weight: .semibold))
                                .foregroundStyle(LensGlassPalette.neutral)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(LensGlassPalette.neutral.opacity(0.09), in: Capsule())
                        }
                    }
                }

                if let recovery, recovery.isDamaged {
                    recoveryNotice(recovery)
                }

                // Summary, tags, and the recovery notice are all optional, so
                // cards in the same grid row would otherwise end at different
                // heights and leave the action rows visibly ragged. Absorbing
                // the slack here pins every card's actions to its bottom edge.
                Spacer(minLength: 0)

                // Secondary actions live on an independent row above the primary tools
                // so revealing them never inflates the card width past its grid cell.
                HStack(spacing: 5) {
                    if entry.manifest.kind == .screenshot {
                        cardButton("复制", symbol: "doc.on.doc", action: onCopy)
                            .focused($focusedSecondaryAction, equals: .copy)
                        if let fileURL = QuickAccessFileTransfer.bestFileURL(for: entry) {
                            cardButton("分享", symbol: "square.and.arrow.up") {
                                LensFileSharing.present(fileURL: fileURL)
                            }
                            .help("打开 macOS 系统分享面板发送当前 PNG，不会自动上传")
                            .accessibilityHint("打开 macOS 系统分享面板发送当前 PNG，不会自动上传")
                            .focused($focusedSecondaryAction, equals: .share)
                        }
                        cardButton("标注", symbol: "pencil.tip", action: onAnnotate)
                            .focused($focusedSecondaryAction, equals: .annotate)
                        if entry.ocrText?.isEmpty == false {
                            cardButton("文字", symbol: "text.viewfinder", action: onShowOCR)
                                .focused($focusedSecondaryAction, equals: .ocr)
                        }
                    } else {
                        cardButton("复制文件", symbol: "doc.on.doc", action: onCopy)
                            .focused($focusedSecondaryAction, equals: .copy)
                        if QuickAccessFileTransfer.bestFileURL(for: entry) != nil {
                            cardButton("分享", symbol: "square.and.arrow.up") {
                                LensFileSharing.present(lens: SavedLens(
                                    packageURL: entry.packageURL,
                                    rawAssetURL: entry.primaryAssetURL,
                                    manifest: entry.manifest
                                ))
                            }
                            .help("打开 macOS 系统分享面板发送当前视频，不会自动上传")
                            .accessibilityHint("打开 macOS 系统分享面板发送当前视频，不会自动上传")
                            .focused($focusedSecondaryAction, equals: .share)
                        }
                        Button(action: onTranscribe) {
                            HStack(spacing: 4) {
                                if isTranscribing {
                                    if let transcriptionProgress {
                                        ProgressView(value: transcriptionProgress.fractionCompleted)
                                            .controlSize(.mini)
                                            .frame(width: 14)
                                    } else {
                                        ProgressView()
                                            .controlSize(.mini)
                                    }
                                } else {
                                    Image(systemName: "waveform.badge.magnifyingglass")
                                }
                                if isTranscribing {
                                    Text(transcriptionProgress.map {
                                        "转写 \($0.completed)/\($0.total)"
                                    } ?? "正在转写")
                                } else {
                                    Text(entry.transcriptText?.isEmpty == false ? "重转写" : "转写")
                                }
                            }
                            .font(.system(size: LensType.micro, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(.primary.opacity(0.055), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isTranscribing)
                        .accessibilityValue(
                            transcriptionProgress.map {
                                "已完成 \($0.completed) / \($0.total) 段"
                            } ?? (isTranscribing ? "进行中" : "未开始")
                        )
                        .focused($focusedSecondaryAction, equals: .transcribe)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A zero-height, fully transparent SwiftUI subtree disappears
                // from macOS AX. Keep one point of layout and a non-zero alpha
                // when collapsed: it remains visually imperceptible, while
                // VoiceOver and keyboard navigation can still discover the
                // actual buttons. Focus/hover expands the row normally.
                .frame(height: showsSecondaryActions ? nil : 1, alignment: .leading)
                .clipped()
                .opacity(showsSecondaryActions ? 1 : 0.001)
                .accessibilityHidden(false)

                HStack(spacing: 7) {
                    cardButton(
                        entry.manifest.kind == .screenshot ? "打开" : "编辑",
                        symbol: entry.manifest.kind == .screenshot
                            ? "arrow.up.right.square"
                            : "timeline.selection",
                        action: onOpen
                    )
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
                    .foregroundStyle(LensGlassPalette.recording.opacity(canDelete ? 0.90 : 0.35))
                    .disabled(!canDelete)
                    .help(canDelete ? "移到废纸篓" : "正在录制或处理，暂时不能删除")
                    .accessibilityLabel("删除：\(displayTitle)")
                }
            }
            .padding(11)
        }
        // Strict boundary: stretch to grid row height, but cap at the maximum
        // cell width so cards can never overflow horizontally into neighbours.
        .frame(maxWidth: 270)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .popover(isPresented: $showsInsights, arrowEdge: .trailing) {
            if let insights = entry.insights {
                LensInsightsPopover(
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

    private var deliveryState: QuickAccessDeliveryState {
        QuickAccessDeliveryState.derived(for: SavedLens(
            packageURL: entry.packageURL,
            rawAssetURL: entry.primaryAssetURL,
            manifest: entry.manifest
        ))
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
        .foregroundStyle(entry.insights == nil ? LensGlassPalette.neutral : LensGlassPalette.accent)
        .disabled(isOrganizing)
        .help(entry.insights == nil ? "本地智能整理" : "查看整理结果")
        .accessibilityLabel(entry.insights == nil
            ? "整理：\(displayTitle)"
            : "查看整理结果：\(displayTitle)")
    }

    @ViewBuilder
    private var preview: some View {
        if let fileURL = QuickAccessFileTransfer.bestFileURL(for: entry) {
            basePreview
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: LensIcon.small, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.68), in: Circle())
                        .padding(7)
                        .contentShape(Circle())
                        .onDrag {
                            let fallbackImage = NSImage(contentsOf: entry.displayAssetURL)
                                ?? NSWorkspace.shared.icon(forFile: fileURL.path)
                            return QuickAccessFileTransfer.itemProvider(
                                fileURL: fileURL,
                                suggestedName: QuickAccessFileTransfer.suggestedFileName(
                                    for: entry,
                                    fileURL: fileURL
                                ),
                                fallbackImage: fallbackImage
                            )
                        } preview: {
                            let fallbackImage = NSImage(contentsOf: entry.displayAssetURL)
                                ?? NSWorkspace.shared.icon(forFile: fileURL.path)
                            Image(nsImage: fallbackImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 180, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: LensGlassMetrics.controlCornerRadius, style: .continuous))
                        }
                        .help(entry.manifest.kind == .recording
                            ? "拖到 Finder、聊天或文档中发送视频"
                            : "拖到 Finder、聊天或文档中发送 PNG")
                        .accessibilityLabel(entry.manifest.kind == .recording
                            ? "拖到 Finder、聊天或文档中发送视频"
                            : "拖到 Finder、聊天或文档中发送 PNG")
                        .accessibilityHint(entry.manifest.kind == .recording
                            ? "按住并拖动此图标可发送视频文件"
                            : "按住并拖动此图标可发送 PNG 文件")
                }
                .help(entry.manifest.kind == .recording
                    ? "点击查看或编辑录屏"
                    : "点击查看原图")
        } else {
            basePreview
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .help(entry.manifest.kind == .recording
                    ? "点击查看或编辑录屏"
                    : "点击查看原图")
        }
    }

    @ViewBuilder
    private var basePreview: some View {
        if entry.manifest.kind == .screenshot {
            LensLibraryThumbnailView(url: entry.displayAssetURL)
        } else {
            ZStack {
                LinearGradient(
                    colors: [.black.opacity(0.88), LensGlassPalette.accent.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: entry.manifest.state == .interrupted ? "exclamationmark.arrow.triangle.2.circlepath" : "play.circle.fill")
                    .font(.system(size: LensIcon.hero, weight: .light))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
    }

    /// Secondary badges for the metadata row, most informative first so the
    /// `ViewThatFits` variants above shed the least useful ones as space runs out.
    private var metadataBadges: [(text: String, symbol: String, isWarning: Bool)] {
        var badges: [(String, String, Bool)] = []
        if let count = entry.insights?.sensitiveFindings.count, count > 0 {
            badges.append(("\(count) 项敏感", "exclamationmark.shield.fill", true))
        }
        if let capture = entry.manifest.captureSource {
            badges.append((capture.mode.libraryTitle, capture.mode.librarySymbol, false))
        }
        if entry.ocrText?.isEmpty == false {
            badges.append(("OCR", "text.viewfinder", false))
        }
        if entry.transcriptText?.isEmpty == false {
            badges.append(("转写", "captions.bubble.fill", false))
        }
        if entry.insights != nil {
            badges.append(("已整理", "sparkles", false))
        }
        return badges
    }

    private func metadataRow(badgeLimit: Int) -> some View {
        HStack(spacing: 7) {
            Text(entry.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let duration = entry.manifest.durationSeconds {
                Text(durationText(duration))
            }
            ForEach(Array(metadataBadges.prefix(badgeLimit)), id: \.text) { badge in
                Label(badge.text, systemImage: badge.symbol)
                    .foregroundStyle(badge.isWarning ? AnyShapeStyle(LensGlassPalette.warning) : AnyShapeStyle(.secondary))
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        // `fixedSize` makes the row report its ideal width even under a nil
        // proposal, and the card's row-height stretch measures exactly that.
        // An ideal wider than a grid cell became the card's minimum width, so
        // every card grew to the widest badge row and overlapped its
        // neighbours. Capping the ideal keeps the ladder (candidates still
        // report fixedSize under real proposals) without leaking it.
        .frame(idealWidth: 213, maxWidth: .infinity, alignment: .leading)
    }

    private var stateBadge: some View {
        Text(stateTitle)
            .font(.system(size: LensType.micro, weight: .bold))
            .foregroundStyle(stateColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(stateColor.opacity(0.12), in: Capsule())
    }

    private var stateTitle: String {
        if entry.manifest.kind == .screenshot {
            return "就绪"
        }
        return switch deliveryState {
        case .ready: "可交付"
        case .processing: "智能处理中"
        case .needsReview: "需复核"
        case .cancelled: "已取消"
        case .interrupted: "已中断"
        case .failed: "生成失败"
        }
    }

    private var stateColor: Color {
        switch deliveryState {
        case .ready: LensGlassPalette.success
        case .processing, .needsReview, .cancelled: LensGlassPalette.warning
        case .interrupted, .failed: LensGlassPalette.recording
        }
    }

    private func cardButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: LensType.micro, weight: .semibold))
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
final class LensLibraryThumbnailCache {
    static let shared = LensLibraryThumbnailCache()

    private let images = NSCache<NSString, NSImage>()
    private var latestKeys: [URL: NSString] = [:]

    init() {
        // A thumbnail is a display cache, never the source of truth. Bound
        // both count and decoded-pixel cost so long screenshots cannot grow
        // the process without limit.
        images.countLimit = 512
        images.totalCostLimit = 128 * 1_024 * 1_024
    }

    private func key(for url: URL) -> NSString {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modifiedAt = (attributes?[.modificationDate] as? Date)
            .map { String(format: "%.9f", $0.timeIntervalSince1970) }
            ?? "unknown"
        return "\(url.standardizedFileURL.path)|\(byteCount)|\(modifiedAt)" as NSString
    }

    func image(for url: URL) -> NSImage? {
        let cacheKey = key(for: url)
        latestKeys[url.standardizedFileURL] = cacheKey
        return images.object(forKey: cacheKey)
    }

    func insert(_ image: NSImage, for url: URL) {
        let normalizedURL = url.standardizedFileURL
        let cacheKey = key(for: normalizedURL)
        if let previousKey = latestKeys.updateValue(cacheKey, forKey: normalizedURL),
           previousKey != cacheKey {
            images.removeObject(forKey: previousKey)
        }
        images.setObject(
            image,
            forKey: cacheKey,
            cost: max(Int(image.size.width * image.size.height * 4), 1)
        )
    }

    func invalidate(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        if let previousKey = latestKeys.removeValue(forKey: normalizedURL) {
            images.removeObject(forKey: previousKey)
        }
    }
}

enum LensThumbnailDecoder {
    static let defaultMaximumPixelSize = 640

    static func image(
        from data: Data,
        maximumPixelSize: Int = defaultMaximumPixelSize
    ) -> NSImage? {
        guard maximumPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
                  ] as CFDictionary
              ) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

struct LensLibraryThumbnailView: View {
    let url: URL

    @State private var image: NSImage?
    @State private var reloadToken = UUID()

    init(url: URL) {
        self.url = url
        // A cache hit renders the image on the first pass instead of flashing
        // the loading state until `.task` completes.
        _image = State(initialValue: LensLibraryThumbnailCache.shared.image(for: url))
    }

    /// Synchronous seed for previews and layout tests. Production callers use
    /// `init(url:)` and let the `.task` below load from disk.
    init(url: URL, previewImage: NSImage) {
        self.url = url
        _image = State(initialValue: previewImage)
    }

    var body: some View {
        Color.clear
            .background {
                LinearGradient(
                    colors: [.black.opacity(0.72), LensGlassPalette.accent.opacity(0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .background {
                if let image {
                    // `scaledToFill` reports its cover size (row height × image
                    // aspect) as the view's ideal width, and under a frame that
                    // measures ideal size (the card's row-height stretch) that
                    // width inflated the whole card past its grid cell so cards
                    // overlapped their neighbours. Background layers never feed
                    // size back into layout, and the clip below trims the
                    // overflowing paint to the slot.
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay {
                if image == nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.75))
                }
            }
            .clipped()
            .task(id: reloadToken) {
                await loadImage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .lensThumbnailDidChange)) { note in
                guard let changedURL = note.object as? URL,
                      changedURL.standardizedFileURL == url.standardizedFileURL else {
                    return
                }
                LensLibraryThumbnailCache.shared.invalidate(url)
                image = nil
                reloadToken = UUID()
            }
    }

    private func loadImage() async {
            if let cached = LensLibraryThumbnailCache.shared.image(for: url) {
                image = cached
                return
            }
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled,
                  let data,
                  let loaded = LensThumbnailDecoder.image(from: data) else { return }
            LensLibraryThumbnailCache.shared.insert(loaded, for: url)
            image = loaded
    }
}

struct LensInsightsPopover: View {
    let insights: LensInsightsDocument
    let isOrganizing: Bool
    let onRegenerate: () -> Void
    let onSaveCustomization: (LensInsightsCustomization?) -> Void

    @State private var isEditing = false
    @State private var titleDraft: String
    @State private var summaryDraft: String
    @State private var tagsDraft: String

    init(
        insights: LensInsightsDocument,
        isOrganizing: Bool,
        onRegenerate: @escaping () -> Void,
        onSaveCustomization: @escaping (LensInsightsCustomization?) -> Void
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
                        .font(.system(size: LensIcon.large, weight: .semibold))
                        .foregroundStyle(LensGlassPalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地智能整理")
                            .font(.system(size: 13, weight: .semibold))
                        Label("只读取当前项目 · 未上传", systemImage: "lock.shield.fill")
                            .font(.system(size: LensType.micro, weight: .medium))
                            .foregroundStyle(.secondary)
                        if insights.customization != nil {
                            Label("含人工校正", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.system(size: LensType.micro, weight: .semibold))
                                .foregroundStyle(LensGlassPalette.success)
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
                            .font(.system(size: LensType.caption, weight: .medium))
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
                                            .font(.system(size: LensType.micro, weight: .semibold))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(time(chapter.startSeconds))–\(time(chapter.endSeconds))")
                                            .font(.system(size: LensType.micro, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(chapter.summary)
                                        .font(.system(size: LensType.micro, weight: .medium))
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
                                        .font(.system(size: LensType.micro, weight: .semibold))
                                    Text(finding.redactedPreview)
                                        .font(.system(size: LensType.micro, weight: .medium, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Text(finding.locationTitle)
                                        .font(.system(size: LensType.micro, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    if finding.occurrenceCount > 1 {
                                        Text("×\(finding.occurrenceCount)")
                                            .font(.system(size: LensType.micro, weight: .bold))
                                    }
                                }
                            }
                        }
                        .foregroundStyle(LensGlassPalette.warning)
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
                            onSaveCustomization(LensInsightsCustomization(
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
            .padding(LensSpacing.l)
        }
        .frame(width: 380, height: 520)
        .lensGlassSurface(role: .window, cornerRadius: LensGlassMetrics.windowCornerRadius)
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
                .font(.system(size: LensType.caption, weight: .medium))
                .frame(minHeight: 70)
                .padding(5)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            TextField("标签，用逗号或顿号分隔", text: $tagsDraft)
                .textFieldStyle(.roundedBorder)
            Text("只改整理层；OCR、转写和原始媒体不会改变。")
                .font(.system(size: LensType.micro, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(LensSpacing.inset)
        .background(LensGlassPalette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: LensGlassMetrics.controlCornerRadius))
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
        .padding(LensSpacing.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: LensGlassMetrics.controlCornerRadius))
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
                    .font(.system(size: LensType.micro, weight: .semibold))
                    .foregroundStyle(LensGlassPalette.neutral)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(LensGlassPalette.neutral.opacity(0.10), in: Capsule())
                    .lineLimit(1)
            }
        }
    }
}

private struct InsightBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .font(.system(size: 4)) // lens-token-exempt: 项目符号圆点，非文字
                .foregroundStyle(LensGlassPalette.neutral)
            configuration.title
        }
    }
}

private extension LensSensitiveDataKind {
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

private extension LensSensitiveFinding {
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

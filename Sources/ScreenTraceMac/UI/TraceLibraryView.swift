import AppKit
import ScreenTraceCore
import SwiftUI

struct TraceLibraryView: View {
    @ObservedObject var model: TraceLibraryModel
    let onOpen: (TraceLibraryEntry) -> Void
    let onReveal: (TraceLibraryEntry) -> Void
    let onCopy: (TraceLibraryEntry) -> Void
    let onAnnotate: (TraceLibraryEntry) -> Void
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
                TextField("搜索标题或 OCR 文字", text: $model.query)
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
            Button(action: onOpenFolder) {
                Image(systemName: "folder")
                    .frame(width: 27, height: 27)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("在 Finder 中打开")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 27, height: 27)
                    .background(.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial)
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
        .background(.thinMaterial)
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
                            onAnnotate: { onAnnotate(entry) }
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

    private var thumbnail: NSImage? {
        guard entry.manifest.kind == .screenshot else { return nil }
        return NSImage(contentsOf: entry.displayAssetURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(height: 132)
                .clipped()
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: entry.manifest.kind == .screenshot ? "photo" : "video.fill")
                        .foregroundStyle(entry.manifest.kind == .screenshot ? .cyan : .red)
                    Text(entry.manifest.title)
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
                    if let duration = entry.manifest.durationSeconds {
                        Text(durationText(duration))
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)

                HStack(spacing: 7) {
                    cardButton("打开", symbol: "arrow.up.right.square", action: onOpen)
                    if entry.manifest.kind == .screenshot {
                        cardButton("复制", symbol: "doc.on.doc", action: onCopy)
                        cardButton("标注", symbol: "pencil.tip", action: onAnnotate)
                    }
                    Spacer(minLength: 0)
                    Button(action: onReveal) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("在 Finder 中显示")
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
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case .processing: "处理中"
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

import AppKit
import LensCore
import SwiftUI

struct QuickAccessView: View {
    let lens: SavedLens
    let image: NSImage
    let dragFileURL: URL?
    let dragSuggestedName: String?
    let confirmationTitle: String
    let onCopy: () -> Void
    let onAnnotate: () -> Void
    let onEdit: () -> Void
    let onReveal: () -> Void
    let onPin: () -> Void
    let onConversationInbox: () -> Void
    let onClose: () -> Void

    private var isRecording: Bool { lens.manifest.kind == .recording }

    var body: some View {
        HStack(spacing: 12) {
            draggablePreview

            VStack(alignment: .leading, spacing: 5) {
                Label(confirmationTitle, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detailText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if isRecording {
                        quickButton("复制文件", symbol: "doc.on.doc", action: onCopy)
                        quickButton("编辑", symbol: "timeline.selection", action: onEdit)
                        quickButton("显示", symbol: "folder", action: onReveal)
                    } else {
                        quickButton("复制", symbol: "doc.on.doc", action: onCopy)
                        quickButton("标注", symbol: "pencil.tip", action: onAnnotate)
                        quickButton("显示", symbol: "folder", action: onReveal)
                        quickButton("贴图", symbol: "pin", action: onPin)
                        quickButton("对话", symbol: "terminal", action: onConversationInbox)
                            .help("保存到对话文件夹并复制路径，方便在终端里发给 AI")
                            .accessibilityHint("保存到对话文件夹并复制路径")
                    }
                }
                .padding(.top, 3)
            }

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭")
            .accessibilityLabel("关闭快速操作")
            .keyboardShortcut(.cancelAction)
        }
        .padding(12)
        .frame(width: isRecording ? 460 : 508)
        .lensGlassSurface(role: .panel, cornerRadius: LensGlassMetrics.panelCornerRadius)
        .padding(28)
    }

    private var detailText: String {
        if isRecording {
            if let seconds = lens.manifest.durationSeconds {
                return String(format: "%.0f 秒 · 可拖进聊天", seconds)
            }
            return "可拖进聊天"
        }
        if let dimensions = lens.manifest.dimensions {
            return "\(dimensions.width) × \(dimensions.height) · 可拖进聊天"
        }
        return "可拖进聊天"
    }

    @ViewBuilder
    private var draggablePreview: some View {
        let preview = Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 118, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.58), in: Circle())
                    .padding(5)
                    .accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
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
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .help(isRecording ? "拖到聊天或 Finder 中发送视频" : "拖到 Finder、聊天或文档中发送 PNG")
                .accessibilityHint(isRecording
                    ? "按住并拖动预览可发送视频文件"
                    : "按住并拖动预览可发送 PNG 文件")
        } else {
            preview
        }
    }

    private func quickButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
        }
        .buttonStyle(LensGlassButtonStyle(tint: .cyan, cornerRadius: 12))
    }
}

@MainActor
enum QuickAccessFileTransfer {
    static func bestFileURL(for lens: SavedLens) -> URL? {
        let preferredRole: LensAsset.Role = lens.manifest.kind == .recording
            ? .renderedVideo
            : .renderedScreenshot
        let preferredCandidates = lens.manifest.assets
            .filter { $0.role == preferredRole }
            .map { lens.packageURL.appendingPathComponent($0.relativePath) }
        let candidates = preferredCandidates + [lens.rawAssetURL]
        return candidates.first { candidate in
            isRegularFileInsidePackage(candidate, packageURL: lens.packageURL)
        }
    }

    static func suggestedFileName(for lens: SavedLens, fileURL: URL) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: lens.manifest.createdAt)
        let identifier = String(lens.manifest.id.uuidString.prefix(8))
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

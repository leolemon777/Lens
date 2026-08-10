import AppKit
import ScreenTraceCore
import SwiftUI

struct QuickAccessView: View {
    let trace: SavedTrace
    let image: NSImage
    let onCopy: () -> Void
    let onAnnotate: () -> Void
    let onReveal: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 118, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
                .accessibilityLabel("刚刚保存的截图预览")

            VStack(alignment: .leading, spacing: 5) {
                Label("截图已复制", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                if let dimensions = trace.manifest.dimensions {
                    Text("\(dimensions.width) × \(dimensions.height) · 已保存为 Trace")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    quickButton("复制", symbol: "doc.on.doc", action: onCopy)
                    quickButton("标注", symbol: "pencil.tip", action: onAnnotate)
                    quickButton("显示", symbol: "folder", action: onReveal)
                    quickButton("贴图", symbol: "pin", action: onPin)
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
        .frame(width: 430)
        .traceGlassPanel(cornerRadius: 24)
        .padding(28)
    }

    private func quickButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

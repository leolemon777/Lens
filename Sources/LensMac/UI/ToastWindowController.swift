import AppKit
import SwiftUI

private struct LensToastView: View {
    let title: String
    let detail: String?
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: LensIcon.medium, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: LensType.body, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: LensType.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .lensGlassSurface(role: .panel, cornerRadius: LensGlassMetrics.panelCornerRadius)
        .padding(24)
    }
}

@MainActor
final class ToastWindowController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(title: String, detail: String? = nil, symbol: String = "checkmark.circle.fill") {
        dismissTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: LensToastView(title: title, detail: detail, symbol: symbol))
        position(panel)
        LensPanelPresenter.present(panel, from: .top)

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            LensPanelPresenter.dismiss(panel)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - panel.frame.width / 2,
            y: screen.visibleFrame.maxY - panel.frame.height - 18
        ))
    }
}

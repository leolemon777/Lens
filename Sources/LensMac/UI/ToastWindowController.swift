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
        .padding(.horizontal, LensSpacing.card)
        .padding(.vertical, LensSpacing.inset)
        .lensGlassSurface(role: .panel, cornerRadius: LensGlassMetrics.panelCornerRadius)
        .padding(LensSpacing.xl)
    }
}

@MainActor
final class ToastWindowController {
    private var panel: LensGlassPanel?
    private var dismissTask: Task<Void, Never>?

    func show(title: String, detail: String? = nil, symbol: String = "checkmark.circle.fill") {
        dismissTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: LensToastView(title: title, detail: detail, symbol: symbol))
        panel.placeOnScreen()
        LensPanelPresenter.present(panel, from: .top)

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            LensPanelPresenter.dismiss(panel)
        }
    }

    private func makePanel() -> LensGlassPanel {
        let panel = LensGlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
            placement: .top,
            allowsKey: false,
            nonactivating: true
        )
        panel.level = .floating
        return panel
    }
}

import AppKit
import LensCore
import SwiftUI

struct ShortcutRecorderButton: View {
    @Binding var shortcut: HotKeyShortcut
    let forbidden: Set<HotKeyShortcut>
    let onChanged: () -> Void
    var onCaptureActiveChange: (Bool) -> Void = { _ in }
    @State private var isCapturing = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                validationMessage = nil
                onCaptureActiveChange(true)
                isCapturing = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCapturing ? "keyboard.badge.ellipsis" : "keyboard")
                    Text(isCapturing ? "请按新的组合键…" : shortcut.displayName)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .font(.system(size: LensType.caption, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    (isCapturing ? LensGlassPalette.accent : Color.primary).opacity(0.08),
                    in: RoundedRectangle(
                        cornerRadius: LensGlassMetrics.controlCornerRadius,
                        style: .continuous
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: LensGlassMetrics.controlCornerRadius,
                        style: .continuous
                    )
                    .stroke(isCapturing ? LensGlassPalette.accent.opacity(0.55) : .white.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCapturing ? "正在录入快捷键" : "快捷键 \(shortcut.displayName)")
            .accessibilityHint(isCapturing
                ? "按下新的组合键，按 Escape 取消"
                : "按下后录入新的组合键")
            .background(
                ShortcutCaptureHost(
                    isActive: $isCapturing,
                    onCapture: apply,
                    onCancel: { validationMessage = nil }
                )
                .frame(width: 1, height: 1)
            )
            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: LensType.micro, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isCapturing) { _, active in
            onCaptureActiveChange(active)
        }
    }

    private func apply(_ candidate: HotKeyShortcut) {
        if forbidden.contains(candidate) {
            validationMessage = "该组合已被另一项功能或备用快捷键占用"
            return
        }
        if let error = candidate.validationError {
            validationMessage = switch error {
            case .missingModifier: "请至少按下 Fn、Control、Option 或 Command"
            case .modifierOnlyRequiresFunction: "纯修饰键组合必须包含 Fn"
            case .modifierOnlyRequiresTwoModifiers: "请至少组合两个修饰键"
            case .unsupportedModifier: "该修饰键组合暂不支持"
            }
            return
        }
        shortcut = candidate
        validationMessage = nil
        onChanged()
    }
}

private struct ShortcutCaptureHost: NSViewRepresentable {
    @Binding var isActive: Bool
    let onCapture: (HotKeyShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureView {
        ShortcutCaptureView()
    }

    func updateNSView(_ view: ShortcutCaptureView, context: Context) {
        view.isActive = isActive
        view.onCapture = { shortcut in
            view.isActive = false
            onCapture(shortcut)
            isActive = false
        }
        view.onCancel = {
            view.isActive = false
            onCancel()
            isActive = false
        }
        if isActive {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }
}

private final class ShortcutCaptureView: NSView {
    var isActive = false
    var onCapture: ((HotKeyShortcut) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func resignFirstResponder() -> Bool {
        if isActive {
            isActive = false
            onCancel?()
        }
        return super.resignFirstResponder()
    }

    @objc private func windowDidResignKey() {
        guard isActive else { return }
        isActive = false
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            super.keyDown(with: event)
            return
        }
        let modifiers = GlobalHotKeyManager.modifiers(from: event.modifierFlags)
        if event.keyCode == 53, modifiers.isEmpty {
            onCancel?()
            return
        }
        onCapture?(HotKeyShortcut(keyCode: event.keyCode, modifiers: modifiers))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isActive else {
            super.flagsChanged(with: event)
            return
        }
        let modifiers = GlobalHotKeyManager.modifiers(from: event.modifierFlags)
        guard modifiers.contains(.function), modifiers.rawValue.nonzeroBitCount >= 2 else { return }
        onCapture?(HotKeyShortcut(keyCode: nil, modifiers: modifiers))
    }
}

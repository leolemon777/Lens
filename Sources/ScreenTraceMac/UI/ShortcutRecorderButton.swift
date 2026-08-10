import AppKit
import ScreenTraceCore
import SwiftUI

struct ShortcutRecorderButton: View {
    @Binding var shortcut: HotKeyShortcut
    let forbidden: Set<HotKeyShortcut>
    let onChanged: () -> Void
    @State private var isCapturing = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                validationMessage = nil
                isCapturing = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCapturing ? "keyboard.badge.ellipsis" : "keyboard")
                    Text(isCapturing ? "请按新的组合键…" : shortcut.displayName)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    (isCapturing ? Color.cyan : Color.primary).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isCapturing ? .cyan.opacity(0.55) : .white.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
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
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            onCapture(shortcut)
            isActive = false
            view.window?.makeFirstResponder(nil)
        }
        view.onCancel = {
            onCancel()
            isActive = false
            view.window?.makeFirstResponder(nil)
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

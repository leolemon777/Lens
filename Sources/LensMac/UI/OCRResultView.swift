import AppKit
import LensCore
import SwiftUI

enum OCRResultPhase: Equatable {
    case recognizing
    case ready
}

enum OCRResultFulfillment: Equatable {
    case ready
    case empty
    case dismissed
}

@MainActor
final class OCRResultModel: ObservableObject {
    let thumbnail: NSImage?
    private(set) var originalText: String
    private(set) var blockCount: Int
    @Published var phase: OCRResultPhase
    @Published var editedText: String

    init(recognizing thumbnail: NSImage?) {
        self.thumbnail = thumbnail
        originalText = ""
        blockCount = 0
        phase = .recognizing
        editedText = ""
    }

    init(document: OCRDocument, thumbnail: NSImage?) {
        self.thumbnail = thumbnail
        let draft = OCRResultDraft(document: document)
        originalText = draft.originalText
        blockCount = draft.blockCount
        phase = .ready
        editedText = draft.editedText
    }

    var isEdited: Bool { editedText != originalText }

    var hasText: Bool {
        phase == .ready
            && !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func apply(_ document: OCRDocument) {
        let draft = OCRResultDraft(document: document)
        originalText = draft.originalText
        blockCount = draft.blockCount
        editedText = draft.editedText
        phase = .ready
    }

    func reset() {
        editedText = originalText
    }

    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard hasText else { return false }
        return OCRResultPasteboard.copy(editedText, to: pasteboard)
    }
}

struct OCRResultView: View {
    @ObservedObject var model: OCRResultModel
    let onCopy: () -> Void
    let onCopyAndClose: () -> Void
    let onClose: () -> Void
    @FocusState private var isEditingText: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 88)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    )
                    .accessibilityLabel("OCR 原图预览")
            }
            resultBody
            HStack(spacing: 8) {
                if model.phase == .ready, model.isEdited {
                    Button("还原", action: model.reset)
                        .buttonStyle(LensGlassButtonStyle(tint: .secondary, cornerRadius: 12))
                        .accessibilityLabel("还原识别原文")
                }
                Spacer()
                Button("复制", action: onCopy)
                    .buttonStyle(LensGlassButtonStyle(tint: LensGlassPalette.neutral, cornerRadius: 12))
                    .disabled(!model.hasText)
                    .accessibilityLabel("复制识别文字")
                Button("复制并关闭", action: onCopyAndClose)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(LensGlassButtonStyle(tint: LensGlassPalette.accent, cornerRadius: 12))
                    .disabled(!model.hasText)
                    .accessibilityLabel("复制并关闭")
                    .help("Command-Return")
                Button("关闭", action: onClose)
                    .buttonStyle(LensGlassButtonStyle(tint: .secondary, cornerRadius: 12))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("关闭 OCR 结果")
            }
        }
        .padding(LensSpacing.card)
        .frame(width: 420, height: model.thumbnail == nil ? 320 : 408)
        .lensGlassSurface(role: .panel, cornerRadius: LensGlassMetrics.panelCornerRadius)
        .padding(22)
        .onAppear { focusEditorIfReady() }
        .onChange(of: model.phase) { _, _ in focusEditorIfReady() }
    }

    @ViewBuilder
    private var resultBody: some View {
        if model.phase == .recognizing {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在识别…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 148, maxHeight: .infinity, alignment: .leading)
            .padding(LensSpacing.m)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在识别文字")
        } else {
            TextEditor(text: $model.editedText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(LensSpacing.s)
                .frame(minHeight: 148, maxHeight: .infinity)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused($isEditingText)
                .accessibilityLabel("识别文字")
                .accessibilityHint("可以修改后再复制。Command-Return 复制并关闭")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LensGlassPalette.accent)
                .frame(width: 32, height: 32)
                .background(LensGlassPalette.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(model.phase == .recognizing ? "正在识别" : "OCR 识别")
                    .font(.system(size: 14, weight: .semibold))
                Text(headerDetail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭")
            .accessibilityLabel("关闭 OCR 结果")
        }
    }

    private var headerDetail: String {
        switch model.phase {
        case .recognizing:
            return "识别完成后可修改，不会自动进剪贴板"
        case .ready:
            return "\(model.blockCount) 段 · Command-Return 复制并关闭"
        }
    }

    private func focusEditorIfReady() {
        isEditingText = model.phase == .ready
    }
}

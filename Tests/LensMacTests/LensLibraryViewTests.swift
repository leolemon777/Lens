import AppKit
import CoreGraphics
import SwiftUI
import XCTest
import LensCore
@testable import LensMac

@MainActor
final class LensLibraryViewTests: XCTestCase {
    func testLibraryViewLaysOutAndRendersWithMixedEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensLibraryViewTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let screenshotURL = root.appendingPathComponent("screenshot.png")
        try screenshotPNGData(width: 960, height: 540).write(to: screenshotURL)
        let screenshot = makeEntry(
            root: root,
            kind: .screenshot,
            title: "设计评审截图",
            assetURL: screenshotURL,
            state: .ready,
            duration: nil,
            ocrText: "Lens launch checklist",
            insights: LensInsightsDocument(
                engine: LocalLensOrganizer.engineIdentifier,
                suggestedTitle: "Safari · Lens 发布检查",
                summary: "检查本地发布流程、字幕与敏感信息提示。",
                tags: ["产品", "Lens", "发布"],
                keyPoints: ["确认所有媒体仍保存在本机"],
                sensitiveFindings: [
                    LensSensitiveFinding(
                        kind: .emailAddress,
                        source: .ocr,
                        redactedPreview: "a•••@example.com"
                    )
                ]
            )
        )
        let recordingURL = root.appendingPathComponent("recording.mp4")
        let recording = makeEntry(
            root: root,
            kind: .recording,
            title: "自然运镜演示",
            assetURL: recordingURL,
            state: .processing,
            duration: 72,
            ocrText: nil,
            insights: nil
        )
        let model = LensLibraryModel(
            store: LensProjectStore(rootDirectory: root),
            initialEntries: [screenshot, recording]
        )
        let rootView = LensLibraryView(
            model: model,
            onOpen: { _ in },
            onReveal: { _ in },
            onCopy: { _ in },
            onAnnotate: { _ in },
            onShowOCR: { _ in },
            onTranscribe: { _ in },
            onOrganize: { _ in },
            onSaveInsights: { _, _ in },
            onDelete: { _ in },
            onRepair: { _ in },
            onDeleteAll: {},
            onOpenFolder: {},
            onClose: {},
            onStartCapture: {}
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_020, height: 690)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create SwiftUI snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 1_020)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 690)
        XCTAssertEqual(
            Double(representation.pixelsWide) / Double(representation.pixelsHigh),
            34.0 / 23.0,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(png?.count ?? 0, 25_000)
    }

    func testScreenshotCardsExposeAnOCRReopenActionWhenTextExists() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/LensLibraryView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("onShowOCR"))
        XCTAssertTrue(source.contains("cardButton(\"文字\""))
        XCTAssertTrue(source.contains("entry.ocrText?.isEmpty == false"))
    }

    func testEmptyLibraryOffersCaptureAndFilteredStateOffersClearAction() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/LensLibraryView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("开始一次捕获"))
        XCTAssertTrue(source.contains("清除筛选"))
        XCTAssertTrue(source.contains("onStartCapture"))
        XCTAssertTrue(source.contains("搜索 Lens 库"))
        XCTAssertTrue(source.contains("结果会优先显示相关标题"))
        XCTAssertTrue(source.contains("本地智能匹配"))
        XCTAssertTrue(source.contains("不会上传素材内容"))
    }

    func testLibraryCardsOfferCrossAppDragDelivery() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/LensLibraryView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("QuickAccessFileTransfer.bestFileURL(for: entry)"))
        XCTAssertTrue(source.contains("onDrag"))
        XCTAssertTrue(source.contains("拖到 Finder、聊天或文档中发送 PNG"))
        XCTAssertTrue(source.contains("拖到 Finder、聊天或文档中发送视频"))
    }

    func testCardSecondaryActionsRevealOnHoverOrKeyboardFocusNotOnlyHover() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/LensLibraryView.swift"),
            encoding: .utf8
        )
        // Primary action is unconditional; secondary actions live in a
        // separate group gated by opacity (never removed from the tree)
        // so Tab/VoiceOver can still reach them when the pointer never
        // hovers the card.
        XCTAssertTrue(source.contains("var showsSecondaryActions: Bool"))
        XCTAssertTrue(source.contains("isHovering || focusedSecondaryAction != nil"))
        XCTAssertTrue(source.contains(".opacity(showsSecondaryActions ? 1 : 0)"))
        XCTAssertFalse(
            source.contains("if showsSecondaryActions {"),
            "Secondary actions must be opacity-hidden, not removed with `if`, " +
            "or keyboard/VoiceOver users could never reach them."
        )
        // Every secondary action must bind to the shared FocusState so
        // keyboard focus alone (no pointer) reveals the same set.
        XCTAssertTrue(source.contains(".focused($focusedSecondaryAction, equals: .copy)"))
        XCTAssertTrue(source.contains(".focused($focusedSecondaryAction, equals: .share)"))
        XCTAssertTrue(source.contains(".focused($focusedSecondaryAction, equals: .annotate)"))
        XCTAssertTrue(source.contains(".focused($focusedSecondaryAction, equals: .ocr)"))
        XCTAssertTrue(source.contains(".focused($focusedSecondaryAction, equals: .transcribe)"))
        // Delete keeps its existing misclick guard and organize/reveal stay
        // compact icon affordances — none of the three enter the
        // primary/secondary tiering.
        XCTAssertTrue(source.contains(".disabled(!canDelete)"))
    }

    func testRecordingCardsOfferFileCopyAction() throws {
        let viewSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/LensLibraryView.swift"),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/LensLibraryWindowController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(viewSource.contains("cardButton(\"复制文件\", symbol: \"doc.on.doc\", action: onCopy)"))
        XCTAssertTrue(controllerSource.contains("FileURLPasteboard.copy(fileURL)"))
    }

    func testRecordingCardsOfferNativeShareAction() throws {
        let viewSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/LensLibraryView.swift"),
            encoding: .utf8
        )
        let sharingSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/LensFileSharing.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(viewSource.contains("cardButton(\"分享\", symbol: \"square.and.arrow.up\")"))
        XCTAssertTrue(viewSource.contains("LensFileSharing.present(fileURL: fileURL)"))
        XCTAssertTrue(viewSource.contains("不会自动上传"))
        XCTAssertTrue(sharingSource.contains("NSSharingServicePicker"))
        XCTAssertTrue(sharingSource.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertTrue(sharingSource.contains("chooses one"))
    }

    func testScreenshotCardsOfferNativeShareAction() throws {
        let viewSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/LensLibraryView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(viewSource.contains("entry.manifest.kind == .screenshot"))
        XCTAssertTrue(viewSource.contains("LensFileSharing.present(fileURL: fileURL)"))
        XCTAssertTrue(viewSource.contains("发送当前 PNG，不会自动上传"))
    }

    func testInsightsPopoverRendersWrappedTagsChaptersAndPrivacyWarnings() throws {
        let insights = LensInsightsDocument(
            engine: LocalLensOrganizer.engineIdentifier,
            suggestedTitle: "Lens 本地发布与隐私检查",
            summary: "整理结果仅引用本机 OCR 与转写，并保留原始素材和分析来源。",
            tags: ["Lens", "产品", "发布", "隐私", "字幕", "macOS"],
            keyPoints: [
                "检查全部原始轨道仍然完整",
                "确认整理文件不复制敏感原值"
            ],
            chapters: [
                LensChapter(
                    index: 0,
                    startSeconds: 0,
                    endSeconds: 42,
                    title: "产品目标",
                    summary: "说明快速捕获和本地优先原则。"
                ),
                LensChapter(
                    index: 1,
                    startSeconds: 42,
                    endSeconds: 96,
                    title: "发布检查",
                    summary: "核对字幕、索引和隐私提醒。"
                )
            ],
            sensitiveFindings: [
                LensSensitiveFinding(
                    kind: .credential,
                    source: .transcript,
                    startSeconds: 71,
                    endSeconds: 74,
                    redactedPreview: "api_key: ••••"
                )
            ],
            customization: LensInsightsCustomization(
                title: "人工校正：Lens 发布检查",
                summary: "已核对本地处理、原始素材保护和隐私提示。",
                tags: ["已审阅", "隐私", "发布"]
            )
        )
        let rootView = LensInsightsPopover(
            insights: insights,
            isOrganizing: false,
            onRegenerate: {},
            onSaveCustomization: { _ in }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(x: 0, y: 0, width: 420, height: 560)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw XCTSkip("Unable to create insights snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 420)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 560)
        XCTAssertGreaterThan(png?.count ?? 0, 18_000)
    }

    private func makeEntry(
        root: URL,
        kind: LensKind,
        title: String,
        assetURL: URL,
        state: LensState,
        duration: Double?,
        ocrText: String?,
        insights: LensInsightsDocument?
    ) -> LensLibraryEntry {
        let id = UUID()
        let package = root.appendingPathComponent("\(id.uuidString).lens", isDirectory: true)
        let role: LensAsset.Role = kind == .screenshot ? .screenshot : .screenVideo
        let manifest = LensManifest(
            id: id,
            kind: kind,
            title: title,
            state: state,
            durationSeconds: duration,
            dimensions: LensDimensions(width: 960, height: 540),
            captureSource: kind == .recording
                ? LensCaptureMetadata(
                    mode: .window,
                    windowID: 12,
                    globalBounds: LensRect(x: 80, y: 60, width: 960, height: 540),
                    windowTitle: "产品演示",
                    applicationName: "Safari"
                )
                : nil,
            assets: [LensAsset(role: role, relativePath: assetURL.lastPathComponent)]
        )
        return LensLibraryEntry(
            packageURL: package,
            manifest: manifest,
            primaryAssetURL: assetURL,
            displayAssetURL: assetURL,
            ocrText: ocrText,
            insights: insights
        )
    }

    private func screenshotPNGData(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Unable to create source bitmap")
        }
        context.setFillColor(CGColor(red: 0.06, green: 0.10, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.15, green: 0.78, blue: 0.90, alpha: 1))
        context.fill(CGRect(x: 90, y: 90, width: 460, height: 260))
        guard let image = context.makeImage() else {
            throw XCTSkip("Unable to create source image")
        }
        return try ImageEncoding.pngData(from: image)
    }
}

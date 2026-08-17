import AppKit
import CoreGraphics
import SwiftUI
import XCTest
import ScreenTraceCore
@testable import ScreenTraceMac

@MainActor
final class TraceLibraryViewTests: XCTestCase {
    func testLibraryViewLaysOutAndRendersWithMixedEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceLibraryViewTests-\(UUID().uuidString)", isDirectory: true)
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
            ocrText: "ScreenTrace launch checklist",
            insights: TraceInsightsDocument(
                engine: LocalTraceOrganizer.engineIdentifier,
                suggestedTitle: "Safari · 屏迹发布检查",
                summary: "检查本地发布流程、字幕与敏感信息提示。",
                tags: ["产品", "ScreenTrace", "发布"],
                keyPoints: ["确认所有媒体仍保存在本机"],
                sensitiveFindings: [
                    TraceSensitiveFinding(
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
        let model = TraceLibraryModel(
            store: TraceProjectStore(rootDirectory: root),
            initialEntries: [screenshot, recording]
        )
        let rootView = TraceLibraryView(
            model: model,
            onOpen: { _ in },
            onReveal: { _ in },
            onCopy: { _ in },
            onAnnotate: { _ in },
            onTranscribe: { _ in },
            onOrganize: { _ in },
            onSaveInsights: { _, _ in },
            onDelete: { _ in },
            onRepair: { _ in },
            onDeleteAll: {},
            onOpenFolder: {},
            onClose: {}
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

    func testInsightsPopoverRendersWrappedTagsChaptersAndPrivacyWarnings() throws {
        let insights = TraceInsightsDocument(
            engine: LocalTraceOrganizer.engineIdentifier,
            suggestedTitle: "屏迹本地发布与隐私检查",
            summary: "整理结果仅引用本机 OCR 与转写，并保留原始素材和分析来源。",
            tags: ["ScreenTrace", "产品", "发布", "隐私", "字幕", "macOS"],
            keyPoints: [
                "检查全部原始轨道仍然完整",
                "确认整理文件不复制敏感原值"
            ],
            chapters: [
                TraceChapter(
                    index: 0,
                    startSeconds: 0,
                    endSeconds: 42,
                    title: "产品目标",
                    summary: "说明快速捕获和本地优先原则。"
                ),
                TraceChapter(
                    index: 1,
                    startSeconds: 42,
                    endSeconds: 96,
                    title: "发布检查",
                    summary: "核对字幕、索引和隐私提醒。"
                )
            ],
            sensitiveFindings: [
                TraceSensitiveFinding(
                    kind: .credential,
                    source: .transcript,
                    startSeconds: 71,
                    endSeconds: 74,
                    redactedPreview: "api_key: ••••"
                )
            ],
            customization: TraceInsightsCustomization(
                title: "人工校正：屏迹发布检查",
                summary: "已核对本地处理、原始素材保护和隐私提示。",
                tags: ["已审阅", "隐私", "发布"]
            )
        )
        let rootView = TraceInsightsPopover(
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
        kind: TraceKind,
        title: String,
        assetURL: URL,
        state: TraceState,
        duration: Double?,
        ocrText: String?,
        insights: TraceInsightsDocument?
    ) -> TraceLibraryEntry {
        let id = UUID()
        let package = root.appendingPathComponent("\(id.uuidString).screentrace", isDirectory: true)
        let role: TraceAsset.Role = kind == .screenshot ? .screenshot : .screenVideo
        let manifest = TraceManifest(
            id: id,
            kind: kind,
            title: title,
            state: state,
            durationSeconds: duration,
            dimensions: TraceDimensions(width: 960, height: 540),
            captureSource: kind == .recording
                ? TraceCaptureMetadata(
                    mode: .window,
                    windowID: 12,
                    globalBounds: TraceRect(x: 80, y: 60, width: 960, height: 540),
                    windowTitle: "产品演示",
                    applicationName: "Safari"
                )
                : nil,
            assets: [TraceAsset(role: role, relativePath: assetURL.lastPathComponent)]
        )
        return TraceLibraryEntry(
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

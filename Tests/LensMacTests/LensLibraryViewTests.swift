import AppKit
import CoreGraphics
import SwiftUI
import XCTest
import LensCore
@testable import LensMac

@MainActor
final class LensLibraryViewTests: XCTestCase {
    func testLibraryThumbnailDecoderDownsamplesLargeSourceBeforeCaching() throws {
        let data = try screenshotPNGData(width: 4_096, height: 2_160)
        let image = try XCTUnwrap(
            LensThumbnailDecoder.image(from: data, maximumPixelSize: 640)
        )

        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 640)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

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
        // separate group that stays in the AX tree while collapsed, so
        // Tab/VoiceOver can still reach them when the pointer never hovers.
        XCTAssertTrue(source.contains("var showsSecondaryActions: Bool"))
        XCTAssertTrue(source.contains("isHovering || focusedSecondaryAction != nil"))
        XCTAssertTrue(source.contains(".frame(height: showsSecondaryActions ? nil : 1"))
        XCTAssertTrue(source.contains(".opacity(showsSecondaryActions ? 1 : 0.001)"))
        XCTAssertTrue(source.contains(".accessibilityHidden(false)"))
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

    func testLibraryStateBadgeUsesTheSharedDerivedDeliveryState() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/LensLibraryView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("QuickAccessDeliveryState.derived(for: SavedLens("))
        XCTAssertTrue(source.contains("case .needsReview: \"需复核\""))
        XCTAssertTrue(source.contains("case .ready: \"可交付\""))
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

    /// Cards carry optional summary, tag, and recovery rows, so their natural
    /// heights differ. Without both of these the grid rendered ragged: each
    /// card ended wherever its own content did and the action rows never lined
    /// up across a row.
    func testCardsShareARowHeightSoActionRowsStayAligned() throws {
        let source = try String(contentsOf: LensLibraryView.sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains(".frame(maxHeight: .infinity, alignment: .top)"),
            "cards must stretch to the grid row height rather than sit at their own"
        )
        XCTAssertTrue(
            source.contains("Spacer(minLength: 0)"),
            "the action row must be pushed to the card's bottom edge"
        )
    }

    /// A 210–270pt card cannot fit the timestamp plus every badge; before this
    /// the badges collided rather than truncating.
    func testMetadataRowDegradesInsteadOfOverflowingANarrowCard() throws {
        let source = try String(contentsOf: LensLibraryView.sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        for limit in ["badgeLimit: .max", "badgeLimit: 2", "badgeLimit: 1", "badgeLimit: 0"] {
            XCTAssertTrue(
                source.contains(limit),
                "\(limit) variant is missing, so the row loses a fallback step"
            )
        }
    }

    /// `scaledToFill` reports its cover size — preview height × image aspect —
    /// as the view's ideal width. Combined with the card's row-height stretch
    /// that width became the card's own: a wide screenshot inflated every card
    /// to ~311pt inside a 235.5pt grid cell, so cards overlapped their
    /// neighbours and painted badges, buttons, and previews across them.
    /// The card must stay inside the cell whatever the image's aspect is.
    func testWideScreenshotThumbnailKeepsItsCoverSizeOutOfLayout() throws {
        // 2010:543 ≈ 3.7 → at the 132pt preview height the old layout painted
        // 132 × 3.7 ≈ 489pt, straight past the cell it was offered.
        let image = try solidNSImage(width: 2_010, height: 543, color: (0.15, 0.25, 0.95))
        // The action row mirrors the card's real trailing row, including the
        // opacity-hidden secondary group: hidden actions reserve no layout
        // width, otherwise the row alone holds the card at ~290pt.
        let actionRow = HStack(spacing: 7) {
            Text("打开")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
            HStack(spacing: 7) {
                ForEach(["复制", "分享", "标注", "文字"], id: \.self) { title in
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                }
            }
            .frame(width: 0, alignment: .leading)
            .clipped()
            .opacity(0)
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
            Image(systemName: "folder")
            Image(systemName: "trash")
        }
        let card = VStack(alignment: .leading, spacing: 0) {
            LensLibraryThumbnailView(
                url: URL(fileURLWithPath: "/dev/null/unused.png"),
                previewImage: image
            )
            VStack(alignment: .leading, spacing: 7) {
                Text("宽图截图标题")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("2026年9月1日 4:28")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                actionRow
            }
            .padding(11)
        }
        .frame(maxHeight: .infinity, alignment: .top)

        let harness = card
            .frame(width: 235.5, alignment: .leading)
            .background(Color.red.opacity(0.999))
            .frame(width: 600, height: 300, alignment: .topLeading)
            .background(Color.black)

        let hostingView = NSHostingView(rootView: harness)
        hostingView.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw XCTSkip("Unable to create SwiftUI snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)

        let pointScale = CGFloat(representation.pixelsWide) / 600
        var lastRedPoint: CGFloat = 0
        for x in stride(from: 0, to: representation.pixelsWide, by: 2) {
            for y in stride(from: 0, to: representation.pixelsHigh, by: 4) {
                guard let color = representation.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB),
                    color.redComponent > 0.5,
                    color.redComponent > color.greenComponent + 0.2,
                    color.redComponent > color.blueComponent + 0.2
                else { continue }
                lastRedPoint = max(lastRedPoint, CGFloat(x) / pointScale)
                break
            }
        }

        XCTAssertGreaterThan(
            lastRedPoint,
            100,
            "Expected the card to render into the harness"
        )
        XCTAssertLessThanOrEqual(
            lastRedPoint,
            240,
            "The card laid out \(lastRedPoint)pt wide inside a 235.5pt cell — " +
            "the thumbnail's cover size leaked into layout and library cards " +
            "will overlap their neighbours."
        )
    }

    private func solidNSImage(
        width: Int,
        height: Int,
        color: (CGFloat, CGFloat, CGFloat)
    ) throws -> NSImage {
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
        context.setFillColor(
            CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            throw XCTSkip("Unable to create source image")
        }
        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: width, height: height)
        )
    }
}

private extension LensLibraryView {
    static var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LensMac/UI/LensLibraryView.swift")
    }
}

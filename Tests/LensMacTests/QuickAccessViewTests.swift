import AppKit
import LensCore
import XCTest
@testable import LensMac

@MainActor
final class QuickAccessViewTests: XCTestCase {
    func testFailureStateOffersAnExplicitRetryAction() throws {
        let source = try String(
            contentsOf: QuickAccessView.sourceURL,
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("isProcessingFailed"))
        XCTAssertTrue(source.contains("重试成片"))
        XCTAssertTrue(source.contains("onRetry"))
    }

    func testQuickAccessOffersNativeShareForARealDeliveryFile() throws {
        let source = try String(
            contentsOf: QuickAccessView.sourceURL,
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("onShare"))
        XCTAssertTrue(source.contains("square.and.arrow.up"))
        XCTAssertTrue(source.contains("dragFileURL != nil"))
        XCTAssertTrue(source.contains("不会自动上传"))
    }

    func testProcessingStateRendersDeterminateProgressNotAnIndefiniteSpinner() throws {
        let source = try String(
            contentsOf: QuickAccessView.sourceURL,
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@ObservedObject var progressModel: QuickAccessProgressModel"))
        XCTAssertTrue(source.contains("ProgressView(value: progressModel.fraction ?? 0)"))
        XCTAssertFalse(
            source.contains("ProgressView()\n"),
            "the processing indicator must carry a value instead of spinning indefinitely"
        )
        XCTAssertTrue(source.contains("progressCaption"))
        XCTAssertTrue(source.contains("约剩"), "an ETA must be shown once enough progress has landed")
        XCTAssertTrue(source.contains("final class QuickAccessProgressModel: ObservableObject"))
        XCTAssertTrue(source.contains("@Published var fraction: Double?"))
    }

    func testUnverifiedPreviewIsPresentedAsNeedsReview() throws {
        let source = try String(
            contentsOf: QuickAccessView.sourceURL,
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("isPreviewNeedsReview"))
        XCTAssertTrue(source.contains("建议打开编辑器复核"))
        // Asserts the state actually driving the banner. This previously named
        // `renderedPreviewRequiresReview`, a symbol that has never existed
        // anywhere in the repository (`git log -S` finds no commit adding or
        // removing it), so the assertion could only ever fail. The behaviour it
        // was meant to guard is real: AppDelegate maps an unverified render to
        // `.needsReview`, which is what `isPreviewNeedsReview` reads.
        XCTAssertTrue(source.contains("deliveryState == .needsReview"))
    }

    func testOneHundredScreenshotDeliveriesRemainReadableAndDraggable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccessStress-\(UUID().uuidString)", isDirectory: true)
        let store = LensProjectStore(rootDirectory: root)
        let png = try pngData(color: .systemTeal)
        let image = try XCTUnwrap(NSImage(data: png))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("LensTests.\(UUID().uuidString)")
        )
        var durations: [Double] = []
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }

        for index in 0..<100 {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let lens = try store.saveScreenshot(
                pngData: png,
                width: 12,
                height: 8,
                titlePrefix: "G1-\(index)"
            )
            let fileURL = try XCTUnwrap(QuickAccessFileTransfer.bestFileURL(for: lens))
            let provider = QuickAccessFileTransfer.itemProvider(
                fileURL: fileURL,
                suggestedName: QuickAccessFileTransfer.suggestedFileName(
                    for: lens,
                    fileURL: fileURL
                ),
                fallbackImage: image
            )

            XCTAssertTrue(ImageClipboardWriter.write(image, to: pasteboard))
            XCTAssertNotNil(pasteboard.availableType(from: [.png, .tiff]))
            XCTAssertEqual(try Data(contentsOf: fileURL), png)
            XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.png"))
            durations.append((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        }

        let sorted = durations.sorted()
        let p95 = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
        XCTAssertLessThan(p95, 250, "100-cycle local delivery P95 regressed to \(p95) ms")
    }

    func testClipboardSuccessRequiresDiscoverableImageRepresentation() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("LensTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let image = try XCTUnwrap(NSImage(data: pngData(color: .systemOrange)))

        XCTAssertTrue(ImageClipboardWriter.write(image, to: pasteboard))
        XCTAssertNotNil(pasteboard.availableType(from: [.png, .tiff]))
    }

    func testFileTransferPrefersRenderedScreenshotAndAdvertisesRealPNGFile() throws {
        let fixture = try makeLens(
            renderedRelativePath: "previews/annotated.png",
            createRenderedFile: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.lens.packageURL) }

        let fileURL = try XCTUnwrap(QuickAccessFileTransfer.bestFileURL(for: fixture.lens))
        let suggestedName = QuickAccessFileTransfer.suggestedFileName(
            for: fixture.lens,
            fileURL: fileURL
        )
        let provider = QuickAccessFileTransfer.itemProvider(
            fileURL: fileURL,
            suggestedName: suggestedName,
            fallbackImage: NSImage(size: CGSize(width: 4, height: 4))
        )

        XCTAssertEqual(fileURL, fixture.lens.packageURL.appendingPathComponent("previews/annotated.png"))
        XCTAssertTrue(suggestedName.hasPrefix("Lens-"))
        XCTAssertTrue(suggestedName.hasSuffix(".png"))
        XCTAssertFalse(suggestedName.contains("/"))
        XCTAssertEqual(provider.suggestedName, suggestedName)
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.png"))
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.file-url"))
    }

    func testFileTransferFallsBackToRawScreenshotWhenRenderedAssetIsMissing() throws {
        let fixture = try makeLens(
            renderedRelativePath: "previews/missing.png",
            createRenderedFile: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.lens.packageURL) }

        XCTAssertEqual(
            QuickAccessFileTransfer.bestFileURL(for: fixture.lens),
            fixture.lens.rawAssetURL
        )
    }

    func testFileTransferRejectsManifestPathOutsideLensPackage() throws {
        let fixture = try makeLens(
            renderedRelativePath: "../../outside.png",
            createRenderedFile: false
        )
        let outsideURL = fixture.lens.packageURL
            .deletingLastPathComponent()
            .appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outsideURL)
        defer {
            try? FileManager.default.removeItem(at: fixture.lens.packageURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        XCTAssertEqual(
            QuickAccessFileTransfer.bestFileURL(for: fixture.lens),
            fixture.lens.rawAssetURL
        )
    }

    func testFileTransferPrefersRenderedRecordingForShareableDelivery() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccessRecording-\(UUID().uuidString).lens", isDirectory: true)
        let rawURL = packageURL.appendingPathComponent("raw/screen.mp4")
        let renderedURL = packageURL.appendingPathComponent("previews/share.mp4")
        let healthURL = packageURL.appendingPathComponent("diagnostics/recording-health.json")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: healthURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: rawURL)
        try Data("share".utf8).write(to: renderedURL)
        let verification = RenderedEffectVerificationReport(
            previewPlayable: true,
            previewDurationSeconds: 12,
            rawMeasuredFramesPerSecond: 60,
            previewMeasuredFramesPerSecond: 60,
            minimumExpectedFramesPerSecond: 58,
            effects: []
        )
        let health = RecordingHealthReport(
            requestedFramesPerSecond: 60,
            measuredFramesPerSecond: 60,
            p95FrameIntervalMilliseconds: 16.7,
            droppedFrameCount: 0,
            videoStatus: .healthy,
            eventStatus: .healthy,
            pointerEventCount: 0,
            clickEventCount: 0,
            keyboardEventCount: 0,
            windowEventCount: 0,
            effectiveCameraKeyframeCount: 0,
            cursorKeyframeCount: 0,
            clickPulseCount: 0,
            renderedEffectVerification: verification,
            warnings: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(health).write(to: healthURL)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let lens = SavedLens(
            packageURL: packageURL,
            rawAssetURL: rawURL,
            manifest: LensManifest(
                kind: .recording,
                title: "演示录屏",
                durationSeconds: 12,
                dimensions: LensDimensions(width: 1280, height: 720),
                assets: [
                    LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                    LensAsset(role: .renderedVideo, relativePath: "previews/share.mp4"),
                    LensAsset(role: .recordingHealth, relativePath: "diagnostics/recording-health.json")
                ]
            )
        )

        XCTAssertEqual(QuickAccessFileTransfer.bestFileURL(for: lens), renderedURL)
        XCTAssertTrue(
            QuickAccessFileTransfer.suggestedFileName(for: lens, fileURL: renderedURL)
                .hasSuffix(".mp4")
        )
    }

    func testProcessingRecordingSharesDurableRawFileInsteadOfStalePreview() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccessProcessingRecording-\(UUID().uuidString).lens", isDirectory: true)
        let rawURL = packageURL.appendingPathComponent("raw/screen.mp4")
        let renderedURL = packageURL.appendingPathComponent("previews/old.mp4")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: rawURL)
        try Data("old preview".utf8).write(to: renderedURL)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let lens = SavedLens(
            packageURL: packageURL,
            rawAssetURL: rawURL,
            manifest: LensManifest(
                kind: .recording,
                title: "处理中录屏",
                state: .processing,
                dimensions: LensDimensions(width: 16, height: 9),
                assets: [
                    LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                    LensAsset(role: .renderedVideo, relativePath: "previews/old.mp4")
                ]
            )
        )

        XCTAssertEqual(QuickAccessFileTransfer.bestFileURL(for: lens), rawURL)
    }

    func testUnverifiedRenderedRecordingSharesRawFileInstead() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccessUnverifiedRecording-\(UUID().uuidString).lens", isDirectory: true)
        let rawURL = packageURL.appendingPathComponent("raw/screen.mp4")
        let renderedURL = packageURL.appendingPathComponent("previews/unverified.mp4")
        let healthURL = packageURL.appendingPathComponent("diagnostics/recording-health.json")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: healthURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: rawURL)
        try Data("unverified preview".utf8).write(to: renderedURL)

        let verification = RenderedEffectVerificationReport(
            previewPlayable: true,
            previewDurationSeconds: 2,
            rawMeasuredFramesPerSecond: 60,
            previewMeasuredFramesPerSecond: 60,
            minimumExpectedFramesPerSecond: 58,
            effects: [
                RenderedEffectVerification(effect: .automaticCamera, state: .failed)
            ]
        )
        let health = RecordingHealthReport(
            requestedFramesPerSecond: 60,
            measuredFramesPerSecond: 60,
            p95FrameIntervalMilliseconds: 16.7,
            droppedFrameCount: 0,
            videoStatus: .healthy,
            eventStatus: .healthy,
            pointerEventCount: 0,
            clickEventCount: 0,
            keyboardEventCount: 0,
            windowEventCount: 0,
            effectiveCameraKeyframeCount: 1,
            cursorKeyframeCount: 0,
            clickPulseCount: 0,
            renderedEffectVerification: verification,
            warnings: [.renderedEffectNotVerified]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(health).write(to: healthURL)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let lens = SavedLens(
            packageURL: packageURL,
            rawAssetURL: rawURL,
            manifest: LensManifest(
                kind: .recording,
                title: "待复核录屏",
                state: .ready,
                durationSeconds: 2,
                dimensions: LensDimensions(width: 16, height: 9),
                assets: [
                    LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                    LensAsset(role: .renderedVideo, relativePath: "previews/unverified.mp4"),
                    LensAsset(role: .recordingHealth, relativePath: "diagnostics/recording-health.json")
                ]
            )
        )

        XCTAssertEqual(QuickAccessFileTransfer.bestFileURL(for: lens), rawURL)
    }

    func testLegacyRecordingWithoutHealthReportSharesRawFileAndNeedsReview() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccessLegacyRecording-\(UUID().uuidString).lens", isDirectory: true)
        let rawURL = packageURL.appendingPathComponent("raw/screen.mp4")
        let renderedURL = packageURL.appendingPathComponent("previews/legacy.mp4")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: rawURL)
        try Data("legacy preview".utf8).write(to: renderedURL)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let lens = SavedLens(
            packageURL: packageURL,
            rawAssetURL: rawURL,
            manifest: LensManifest(
                kind: .recording,
                title: "旧项目录屏",
                state: .ready,
                dimensions: LensDimensions(width: 16, height: 9),
                assets: [
                    LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                    LensAsset(role: .renderedVideo, relativePath: "previews/legacy.mp4")
                ]
            )
        )

        XCTAssertTrue(QuickAccessFileTransfer.previewNeedsReview(for: lens))
        XCTAssertEqual(QuickAccessFileTransfer.bestFileURL(for: lens), rawURL)
    }

    func testFileProviderMaterializesTheRenderedPNGBytes() async throws {
        let fixture = try makeLens(
            renderedRelativePath: "previews/annotated.png",
            createRenderedFile: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.lens.packageURL) }
        let fileURL = try XCTUnwrap(QuickAccessFileTransfer.bestFileURL(for: fixture.lens))
        let expected = try Data(contentsOf: fileURL)
        let provider = QuickAccessFileTransfer.itemProvider(
            fileURL: fileURL,
            suggestedName: "Lens-E2.png",
            fallbackImage: NSImage(size: CGSize(width: 4, height: 4))
        )

        let transferred = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: "public.png") { url, error in
                do {
                    if let error { throw error }
                    let url = try XCTUnwrap(url)
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(transferred, expected)
        XCTAssertNotNil(NSImage(data: transferred))
    }

    private func makeLens(
        renderedRelativePath: String,
        createRenderedFile: Bool
    ) throws -> (lens: SavedLens, rawURL: URL) {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccess-\(UUID().uuidString).lens", isDirectory: true)
        let rawURL = packageURL.appendingPathComponent("raw/screenshot.png")
        try FileManager.default.createDirectory(
            at: rawURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData(color: .cyan).write(to: rawURL)

        if createRenderedFile {
            let renderedURL = packageURL.appendingPathComponent(renderedRelativePath)
            try FileManager.default.createDirectory(
                at: renderedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData(color: .systemOrange).write(to: renderedURL)
        }

        let lens = SavedLens(
            packageURL: packageURL,
            rawAssetURL: rawURL,
            manifest: LensManifest(
                kind: .screenshot,
                title: "Quick Access",
                dimensions: LensDimensions(width: 320, height: 180),
                assets: [
                    LensAsset(role: .screenshot, relativePath: "raw/screenshot.png"),
                    LensAsset(role: .renderedScreenshot, relativePath: renderedRelativePath)
                ]
            )
        )
        return (lens, rawURL)
    }

    private func pngData(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    // MARK: - Recent-captures stack (P7c)

    private func makeStackLens(title: String) -> SavedLens {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccessStack-\(UUID().uuidString).lens", isDirectory: true)
        return SavedLens(
            packageURL: packageURL,
            rawAssetURL: packageURL.appendingPathComponent("raw/screenshot.png"),
            manifest: LensManifest(
                kind: .screenshot,
                title: title,
                dimensions: LensDimensions(width: 320, height: 180),
                assets: [LensAsset(role: .screenshot, relativePath: "raw/screenshot.png")]
            )
        )
    }

    private func makeTinyImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        return image
    }

    func testStackTracksUpToFiveCapturesMostRecentFirst() {
        let model = QuickAccessStackModel()
        let lenses = (0..<5).map { makeStackLens(title: "Capture \($0)") }
        for lens in lenses {
            _ = model.upsert(QuickAccessStackEntry(
                lens: lens,
                thumbnail: makeTinyImage(),
                confirmationTitle: "截图已复制",
                deliveryState: .ready
            ))
        }
        XCTAssertEqual(model.entries.count, 5)
        XCTAssertEqual(model.entries.map(\.id), lenses.reversed().map(\.manifest.id))
    }

    func testStackTrimsOldestEntryPastCapacity() {
        let model = QuickAccessStackModel()
        let lenses = (0..<6).map { makeStackLens(title: "Capture \($0)") }
        for lens in lenses {
            _ = model.upsert(QuickAccessStackEntry(
                lens: lens,
                thumbnail: makeTinyImage(),
                confirmationTitle: "截图已复制",
                deliveryState: .ready
            ))
        }
        XCTAssertEqual(model.entries.count, 5, "capacity must stay at 5")
        XCTAssertFalse(
            model.entries.contains { $0.id == lenses[0].manifest.id },
            "the oldest capture must be the one evicted"
        )
        for lens in lenses.dropFirst() {
            XCTAssertTrue(model.entries.contains { $0.id == lens.manifest.id })
        }
    }

    func testUpdatingAnExistingEntryDoesNotReorderOrGrowTheStack() {
        let model = QuickAccessStackModel()
        let first = makeStackLens(title: "First")
        let second = makeStackLens(title: "Second")
        _ = model.upsert(QuickAccessStackEntry(
            lens: first,
            thumbnail: makeTinyImage(),
            confirmationTitle: "截图已复制",
            deliveryState: .ready
        ))
        _ = model.upsert(QuickAccessStackEntry(
            lens: second,
            thumbnail: makeTinyImage(),
            confirmationTitle: "截图已复制",
            deliveryState: .ready
        ))
        XCTAssertEqual(model.entries.map(\.id), [second.manifest.id, first.manifest.id])

        // A recording finishing its render is a state update to an existing
        // entry, not a new capture — it must not jump back to the front or
        // grow the stack, only refresh its own row in place.
        let isNewCapture = model.upsert(QuickAccessStackEntry(
            lens: first,
            thumbnail: makeTinyImage(),
            confirmationTitle: "成片已可发送",
            deliveryState: .needsReview
        ))

        XCTAssertFalse(isNewCapture)
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertEqual(model.entries.map(\.id), [second.manifest.id, first.manifest.id])
        XCTAssertEqual(model.entries.last?.confirmationTitle, "成片已可发送")
        XCTAssertEqual(model.entries.last?.deliveryState, .needsReview)
    }

    func testRemovingAnEntryReportsWhetherTheStackBecameEmpty() {
        let model = QuickAccessStackModel()
        let first = makeStackLens(title: "First")
        let second = makeStackLens(title: "Second")
        _ = model.upsert(QuickAccessStackEntry(
            lens: first,
            thumbnail: makeTinyImage(),
            confirmationTitle: "截图已复制",
            deliveryState: .ready
        ))
        _ = model.upsert(QuickAccessStackEntry(
            lens: second,
            thumbnail: makeTinyImage(),
            confirmationTitle: "截图已复制",
            deliveryState: .ready
        ))

        XCTAssertFalse(model.remove(id: second.manifest.id))
        XCTAssertEqual(model.entries.map(\.id), [first.manifest.id])
        XCTAssertTrue(model.remove(id: first.manifest.id))
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testExpandedStackPausesAutoDismissAndCollapseRestartsIt() async throws {
        // Forces `hide()`'s dismiss to be instant rather than a real ~130ms
        // fade, so this test only has to account for the (overridden, short)
        // countdown duration itself.
        LensPanelPresenter.reduceMotionOverride = true
        QuickAccessWindowController.dismissDurationOverride = .milliseconds(30)
        defer {
            LensPanelPresenter.reduceMotionOverride = nil
            QuickAccessWindowController.dismissDurationOverride = nil
        }
        let controller = QuickAccessWindowController()
        let primary = makeStackLens(title: "Primary")
        let older = makeStackLens(title: "Older")
        controller.show(lens: older, image: makeTinyImage())
        controller.show(lens: primary, image: makeTinyImage())
        XCTAssertTrue(controller.isVisible)

        controller.setStackExpandedForTesting(true)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertTrue(
            controller.isVisible,
            "an expanded stack must not auto-dismiss out from under the user"
        )

        controller.setStackExpandedForTesting(false)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(
            controller.isVisible,
            "collapsing must restart the countdown so the panel still auto-dismisses"
        )
    }

    func testEachStackedEntryProvidesAnIndependentDragItemProvider() throws {
        let source = try String(contentsOf: QuickAccessView.sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("private func stackedEntryThumbnail"))
        // The per-row `.onDrag` closure must be built from that row's own
        // `entry`, not a fixed/shared reference — otherwise every stacked
        // row would silently drag the same (likely primary) capture.
        XCTAssertTrue(source.contains("if let fileURL = QuickAccessFileTransfer.bestFileURL(for: entry.lens)"))
        XCTAssertTrue(source.contains("fallbackImage: entry.thumbnail"))
    }
}

private extension QuickAccessView {
    static var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LensMac/UI/QuickAccessView.swift")
    }
}

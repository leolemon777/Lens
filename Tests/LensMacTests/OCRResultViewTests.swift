import AppKit
import LensCore
import SwiftUI
import XCTest
@testable import LensMac

@MainActor
final class OCRResultViewTests: XCTestCase {
    // Several tests below assert a panel's presence/absence in `NSApp.windows`
    // right after calling into the controller. LensPanelPresenter's animated
    // dismiss only orders the window out after a short fade, which races
    // with those synchronous assertions (and with the next test's own
    // windows, since `NSApp.windows` is process-global). Forcing the
    // reduced-motion path makes dismiss synchronous again for this file,
    // matching what these tests were actually written to verify.
    override func setUp() {
        super.setUp()
        LensPanelPresenter.reduceMotionOverride = true
    }

    override func tearDown() {
        LensPanelPresenter.reduceMotionOverride = nil
        super.tearDown()
    }

    func testCopyUsesEditedTextInsteadOfOriginalRecognition() {
        let model = OCRResultModel(document: makeDocument("识别原文"), thumbnail: nil)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.isEdited)
        XCTAssertTrue(model.hasText)

        model.editedText = "改过的识别结果"
        XCTAssertTrue(model.isEdited)

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("LensTests.OCRModel.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(model.copy(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "改过的识别结果")
        XCTAssertNil(pasteboard.availableType(from: [.png, .tiff]))
    }

    func testResetRestoresOriginalRecognitionAndBlankEditsAreNotCopyable() {
        let model = OCRResultModel(document: makeDocument("第一行"), thumbnail: nil)
        model.editedText = " \n "
        XCTAssertTrue(model.isEdited)
        XCTAssertFalse(model.hasText)

        model.reset()
        XCTAssertEqual(model.editedText, "第一行")
        XCTAssertFalse(model.isEdited)
        XCTAssertTrue(model.hasText)
    }

    func testRecognizingModelCannotCopyUntilDocumentArrives() {
        let thumbnail = NSImage(size: NSSize(width: 8, height: 8))
        let model = OCRResultModel(recognizing: thumbnail)
        XCTAssertEqual(model.phase, .recognizing)
        XCTAssertFalse(model.hasText)
        XCTAssertTrue(model.thumbnail === thumbnail)

        model.apply(makeDocument("识别完成"))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.editedText, "识别完成")
        XCTAssertTrue(model.hasText)
        XCTAssertTrue(model.thumbnail === thumbnail)
    }

    func testResultCardRendersEditableTextWithoutCopyingAutomatically() throws {
        let model = OCRResultModel(document: makeDocument("可编辑的识别文字"), thumbnail: nil)
        var copyCount = 0
        var copyAndCloseCount = 0
        let hostingView = NSHostingView(rootView: OCRResultView(
            model: model,
            onCopy: { copyCount += 1 },
            onCopyAndClose: { copyAndCloseCount += 1 },
            onClose: {}
        ))
        hostingView.frame = CGRect(x: 0, y: 0, width: 464, height: 364)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(copyCount, 0)
        XCTAssertEqual(copyAndCloseCount, 0)
        XCTAssertEqual(model.editedText, "可编辑的识别文字")
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.width, 420)
    }

    func testCopyAndCloseUsesCommandReturnInsteadOfPlainReturn() throws {
        let source = try String(
            contentsOf: OCRResultView.sourceURL,
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("onCopyAndClose"))
        XCTAssertTrue(source.contains("keyboardShortcut(.return, modifiers: .command)"))
        XCTAssertFalse(
            source.contains("keyboardShortcut(.return, modifiers: [])"),
            "Return must keep inserting newlines in the editor"
        )
        XCTAssertFalse(
            source.contains("keyboardShortcut(.defaultAction)"),
            "Default Return would steal newlines from TextEditor"
        )
    }

    func testFloatingResultPanelBecomesKeyAndEscapeClosesIt() {
        let controller = OCRResultWindowController()
        defer { controller.closeAll() }
        controller.show(document: makeDocument("浮层文字"), thumbnail: nil)

        XCTAssertTrue(controller.hasVisibleResults)
        let panel = panelLabeled("OCR 识别结果")
        XCTAssertNotNil(panel)
        XCTAssertTrue(panel?.canBecomeKey == true)

        panel?.cancelOperation(nil)
        XCTAssertFalse(controller.hasVisibleResults)
    }

    func testRecognizingPanelKeepsTheProvidedThumbnailAndFillsInTextLater() {
        let controller = OCRResultWindowController()
        defer { controller.closeAll() }
        let lensID = UUID()
        let thumbnail = NSImage(size: NSSize(width: 12, height: 9))

        controller.beginRecognizing(lensID: lensID, thumbnail: thumbnail)
        XCTAssertTrue(controller.hasVisibleResults)
        XCTAssertNotNil(panelLabeled("OCR 正在识别"))

        XCTAssertEqual(
            controller.fulfill(lensID: lensID, document: makeDocument("后来的文字")),
            .ready
        )
        XCTAssertTrue(controller.hasVisibleResults)
        XCTAssertNotNil(panelLabeled("OCR 识别结果"))
        XCTAssertNil(panelLabeled("OCR 正在识别"))
        XCTAssertTrue(controller.thumbnail(for: lensID) === thumbnail)
    }

    func testEmptyRecognitionClosesTheWaitingPanel() {
        let controller = OCRResultWindowController()
        defer { controller.closeAll() }
        let lensID = UUID()
        controller.beginRecognizing(lensID: lensID, thumbnail: nil)

        XCTAssertEqual(
            controller.fulfill(lensID: lensID, document: makeDocument("  \n ")),
            .empty
        )
        XCTAssertFalse(controller.hasVisibleResults)
    }

    func testClosingTheWaitingPanelDismissesTheLaterResult() {
        let controller = OCRResultWindowController()
        defer { controller.closeAll() }
        let lensID = UUID()
        controller.beginRecognizing(lensID: lensID, thumbnail: nil)
        controller.closeAll()

        XCTAssertEqual(
            controller.fulfill(lensID: lensID, document: makeDocument("不该再弹出")),
            .dismissed
        )
        XCTAssertFalse(controller.hasVisibleResults)
    }

    func testFailedRecognitionClosesTheWaitingPanel() {
        let controller = OCRResultWindowController()
        defer { controller.closeAll() }
        let lensID = UUID()
        controller.beginRecognizing(lensID: lensID, thumbnail: nil)
        controller.fail(lensID: lensID)
        XCTAssertFalse(controller.hasVisibleResults)
    }

    private func panelLabeled(_ label: String) -> NSWindow? {
        NSApp.windows.first { $0.accessibilityLabel() == label }
    }

    private func makeDocument(_ text: String) -> OCRDocument {
        OCRDocument(
            engine: "test",
            recognitionLanguages: ["zh-Hans"],
            fullText: text,
            blocks: [
                OCRTextBlock(
                    text: text,
                    confidence: 0.9,
                    normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 1)
                )
            ]
        )
    }
}

private extension OCRResultView {
    static var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LensMac/UI/OCRResultView.swift")
    }
}

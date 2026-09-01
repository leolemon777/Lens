import AppKit
import LensCore

struct PinnedImagePresentation: Equatable {
    static let minimumOpacity: CGFloat = 0.4

    let imageSize: CGSize
    let fittedScale: CGFloat
    var scale: CGFloat
    var opacity: CGFloat = 1
    var isPositionLocked = false
    var isClickThrough = false

    init(imageSize: CGSize, maximumInitialSize: CGSize) {
        self.imageSize = CGSize(
            width: max(imageSize.width, 1),
            height: max(imageSize.height, 1)
        )
        fittedScale = min(
            maximumInitialSize.width / self.imageSize.width,
            maximumInitialSize.height / self.imageSize.height,
            1
        )
        scale = fittedScale
    }

    var windowSize: CGSize {
        CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    var minimumScale: CGFloat {
        max(fittedScale * 0.4, 0.01)
    }

    var maximumScale: CGFloat {
        min(max(fittedScale * 4, fittedScale), 3)
    }

    mutating func zoom(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        scale = min(max(scale * factor, minimumScale), maximumScale)
    }

    mutating func resetScale() {
        scale = fittedScale
    }

    mutating func setOpacity(_ value: CGFloat) {
        guard value.isFinite else { return }
        opacity = min(max(value, Self.minimumOpacity), 1)
    }

    mutating func cycleOpacity() {
        let levels: [CGFloat] = [1, 0.8, 0.6, 0.4]
        let currentIndex = levels.firstIndex { abs($0 - opacity) < 0.01 } ?? 0
        opacity = levels[(currentIndex + 1) % levels.count]
    }

    /// Trackpad pixel deltas are large; mouse wheels report one notch as ±1.
    mutating func applyScroll(
        deltaY: CGFloat,
        isPrecise: Bool,
        adjustsOpacity: Bool
    ) {
        guard deltaY.isFinite, deltaY != 0 else { return }
        if adjustsOpacity {
            let delta = isPrecise ? deltaY / 350 : deltaY * 0.08
            setOpacity(opacity + delta)
            return
        }
        let steps = isPrecise ? deltaY / 70 : deltaY
        zoom(by: pow(1.1, steps))
    }

    mutating func applyMagnification(_ magnification: CGFloat) {
        guard magnification.isFinite, magnification != 0 else { return }
        zoom(by: 1 + magnification)
    }

    static func scrollAdjustsOpacity(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.control) || flags.contains(.option)
    }

    /// Click-through dims a fully opaque pin so the window below stays readable.
    var displayedOpacity: CGFloat {
        isClickThrough ? min(opacity, 0.6) : opacity
    }
}

struct PinnedImageSource {
    let title: String
    let lens: SavedLens?

    static func project(_ lens: SavedLens) -> PinnedImageSource {
        PinnedImageSource(title: lens.manifest.title, lens: lens)
    }

    static func clipboard(title: String) -> PinnedImageSource {
        PinnedImageSource(title: title, lens: nil)
    }
}

@MainActor
final class PinnedImageWindowController {
    private var windows: [PinnedImageWindow] = []
    var onCopyResult: ((Bool) -> Void)?
    private(set) var areHidden = false

    var hasPins: Bool { !windows.isEmpty }

    @discardableResult
    func pinClipboard(from pasteboard: NSPasteboard = .general) -> Bool {
        guard let item = PinnedClipboardReader.read(from: pasteboard) else { return false }
        pin(image: item.image, source: .clipboard(title: item.title))
        return true
    }

    func pin(lens: SavedLens, image: NSImage) {
        pin(image: image, source: .project(lens))
    }

    func hideAll() {
        guard hasPins else { return }
        areHidden = true
        windows.forEach { $0.setGroupHidden(true) }
    }

    func showAll() {
        areHidden = false
        windows.forEach { $0.setGroupHidden(false) }
    }

    func toggleHidden() {
        if areHidden {
            showAll()
        } else {
            hideAll()
        }
    }

    func closeAll() {
        let snapshot = windows
        snapshot.forEach { $0.closePinnedImage() }
    }

    private func pin(image: NSImage, source: PinnedImageSource) {
        if areHidden {
            showAll()
        }
        let window = PinnedImageWindow(
            image: image,
            source: source,
            maximumInitialSize: CGSize(width: 520, height: 420)
        )
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            windows.removeAll { $0 === window }
            if windows.isEmpty {
                areHidden = false
            }
        }
        window.onCopyResult = { [weak self] in self?.onCopyResult?($0) }
        windows.append(window)
        window.center()
        window.setFrameOrigin(Self.cascadedOrigin(
            centeredFrame: window.frame,
            pinIndex: windows.count - 1,
            visibleFrame: (window.screen ?? NSScreen.main)?.visibleFrame
        ))
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Offsets each new pin from the centred position so stacked pins stay
    /// individually grabbable, then keeps the result on screen.
    ///
    /// The offset wraps rather than growing without bound: pinning many images
    /// previously marched them off the bottom-right corner, where they could
    /// no longer be seen or closed.
    static func cascadedOrigin(
        centeredFrame: CGRect,
        pinIndex: Int,
        visibleFrame: CGRect?,
        step: CGFloat = 28
    ) -> CGPoint {
        guard pinIndex > 0 else { return centeredFrame.origin }
        guard let visibleFrame, visibleFrame.width > 0, visibleFrame.height > 0 else {
            return CGPoint(
                x: centeredFrame.minX + CGFloat(pinIndex) * step,
                y: centeredFrame.minY - CGFloat(pinIndex) * step
            )
        }

        // Wrap before the cascade can leave the usable area, so a long session
        // of pinning cycles back over the centre instead of escaping the screen.
        let slack = max(
            0,
            min(
                visibleFrame.maxX - centeredFrame.maxX,
                centeredFrame.minY - visibleFrame.minY
            )
        )
        let stepsBeforeWrap = max(1, Int(slack / step))
        let offset = CGFloat(pinIndex % (stepsBeforeWrap + 1)) * step

        return CGPoint(
            x: min(
                max(centeredFrame.minX + offset, visibleFrame.minX),
                max(visibleFrame.minX, visibleFrame.maxX - centeredFrame.width)
            ),
            y: min(
                max(centeredFrame.minY - offset, visibleFrame.minY),
                max(visibleFrame.minY, visibleFrame.maxY - centeredFrame.height)
            )
        )
    }
}

@MainActor
final class PinnedImageWindow: NSWindow, NSMenuDelegate {
    private enum MenuTag {
        static let opacityBase = 2_000
        static let lockPosition = 3_000
        static let clickThrough = 3_001
    }

    var onClose: (() -> Void)?
    var onCopyResult: ((Bool) -> Void)?

    private let source: PinnedImageSource
    private let pinnedContentView: PinnedImageContentView
    private var presentation: PinnedImagePresentation
    private var clickThroughBadge: PinnedClickThroughBadgeWindow?
    private var ownedDragFileURL: URL?

    convenience init(image: NSImage, lens: SavedLens, maximumInitialSize: CGSize) {
        self.init(image: image, source: .project(lens), maximumInitialSize: maximumInitialSize)
    }

    init(image: NSImage, source: PinnedImageSource, maximumInitialSize: CGSize) {
        self.source = source
        presentation = PinnedImagePresentation(
            imageSize: image.size,
            maximumInitialSize: maximumInitialSize
        )
        pinnedContentView = PinnedImageContentView(
            frame: CGRect(origin: .zero, size: presentation.windowSize),
            image: image
        )

        super.init(
            contentRect: CGRect(origin: .zero, size: presentation.windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        contentView = pinnedContentView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        title = source.title
        setAccessibilityLabel("贴图：\(source.title)")
        minSize = CGSize(
            width: presentation.imageSize.width * presentation.minimumScale,
            height: presentation.imageSize.height * presentation.minimumScale
        )
        maxSize = CGSize(
            width: presentation.imageSize.width * presentation.maximumScale,
            height: presentation.imageSize.height * presentation.maximumScale
        )
        configureToolbar()
        configureContextMenu()
        applyPresentation(resizing: false)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if presentation.isClickThrough {
                toggleClickThrough()
            } else {
                closePinnedImage()
            }
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "c": copyImage()
            case "+", "=": zoomIn()
            case "-": zoomOut()
            case "0": resetSize()
            case "w": closePinnedImage()
            default: super.keyDown(with: event)
            }
            return
        }
        super.keyDown(with: event)
    }

    @objc private func copyImage() {
        let copied = ImageClipboardWriter.write(pinnedContentView.image)
        pinnedContentView.showConfirmation(
            symbol: copied ? "checkmark" : "exclamationmark"
        )
        onCopyResult?(copied)
    }

    @objc private func zoomIn() {
        presentation.zoom(by: 1.2)
        applyPresentation(resizing: true)
    }

    @objc private func zoomOut() {
        presentation.zoom(by: 1 / 1.2)
        applyPresentation(resizing: true)
    }

    @objc private func resetSize() {
        presentation.resetScale()
        applyPresentation(resizing: true, animated: true)
    }

    func resetSizeAndOpacity() {
        presentation.resetScale()
        presentation.setOpacity(1)
        applyPresentation(resizing: true, animated: true)
    }

    func applyScroll(
        deltaY: CGFloat,
        isPrecise: Bool,
        modifiers: NSEvent.ModifierFlags
    ) {
        let previousSize = presentation.windowSize
        presentation.applyScroll(
            deltaY: deltaY,
            isPrecise: isPrecise,
            adjustsOpacity: PinnedImagePresentation.scrollAdjustsOpacity(modifiers)
        )
        applyPresentation(
            resizing: presentation.windowSize != previousSize,
            animated: false
        )
    }

    func applyMagnification(_ magnification: CGFloat) {
        let previousSize = presentation.windowSize
        presentation.applyMagnification(magnification)
        applyPresentation(
            resizing: presentation.windowSize != previousSize,
            animated: false
        )
    }

    @objc private func cycleOpacity() {
        presentation.cycleOpacity()
        applyPresentation(resizing: false)
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        presentation.setOpacity(CGFloat(sender.tag - MenuTag.opacityBase) / 100)
        applyPresentation(resizing: false)
    }

    @objc private func togglePositionLock() {
        presentation.isPositionLocked.toggle()
        applyPresentation(resizing: false)
    }

    @objc private func toggleClickThrough() {
        presentation.isClickThrough.toggle()
        applyPresentation(resizing: false)
    }

    @objc private func revealProject() {
        guard let packageURL = source.lens?.packageURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([packageURL])
    }

    @objc func closePinnedImage() {
        clickThroughBadge?.orderOut(nil)
        clickThroughBadge = nil
        if let ownedDragFileURL {
            try? FileManager.default.removeItem(at: ownedDragFileURL)
            self.ownedDragFileURL = nil
        }
        orderOut(nil)
        onClose?()
    }

    func setGroupHidden(_ hidden: Bool) {
        if hidden {
            clickThroughBadge?.orderOut(nil)
            orderOut(nil)
        } else {
            orderFrontRegardless()
            updateClickThroughBadge()
        }
    }

    static func shouldBeginFileDrag(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        // Control+click is the macOS context-menu chord, so it cannot also start a drag.
        return flags.contains(.command) || flags.contains(.option)
    }

    func fileURLForDragging() -> URL? {
        if let lens = source.lens,
           let url = QuickAccessFileTransfer.bestFileURL(for: lens) {
            return url
        }
        if let ownedDragFileURL,
           FileManager.default.fileExists(atPath: ownedDragFileURL.path) {
            return ownedDragFileURL
        }
        guard let tiff = pinnedContentView.image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lens-Pin-\(UUID().uuidString).png")
        do {
            try png.write(to: url, options: .atomic)
            ownedDragFileURL = url
            return url
        } catch {
            return nil
        }
    }

    func beginFileDrag(with event: NSEvent) {
        guard let url = fileURLForDragging() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(pinnedContentView.bounds, contents: pinnedContentView.image)
        pinnedContentView.beginDraggingSession(with: [item], event: event, source: pinnedContentView)
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            if item.tag == MenuTag.lockPosition {
                item.state = presentation.isPositionLocked ? .on : .off
            } else if item.tag == MenuTag.clickThrough {
                item.state = presentation.isClickThrough ? .on : .off
            } else if item.tag >= MenuTag.opacityBase,
                      item.tag <= MenuTag.opacityBase + 100 {
                let itemOpacity = CGFloat(item.tag - MenuTag.opacityBase) / 100
                item.state = abs(itemOpacity - presentation.opacity) < 0.01 ? .on : .off
            }
        }
    }

    func setControlsVisible(_ visible: Bool) {
        pinnedContentView.setToolbarVisible(visible, animated: false)
    }

    func applyPresentation(resizing: Bool, animated: Bool = true) {
        if resizing {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let nextSize = presentation.windowSize
            setFrame(
                CGRect(
                    x: center.x - nextSize.width / 2,
                    y: center.y - nextSize.height / 2,
                    width: nextSize.width,
                    height: nextSize.height
                ),
                display: true,
                animate: animated
            )
        }
        alphaValue = presentation.displayedOpacity
        ignoresMouseEvents = presentation.isClickThrough
        isMovableByWindowBackground = !presentation.isPositionLocked && !presentation.isClickThrough
        pinnedContentView.setPositionLocked(presentation.isPositionLocked)
        pinnedContentView.setClickThrough(presentation.isClickThrough)
        pinnedContentView.setOpacityLabel(Int((presentation.opacity * 100).rounded()))
        pinnedContentView.setClickThroughChrome(presentation.isClickThrough)
        if let menu = pinnedContentView.menu {
            menuWillOpen(menu)
        }
        updateClickThroughBadge()
    }

    private func updateClickThroughBadge() {
        if presentation.isClickThrough {
            let badge = clickThroughBadge ?? PinnedClickThroughBadgeWindow { [weak self] in
                self?.toggleClickThrough()
            }
            clickThroughBadge = badge
            badge.reposition(over: frame)
            if isVisible {
                badge.orderFrontRegardless()
            }
        } else {
            clickThroughBadge?.orderOut(nil)
            clickThroughBadge = nil
        }
    }

    private func configureToolbar() {
        pinnedContentView.configureToolbar(
            target: self,
            copyAction: #selector(copyImage),
            zoomOutAction: #selector(zoomOut),
            zoomInAction: #selector(zoomIn),
            opacityAction: #selector(cycleOpacity),
            lockAction: #selector(togglePositionLock),
            clickThroughAction: #selector(toggleClickThrough),
            closeAction: #selector(closePinnedImage)
        )
    }

    private func configureContextMenu() {
        let menu = NSMenu(title: "贴图")
        menu.delegate = self
        menu.addItem(menuItem("复制图像", action: #selector(copyImage), keyEquivalent: "c"))
        menu.addItem(.separator())
        menu.addItem(menuItem("放大", action: #selector(zoomIn), keyEquivalent: "+"))
        menu.addItem(menuItem("缩小", action: #selector(zoomOut), keyEquivalent: "-"))
        menu.addItem(menuItem("适合初始大小", action: #selector(resetSize), keyEquivalent: "0"))

        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu(title: "透明度")
        opacityMenu.delegate = self
        for value in [100, 80, 60, 40] {
            let item = menuItem("\(value)%", action: #selector(setOpacity(_:)))
            item.tag = MenuTag.opacityBase + value
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        let lockItem = menuItem("锁定位置", action: #selector(togglePositionLock))
        lockItem.tag = MenuTag.lockPosition
        menu.addItem(lockItem)
        let clickThroughItem = menuItem("鼠标穿透", action: #selector(toggleClickThrough), keyEquivalent: "p")
        clickThroughItem.keyEquivalentModifierMask = []
        clickThroughItem.tag = MenuTag.clickThrough
        menu.addItem(clickThroughItem)
        menu.addItem(.separator())
        if source.lens != nil {
            menu.addItem(menuItem("在 Finder 中显示项目", action: #selector(revealProject)))
        }
        menu.addItem(menuItem("关闭贴图", action: #selector(closePinnedImage), keyEquivalent: "w"))
        pinnedContentView.menu = menu
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }
}

@MainActor
private final class PinnedImageContentView: NSView, NSDraggingSource {
    let image: NSImage

    private let imageView: NSImageView
    private let toolbar = NSVisualEffectView()
    private let toolbarStack = NSStackView()
    private let copyButton = NSButton()
    private let opacityButton = NSButton()
    private let lockButton = NSButton()
    private let clickThroughButton = NSButton()
    private var trackingAreaReference: NSTrackingArea?
    private var confirmationWorkItem: DispatchWorkItem?

    init(frame: CGRect, image: NSImage) {
        self.image = image
        imageView = PinnedImageView(frame: frame)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 10
        toolbar.layer?.masksToBounds = true
        toolbar.alphaValue = 0
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 2
        toolbarStack.edgeInsets = NSEdgeInsets(top: 4, left: 5, bottom: 4, right: 5)
        toolbar.addSubview(toolbarStack)
        addSubview(toolbar)
        toolTip = "拖动移动；Command 或 Option 拖出 PNG"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let size = toolbarStack.fittingSize
        toolbar.frame = CGRect(
            x: max(bounds.maxX - size.width - 10, 8),
            y: max(bounds.maxY - size.height - 10, 8),
            width: size.width,
            height: size.height
        )
        toolbarStack.frame = toolbar.bounds
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override var mouseDownCanMoveWindow: Bool {
        window?.isMovableByWindowBackground ?? true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if PinnedImageWindow.shouldBeginFileDrag(event.modifierFlags) {
            (window as? PinnedImageWindow)?.beginFileDrag(with: event)
            return
        }
        // Borderless pins have no title bar. NSImageView is an NSControl, so
        // AppKit would otherwise eat the drag instead of moving the window.
        if window?.isMovableByWindowBackground == true {
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    override func scrollWheel(with event: NSEvent) {
        forwardScroll(event)
    }

    override func magnify(with event: NSEvent) {
        (window as? PinnedImageWindow)?.applyMagnification(event.magnification)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            (window as? PinnedImageWindow)?.resetSizeAndOpacity()
            return
        }
        super.otherMouseDown(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        setToolbarVisible(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        setToolbarVisible(false, animated: true)
    }

    func setToolbarVisible(_ visible: Bool, animated: Bool) {
        guard animated else {
            toolbar.alphaValue = visible ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.12 : 0.18
            toolbar.animator().alphaValue = visible ? 1 : 0
        }
    }

    func configureToolbar(
        target: AnyObject,
        copyAction: Selector,
        zoomOutAction: Selector,
        zoomInAction: Selector,
        opacityAction: Selector,
        lockAction: Selector,
        clickThroughAction: Selector,
        closeAction: Selector
    ) {
        configure(
            copyButton,
            symbol: "doc.on.doc",
            label: "复制图像",
            target: target,
            action: copyAction
        )
        toolbarStack.addArrangedSubview(copyButton)
        toolbarStack.addArrangedSubview(button(
            symbol: "minus.magnifyingglass",
            label: "缩小贴图",
            target: target,
            action: zoomOutAction
        ))
        toolbarStack.addArrangedSubview(button(
            symbol: "plus.magnifyingglass",
            label: "放大贴图",
            target: target,
            action: zoomInAction
        ))
        configure(
            opacityButton,
            symbol: "circle.lefthalf.filled",
            label: "切换透明度",
            target: target,
            action: opacityAction
        )
        toolbarStack.addArrangedSubview(opacityButton)
        configure(
            lockButton,
            symbol: "lock.open",
            label: "锁定位置",
            target: target,
            action: lockAction
        )
        toolbarStack.addArrangedSubview(lockButton)
        configure(
            clickThroughButton,
            symbol: "cursorarrow.slash",
            label: "鼠标穿透",
            target: target,
            action: clickThroughAction
        )
        if clickThroughButton.image == nil {
            clickThroughButton.image = NSImage(
                systemSymbolName: "eye.slash",
                accessibilityDescription: "鼠标穿透"
            )
        }
        toolbarStack.addArrangedSubview(clickThroughButton)
        toolbarStack.addArrangedSubview(button(
            symbol: "xmark",
            label: "关闭贴图",
            target: target,
            action: closeAction
        ))
        needsLayout = true
    }

    func setPositionLocked(_ isLocked: Bool) {
        lockButton.image = NSImage(
            systemSymbolName: isLocked ? "lock" : "lock.open",
            accessibilityDescription: isLocked ? "解锁位置" : "锁定位置"
        )
        lockButton.toolTip = isLocked ? "解锁位置" : "锁定位置"
    }

    func setClickThrough(_ isClickThrough: Bool) {
        let symbol = isClickThrough ? "cursorarrow" : "cursorarrow.slash"
        let fallback = isClickThrough ? "eye" : "eye.slash"
        let label = isClickThrough ? "退出鼠标穿透" : "鼠标穿透"
        clickThroughButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: label)
        clickThroughButton.toolTip = label
        clickThroughButton.setAccessibilityLabel(label)
    }

    func setClickThroughChrome(_ isClickThrough: Bool) {
        layer?.borderWidth = isClickThrough ? 2 : 0
        layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.9).cgColor
    }

    func setOpacityLabel(_ percent: Int) {
        opacityButton.toolTip = "透明度 \(percent)% · Option 或 Control + 滚轮"
        opacityButton.setAccessibilityLabel("透明度 \(percent)%")
    }

    private func forwardScroll(_ event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        (window as? PinnedImageWindow)?.applyScroll(
            deltaY: delta,
            isPrecise: event.hasPreciseScrollingDeltas,
            modifiers: event.modifierFlags
        )
    }

    func showConfirmation(symbol: String) {
        confirmationWorkItem?.cancel()
        copyButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "复制成功"
        )
        let workItem = DispatchWorkItem { [weak self] in
            self?.copyButton.image = NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: "复制图像"
            )
        }
        confirmationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func button(
        symbol: String,
        label: String,
        target: AnyObject,
        action: Selector
    ) -> NSButton {
        let button = NSButton()
        configure(button, symbol: symbol, label: label, target: target, action: action)
        return button
    }

    private func configure(
        _ button: NSButton,
        symbol: String,
        label: String,
        target: AnyObject,
        action: Selector
    ) {
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.target = target
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
}

/// Fills the pin. NSControl defaults to swallowing mouse-down, which would
/// leave a borderless screenshot stuck in place after it is pinned.
private final class PinnedImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool {
        window?.isMovableByWindowBackground ?? true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if PinnedImageWindow.shouldBeginFileDrag(event.modifierFlags) {
            (window as? PinnedImageWindow)?.beginFileDrag(with: event)
            return
        }
        if window?.isMovableByWindowBackground == true {
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        superview?.magnify(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        superview?.otherMouseDown(with: event)
    }
}

/// Stays clickable while the pin ignores mouse events, so click-through is reversible
/// without a global hotkey or Accessibility key monitoring.
private final class PinnedClickThroughBadgeWindow: NSPanel {
    private let onExit: () -> Void

    init(onExit: @escaping () -> Void) {
        self.onExit = onExit
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 88, height: 28),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false

        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 88, height: 28))
        button.title = "退出穿透"
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.target = self
        button.action = #selector(exitClickThrough)
        button.setAccessibilityLabel("退出鼠标穿透")
        contentView = button
    }

    @objc private func exitClickThrough() {
        onExit()
    }

    func reposition(over pinFrame: CGRect) {
        let size = frame.size
        var origin = CGPoint(
            x: pinFrame.midX - size.width / 2,
            y: pinFrame.maxY + 8
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(pinFrame) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y + size.height > visible.maxY {
                origin.y = pinFrame.minY - size.height - 8
            }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        setFrameOrigin(origin)
    }
}

import AppKit
import ScreenTraceCore

struct PinnedImagePresentation: Equatable {
    static let minimumOpacity: CGFloat = 0.4

    let imageSize: CGSize
    let fittedScale: CGFloat
    var scale: CGFloat
    var opacity: CGFloat = 1
    var isPositionLocked = false

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
}

@MainActor
final class PinnedImageWindowController {
    private var windows: [PinnedImageWindow] = []

    func pin(trace: SavedTrace, image: NSImage) {
        let window = PinnedImageWindow(
            image: image,
            trace: trace,
            maximumInitialSize: CGSize(width: 520, height: 420)
        )
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            windows.removeAll { $0 === window }
        }
        windows.append(window)
        window.center()
        window.orderFrontRegardless()
        window.makeKey()
    }
}

@MainActor
final class PinnedImageWindow: NSWindow, NSMenuDelegate {
    private enum MenuTag {
        static let opacityBase = 2_000
        static let lockPosition = 3_000
    }

    var onClose: (() -> Void)?

    private let trace: SavedTrace
    private let pinnedContentView: PinnedImageContentView
    private var presentation: PinnedImagePresentation

    init(image: NSImage, trace: SavedTrace, maximumInitialSize: CGSize) {
        self.trace = trace
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
        title = trace.manifest.title
        setAccessibilityLabel("贴图：\(trace.manifest.title)")
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
            closePinnedImage()
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([pinnedContentView.image])
        pinnedContentView.showConfirmation(symbol: "checkmark")
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
        applyPresentation(resizing: true)
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

    @objc private func revealProject() {
        NSWorkspace.shared.activateFileViewerSelecting([trace.packageURL])
    }

    @objc private func closePinnedImage() {
        orderOut(nil)
        onClose?()
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            if item.tag == MenuTag.lockPosition {
                item.state = presentation.isPositionLocked ? .on : .off
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

    private func applyPresentation(resizing: Bool) {
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
                animate: true
            )
        }
        alphaValue = presentation.opacity
        isMovableByWindowBackground = !presentation.isPositionLocked
        pinnedContentView.setPositionLocked(presentation.isPositionLocked)
        pinnedContentView.setOpacityLabel(Int((presentation.opacity * 100).rounded()))
    }

    private func configureToolbar() {
        pinnedContentView.configureToolbar(
            target: self,
            copyAction: #selector(copyImage),
            zoomOutAction: #selector(zoomOut),
            zoomInAction: #selector(zoomIn),
            opacityAction: #selector(cycleOpacity),
            lockAction: #selector(togglePositionLock),
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
        menu.addItem(.separator())
        menu.addItem(menuItem("在 Finder 中显示项目", action: #selector(revealProject)))
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
private final class PinnedImageContentView: NSView {
    let image: NSImage

    private let imageView: NSImageView
    private let toolbar = NSVisualEffectView()
    private let toolbarStack = NSStackView()
    private let copyButton = NSButton()
    private let opacityButton = NSButton()
    private let lockButton = NSButton()
    private var trackingAreaReference: NSTrackingArea?
    private var confirmationWorkItem: DispatchWorkItem?

    init(frame: CGRect, image: NSImage) {
        self.image = image
        imageView = NSImageView(frame: frame)
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

    func setOpacityLabel(_ percent: Int) {
        opacityButton.toolTip = "透明度 \(percent)%"
        opacityButton.setAccessibilityLabel("透明度 \(percent)%")
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

import AppKit

enum PinnedClipboardKind: Equatable {
    case image
    case text
    case color
}

struct PinnedClipboardItem: Equatable {
    let kind: PinnedClipboardKind
    let title: String
    let image: NSImage

    static func == (lhs: PinnedClipboardItem, rhs: PinnedClipboardItem) -> Bool {
        lhs.kind == rhs.kind
            && lhs.title == rhs.title
            && lhs.image.size == rhs.image.size
    }
}

enum PinnedClipboardReader {
    static func read(from pasteboard: NSPasteboard = .general) -> PinnedClipboardItem? {
        if let image = image(from: pasteboard) {
            return PinnedClipboardItem(kind: .image, title: "剪贴板图像", image: image)
        }
        guard let string = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }
        if let color = PinnedColorSwatch.color(from: string) {
            return PinnedClipboardItem(
                kind: .color,
                title: PinnedColorSwatch.hexString(color),
                image: PinnedClipboardRenderer.colorSwatch(color)
            )
        }
        return PinnedClipboardItem(
            kind: .text,
            title: String(string.prefix(24)),
            image: PinnedClipboardRenderer.textCard(string)
        )
    }

    private static func image(from pasteboard: NSPasteboard) -> NSImage? {
        if pasteboard.availableType(from: [.png, .tiff]) != nil,
           let image = NSImage(pasteboard: pasteboard),
           image.size.width > 1,
           image.size.height > 1 {
            return image
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] else {
            return nil
        }
        for url in urls {
            if let image = NSImage(contentsOf: url),
               image.size.width > 1,
               image.size.height > 1 {
                return image
            }
        }
        return nil
    }
}

enum PinnedColorSwatch {
    static func color(from string: String) -> NSColor? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            return hexColor(trimmed)
        }
        if trimmed.lowercased().hasPrefix("rgb") {
            return rgbColor(trimmed)
        }
        return nil
    }

    static func hexString(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    private static func hexColor(_ raw: String) -> NSColor? {
        var hex = String(raw.drop(while: { $0 == "#" }))
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let hasAlpha = hex.count == 8
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if hasAlpha {
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            alpha = CGFloat(value & 0xFF) / 255
        } else {
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
            alpha = 1
        }
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func rgbColor(_ raw: String) -> NSColor? {
        let scalars = raw.split { character in
            !character.isNumber && character != "."
        }
        let values = scalars.compactMap { Double($0) }
        guard values.count == 3 || values.count == 4,
              values.prefix(3).allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        let alpha: CGFloat
        if values.count == 4 {
            let rawAlpha = values[3]
            alpha = rawAlpha > 1 ? min(rawAlpha / 255, 1) : max(rawAlpha, 0)
        } else {
            alpha = 1
        }
        return NSColor(
            srgbRed: values[0] / 255,
            green: values[1] / 255,
            blue: values[2] / 255,
            alpha: alpha
        )
    }
}

enum PinnedClipboardRenderer {
    static func textCard(_ text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 14)
        let inset: CGFloat = 16
        let maxWidth: CGFloat = 360
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth - inset * 2, height: 2_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let size = CGSize(
            width: min(max(ceil(bounds.width) + inset * 2, 128), maxWidth),
            height: min(max(ceil(bounds.height) + inset * 2, 48), 420)
        )
        return NSImage(size: size, flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            (text as NSString).draw(
                with: rect.insetBy(dx: inset, dy: inset),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor
                ]
            )
            return true
        }
    }

    static func colorSwatch(_ color: NSColor) -> NSImage {
        let size = CGSize(width: 180, height: 118)
        let hex = PinnedColorSwatch.hexString(color)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            let swatch = CGRect(x: 12, y: 36, width: rect.width - 24, height: 70)
            color.setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 8, yRadius: 8).fill()
            (hex as NSString).draw(
                at: CGPoint(x: 14, y: 12),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.labelColor
                ]
            )
            return true
        }
    }
}

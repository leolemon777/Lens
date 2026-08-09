import AppKit

enum ImageEncodingError: LocalizedError {
    case unableToCreateBitmap
    case unableToEncodePNG

    var errorDescription: String? {
        switch self {
        case .unableToCreateBitmap:
            return "无法读取截图像素。"
        case .unableToEncodePNG:
            return "无法把截图编码为 PNG。"
        }
    }
}

enum ImageEncoding {
    static func pngData(from image: CGImage) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: image)
        guard representation.pixelsWide > 0, representation.pixelsHigh > 0 else {
            throw ImageEncodingError.unableToCreateBitmap
        }
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ImageEncodingError.unableToEncodePNG
        }
        return data
    }

    static func nsImage(from image: CGImage) -> NSImage {
        NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    static func cgImage(from image: NSImage) throws -> CGImage {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            throw ImageEncodingError.unableToCreateBitmap
        }
        return cgImage
    }
}

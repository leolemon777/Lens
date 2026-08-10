import AppKit
import ScreenTraceCore

enum ImageEncodingError: LocalizedError {
    case unableToCreateBitmap
    case unableToEncodePNG
    case unableToEncodeJPEG

    var errorDescription: String? {
        switch self {
        case .unableToCreateBitmap:
            return "无法读取截图像素。"
        case .unableToEncodePNG:
            return "无法把截图编码为 PNG。"
        case .unableToEncodeJPEG:
            return "无法把截图编码为 JPEG。"
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

    static func jpegData(from image: CGImage, quality: Double = 0.92) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ImageEncodingError.unableToCreateBitmap
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        guard let flattenedImage = context.makeImage() else {
            throw ImageEncodingError.unableToCreateBitmap
        }

        let representation = NSBitmapImageRep(cgImage: flattenedImage)
        guard representation.pixelsWide > 0, representation.pixelsHigh > 0 else {
            throw ImageEncodingError.unableToCreateBitmap
        }
        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: min(max(quality, 0), 1)]
        ) else {
            throw ImageEncodingError.unableToEncodeJPEG
        }
        return data
    }

    static func data(
        from image: CGImage,
        format: ScreenshotExportFormat
    ) throws -> Data {
        switch format {
        case .png: try pngData(from: image)
        case .jpeg: try jpegData(from: image)
        }
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

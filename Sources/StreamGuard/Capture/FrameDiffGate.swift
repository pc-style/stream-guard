import CoreGraphics
import CoreVideo
import Foundation

struct PackedPixelLayout {
    let redOffset: Int
    let greenOffset: Int
    let blueOffset: Int
    let bytesPerPixel: Int

    static func layout(for pixelFormat: OSType) -> PackedPixelLayout? {
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            PackedPixelLayout(redOffset: 2, greenOffset: 1, blueOffset: 0, bytesPerPixel: 4)
        case kCVPixelFormatType_32ARGB:
            PackedPixelLayout(redOffset: 1, greenOffset: 2, blueOffset: 3, bytesPerPixel: 4)
        case kCVPixelFormatType_32RGBA:
            PackedPixelLayout(redOffset: 0, greenOffset: 1, blueOffset: 2, bytesPerPixel: 4)
        case kCVPixelFormatType_32ABGR:
            PackedPixelLayout(redOffset: 3, greenOffset: 2, blueOffset: 1, bytesPerPixel: 4)
        default:
            nil
        }
    }

    func luminance(base: UnsafePointer<UInt8>, bytesPerRow: Int, x: Int, y: Int) -> UInt8 {
        let offset = y * bytesPerRow + x * bytesPerPixel
        let r = Int(base[offset + redOffset])
        let g = Int(base[offset + greenOffset])
        let b = Int(base[offset + blueOffset])
        return UInt8(clamping: (77 * r + 150 * g + 29 * b) >> 8)
    }
}

enum FrameDiffGate {
    /// Minimum fraction of fingerprint pixels that must change to treat a frame as new.
    static let unchangedThreshold = 0.02

    static func changeRatio(previous: [UInt8]?, current: [UInt8]) -> Double {
        guard let previous, previous.count == current.count, !current.isEmpty else {
            return 1.0
        }
        var changed = 0
        for i in 0..<current.count {
            if abs(Int(current[i]) - Int(previous[i])) > 8 {
                changed += 1
            }
        }
        return Double(changed) / Double(current.count)
    }

    /// Small subsampled fingerprint without copying the full frame buffer.
    static func fingerprint(pixelBuffer: CVPixelBuffer, targetWidth: Int = 64) -> [UInt8] {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return [] }
        guard let layout = PackedPixelLayout.layout(for: CVPixelBufferGetPixelFormatType(pixelBuffer)) else {
            return []
        }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            return []
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let sampleWidth = max(1, min(targetWidth, width))
        let scale = Double(sampleWidth) / Double(width)
        let sampleHeight = max(1, min(height, Int(round(Double(height) * scale))))
        var output = [UInt8]()
        output.reserveCapacity(sampleWidth * sampleHeight)

        for sampleY in 0..<sampleHeight {
            let y = min(height - 1, Int((Double(sampleY) + 0.5) * Double(height) / Double(sampleHeight)))
            for sampleX in 0..<sampleWidth {
                let x = min(width - 1, Int((Double(sampleX) + 0.5) * Double(width) / Double(sampleWidth)))
                output.append(layout.luminance(base: base, bytesPerRow: bytesPerRow, x: x, y: y))
            }
        }
        return output
    }
}

enum ImageDownscaler {
    static let maxLongEdge: CGFloat = CGFloat(ScreenCaptureManager.ocrMaxLongEdge)
    private static let maxCroppedImages = 12

    static func needsDownscale(pixelBuffer: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return max(width, height) > Int(maxLongEdge)
    }

    static func imageForOCR(pixelBuffer: CVPixelBuffer) -> CGImage? {
        if needsDownscale(pixelBuffer: pixelBuffer) {
            return downscale(pixelBuffer: pixelBuffer)
        }
        return cgImage(from: pixelBuffer)
    }

    static func croppedImagesForOCR(pixelBuffer: CVPixelBuffer, regions: [TextRegion]) -> [CGImage] {
        guard let image = imageForOCR(pixelBuffer: pixelBuffer) else { return [] }
        return croppedImages(from: image, pixelBuffer: pixelBuffer, regions: regions, extraScale: 1)
    }

    static func downscaledCroppedImagesForOCR(pixelBuffer: CVPixelBuffer, regions: [TextRegion], factor: CGFloat) -> [CGImage] {
        guard let image = imageForOCR(pixelBuffer: pixelBuffer) else { return [] }
        return croppedImages(from: image, pixelBuffer: pixelBuffer, regions: regions, extraScale: max(factor, 1))
    }

    static func adaptiveCroppedImagesForOCR(pixelBuffer: CVPixelBuffer, regions: [TextRegion]) -> [CGImage] {
        guard let image = imageForOCR(pixelBuffer: pixelBuffer) else { return [] }
        return croppedImages(from: image, pixelBuffer: pixelBuffer, regions: regions) { crop in
            let longEdge = max(crop.width, crop.height)
            let shortEdge = min(crop.width, crop.height)
            guard longEdge >= 900, shortEdge >= 220 else { return 1 }
            return 2
        }
    }

    private static func croppedImages(
        from image: CGImage,
        pixelBuffer: CVPixelBuffer,
        regions: [TextRegion],
        extraScale: CGFloat
    ) -> [CGImage] {
        croppedImages(from: image, pixelBuffer: pixelBuffer, regions: regions) { _ in extraScale }
    }

    private static func croppedImages(
        from image: CGImage,
        pixelBuffer: CVPixelBuffer,
        regions: [TextRegion],
        scaleForCrop: (CGImage) -> CGFloat
    ) -> [CGImage] {
        guard !regions.isEmpty else { return [] }
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let scaleX = imageWidth / max(sourceWidth, 1)
        let scaleY = imageHeight / max(sourceHeight, 1)
        let imageBounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        var seenRects = Set<String>()
        var cropped: [CGImage] = []

        for region in regions.prefix(maxCroppedImages) {
            let cropRect = CGRect(
                x: region.pixelRect.minX * scaleX,
                y: region.pixelRect.minY * scaleY,
                width: region.pixelRect.width * scaleX,
                height: region.pixelRect.height * scaleY
            )
            let integralRect = cropRect.intersection(imageBounds).integral.intersection(imageBounds)
            guard integralRect.width >= 8, integralRect.height >= 8 else { continue }

            let rectKey = "\(Int(integralRect.minX)):\(Int(integralRect.minY)):\(Int(integralRect.width)):\(Int(integralRect.height))"
            guard seenRects.insert(rectKey).inserted else { continue }
            guard let crop = image.cropping(to: integralRect) else { continue }
            let scale = max(scaleForCrop(crop), 1)
            if scale > 1,
               let downscaled = downscale(image: crop, factor: scale) {
                cropped.append(downscaled)
            } else {
                cropped.append(crop)
            }
        }
        return cropped
    }

    private static func downscale(image: CGImage, factor: CGFloat) -> CGImage? {
        let targetWidth = max(1, Int(CGFloat(image.width) / factor))
        let targetHeight = max(1, Int(CGFloat(image.height) / factor))
        guard targetWidth < image.width || targetHeight < image.height else { return image }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    static func downscale(pixelBuffer: CVPixelBuffer) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let longEdge = max(width, height)
        let scale = maxLongEdge / CGFloat(longEdge)
        let targetWidth = Int(CGFloat(width) * scale)
        let targetHeight = Int(CGFloat(height) * scale)
        guard let sourceBitmapInfo = bitmapInfo(for: CVPixelBufferGetPixelFormatType(pixelBuffer)) else {
            return nil
        }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let targetBitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: targetBitmapInfo
        ) else { return nil }

        guard let sourceContext = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: sourceBitmapInfo
        ), let sourceImage = sourceContext.makeImage() else { return nil }

        context.interpolationQuality = .medium
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    private static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard let bitmapInfo = bitmapInfo(for: CVPixelBufferGetPixelFormatType(pixelBuffer)) else {
            return nil
        }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        return context.makeImage()
    }

    private static func bitmapInfo(for pixelFormat: OSType) -> UInt32? {
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        case kCVPixelFormatType_32ARGB:
            CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        case kCVPixelFormatType_32RGBA:
            CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        case kCVPixelFormatType_32ABGR:
            CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        default:
            nil
        }
    }
}

import CoreGraphics
import CoreVideo
import Foundation

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

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            return []
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let scale = Double(targetWidth) / Double(width)
        let targetHeight = max(1, Int(Double(height) * scale))
        var output = [UInt8]()
        output.reserveCapacity(targetWidth * targetHeight)

        for y in stride(from: 0, to: height, by: max(1, height / targetHeight)) {
            for x in stride(from: 0, to: width, by: max(1, width / targetWidth)) {
                let offset = y * bytesPerRow + x * 4
                let r = UInt16(base[offset])
                let g = UInt16(base[offset + 1])
                let b = UInt16(base[offset + 2])
                let average = (r + g + b) / 3
                output.append(UInt8(clamping: average))
            }
        }
        return output
    }
}

enum ImageDownscaler {
    static let maxLongEdge: CGFloat = CGFloat(ScreenCaptureManager.ocrMaxLongEdge)

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

    static func downscale(pixelBuffer: CVPixelBuffer) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let longEdge = max(width, height)
        let scale = maxLongEdge / CGFloat(longEdge)
        let targetWidth = Int(CGFloat(width) * scale)
        let targetHeight = Int(CGFloat(height) * scale)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
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

        guard let sourceContext = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let sourceImage = sourceContext.makeImage() else { return nil }

        context.interpolationQuality = .medium
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    private static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

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
}

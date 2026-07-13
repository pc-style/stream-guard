import Foundation
import CoreGraphics

public struct CaptureGeometry: Equatable, Sendable {
    public let globalBounds: CGRect
    public let pixelSize: CGSize
    /// The portion of the output bitmap containing the captured display, in
    /// Core Image's bottom-left coordinate system.
    public let contentRect: CGRect

    public init(globalBounds: CGRect, pixelSize: CGSize, contentRect: CGRect? = nil) {
        self.globalBounds = globalBounds
        self.pixelSize = pixelSize
        self.contentRect = contentRect ?? CGRect(origin: .zero, size: pixelSize)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.globalBounds.equalTo(rhs.globalBounds) && lhs.pixelSize.equalTo(rhs.pixelSize) && lhs.contentRect.equalTo(rhs.contentRect)
    }

    /// Converts top-left desktop coordinates to bottom-left image coordinates.
    public func imageRect(for globalRect: CGRect, padding: CGFloat = 2) -> CGRect? {
        let clipped = globalRect.intersection(globalBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0,
              globalBounds.width > 0, globalBounds.height > 0 else { return nil }
        guard contentRect.width > 0, contentRect.height > 0 else { return nil }
        let sx = contentRect.width / globalBounds.width
        let sy = contentRect.height / globalBounds.height
        let x0 = floor(contentRect.minX + (clipped.minX - globalBounds.minX) * sx - padding)
        let x1 = ceil(contentRect.minX + (clipped.maxX - globalBounds.minX) * sx + padding)
        let y0 = floor(contentRect.minY + (globalBounds.maxY - clipped.maxY) * sy - padding)
        let y1 = ceil(contentRect.minY + (globalBounds.maxY - clipped.minY) * sy + padding)
        let mapped = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        let output = CGRect(origin: .zero, size: pixelSize)
        let result = mapped.intersection(contentRect).intersection(output)
        return result.isNull || result.isEmpty ? nil : result
    }
}

/// Converts a Core Image bottom-left crop to CGImage top-left coordinates.
public func cgImageCropRect(fromCIRect rect: CGRect, imageHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: imageHeight - rect.maxY, width: rect.width, height: rect.height)
}

public struct ProtectionSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let capturedAt: TimeInterval
    /// Desktop-coordinate rectangles, mapped against the delivered frame size.
    public let maskRects: [CGRect]
    /// Desktop-coordinate AX coverage failures. Safe OCR is scoped to these.
    public let gapRects: [CGRect]
    public let captureBounds: CGRect?
    public let usesOCR: Bool
    public let detectionOptions: DetectionOptions
    public let blocksFrame: Bool
    public let reason: String

    public init(generation: UInt64, capturedAt: TimeInterval, maskRects: [CGRect], gapRects: [CGRect] = [], captureBounds: CGRect? = nil, usesOCR: Bool = false, detectionOptions: DetectionOptions = DetectionOptions(), blocksFrame: Bool, reason: String) {
        self.generation = generation; self.capturedAt = capturedAt; self.maskRects = maskRects
        self.gapRects = gapRects; self.captureBounds = captureBounds; self.usesOCR = usesOCR; self.detectionOptions = detectionOptions
        self.blocksFrame = blocksFrame; self.reason = reason
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generation == rhs.generation && lhs.capturedAt == rhs.capturedAt && lhs.blocksFrame == rhs.blocksFrame && lhs.reason == rhs.reason &&
        lhs.maskRects.count == rhs.maskRects.count && zip(lhs.maskRects, rhs.maskRects).allSatisfy { $0.equalTo($1) } && lhs.gapRects.count == rhs.gapRects.count && zip(lhs.gapRects, rhs.gapRects).allSatisfy { $0.equalTo($1) } && lhs.captureBounds == rhs.captureBounds && lhs.usesOCR == rhs.usesOCR
    }

    public func isFresh(at time: TimeInterval, maximumAge: TimeInterval) -> Bool {
        time >= capturedAt && time - capturedAt <= maximumAge
    }
}

public final class SnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProtectionSnapshot?
    public init() {}
    public func replace(_ snapshot: ProtectionSnapshot?) { lock.withLock { value = snapshot } }
    public func decision(at time: TimeInterval, maximumAge: TimeInterval, expectedGeneration: UInt64) -> ProtectionSnapshot? {
        lock.withLock { value.flatMap { $0.generation == expectedGeneration && $0.isFresh(at: time, maximumAge: maximumAge) ? $0 : nil } }
    }
}

import Foundation

public struct DelayBufferPolicy: Equatable, Sendable {
    public static let defaultMemoryBudgetBytes = 256 * 1_024 * 1_024

    public let estimatedBytesPerFrame: Int
    public let maxFrames: Int
    public let sampleInterval: TimeInterval

    public init(
        width: Int,
        height: Int,
        delaySeconds: TimeInterval,
        fps: Int,
        memoryBudgetBytes: Int = Self.defaultMemoryBudgetBytes
    ) {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        let safeFPS = max(1, fps)
        let safeDelay = max(0, delaySeconds)
        let safeBudget = max(1, memoryBudgetBytes)

        let (pixels, pixelsOverflowed) = safeWidth.multipliedReportingOverflow(by: safeHeight)
        let (bytes, bytesOverflowed) = pixels.multipliedReportingOverflow(by: 4)
        let bytesPerFrame = pixelsOverflowed || bytesOverflowed ? Int.max : max(1, bytes)
        let budgetFrameCount = bytesPerFrame > safeBudget ? 1 : max(1, safeBudget / bytesPerFrame)
        let desiredFrameCount = max(1, Int(ceil(safeDelay * Double(safeFPS))))
        let maxFrames = min(desiredFrameCount, budgetFrameCount)

        self.estimatedBytesPerFrame = bytesPerFrame
        self.maxFrames = maxFrames
        self.sampleInterval = max(1.0 / Double(safeFPS), safeDelay / Double(maxFrames))
    }

    public var estimatedMaximumBytes: Int {
        let (bytes, overflowed) = estimatedBytesPerFrame.multipliedReportingOverflow(by: maxFrames)
        return overflowed ? Int.max : bytes
    }
}

import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import StreamGuardCore

protocol ScreenCaptureDelegate: AnyObject {
    func captureDidOutput(pixelBuffer: CVPixelBuffer, timestamp: CMTime)
    func captureDidFail(error: Error)
}

final class ScreenCaptureManager: NSObject, @unchecked Sendable {
    static let ocrMaxLongEdge = 1280

    weak var delegate: ScreenCaptureDelegate?

    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var excludedWindowIDs: [CGWindowID] = []
    private var contentFilter: SCContentFilter?
    private var streamConfiguration: SCStreamConfiguration?
    private var captureDisplay: SCDisplay?

    var isRunning: Bool { stream != nil }

    /// Dimensions for ScreenCaptureKit capture aligned with Vision OCR input size.
    static func ocrCaptureDimensions(displayWidth: Int, displayHeight: Int) -> (width: Int, height: Int) {
        let longEdge = max(displayWidth, displayHeight)
        guard longEdge > ocrMaxLongEdge else {
            return (displayWidth, displayHeight)
        }
        let scale = Double(ocrMaxLongEdge) / Double(longEdge)
        return (
            max(1, Int(Double(displayWidth) * scale)),
            max(1, Int(Double(displayHeight) * scale))
        )
    }

    func setExcludedWindows(_ windowIDs: [CGWindowID]) async {
        excludedWindowIDs = windowIDs
        await refreshContentFilterIfNeeded()
    }

    func requestPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func start() async throws {
        guard hasPermission() else {
            throw CaptureError.permissionDenied
        }
        try await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        captureDisplay = display
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(from: content))
        let (captureWidth, captureHeight) = Self.ocrCaptureDimensions(
            displayWidth: display.width,
            displayHeight: display.height
        )

        let configuration = SCStreamConfiguration()
        configuration.width = captureWidth
        configuration.height = captureHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let output = CaptureStreamOutput { [weak self] buffer, time in
            self?.delegate?.captureDidOutput(pixelBuffer: buffer, timestamp: time)
        }
        streamOutput = output

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "dev.pcstyle.stream-guard.capture"))
        try await stream.startCapture()
        self.stream = stream
        self.contentFilter = filter
        self.streamConfiguration = configuration
    }

    /// Pulls a fresh frame on demand when the screen is static (clear hysteresis watchdog).
    func captureSnapshot() async -> CVPixelBuffer? {
        guard let contentFilter, let streamConfiguration else { return nil }
        if #available(macOS 14.0, *) {
            do {
                let sample = try await SCScreenshotManager.captureSampleBuffer(
                    contentFilter: contentFilter,
                    configuration: streamConfiguration
                )
                return CMSampleBufferGetImageBuffer(sample)
            } catch {
                return nil
            }
        }
        return nil
    }

    func stop() async throws {
        if let stream {
            try await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        contentFilter = nil
        streamConfiguration = nil
        captureDisplay = nil
    }

    private func refreshContentFilterIfNeeded() async {
        guard let stream, let display = captureDisplay else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(from: content))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stream.updateContentFilter(filter) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            contentFilter = filter
        } catch {
            // Best-effort; stale filter is non-fatal.
        }
    }

    private func excludedWindows(from content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { window in
            excludedWindowIDs.contains(window.windowID)
        }
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission is required. Grant access in System Settings, then restart Stream Guard."
        case .noDisplay:
            return "No display available for capture."
        }
    }
}

private final class CaptureStreamOutput: NSObject, SCStreamOutput {
    private let handler: (CVPixelBuffer, CMTime) -> Void

    init(handler: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        handler(pixelBuffer, timestamp)
    }
}

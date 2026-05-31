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
    weak var delegate: ScreenCaptureDelegate?

    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var excludedWindowIDs: [CGWindowID] = []
    private var contentFilter: SCContentFilter?
    private var streamConfiguration: SCStreamConfiguration?

    var isRunning: Bool { stream != nil }

    func setExcludedWindows(_ windowIDs: [CGWindowID]) {
        excludedWindowIDs = windowIDs
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

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(from: content))
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
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

    /// Pulls a fresh frame on demand, independent of `SCStream`'s change-driven
    /// delivery (which withholds frames while the screen is static). Reuses the
    /// stream's content filter so window exclusions stay consistent.
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

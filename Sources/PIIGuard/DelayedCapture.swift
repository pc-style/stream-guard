import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

final class DelayedCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame {
        let readyAt: TimeInterval
        let image: CGImage
    }

    var onFrame: ((CGImage) -> Void)?
    var onError: ((String) -> Void)?

    private let outputQueue = DispatchQueue(label: "dev.pcstyle.piiguard.capture", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var frames: [Frame] = []
    private var stream: SCStream?
    private var delaySeconds: Double = 2

    var isRunning: Bool { stream != nil }

    func start(delaySeconds: Double, fps: Int, width: Int, height: Int, showsCursor: Bool) async throws {
        await stop()
        self.delaySeconds = delaySeconds
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let ownApplication = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplication.map { [$0] } ?? [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = min(width, display.width)
        configuration.height = min(height, display.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 3
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        outputQueue.async { [weak self] in self?.frames.removeAll() }
    }

    func updateDelay(_ seconds: Double) {
        outputQueue.async { [weak self] in
            self?.delaySeconds = seconds
            self?.frames.removeAll()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        frames.append(Frame(readyAt: now + delaySeconds, image: cgImage))
        var newestReady: CGImage?
        while let first = frames.first, first.readyAt <= now {
            newestReady = first.image
            frames.removeFirst()
        }
        if let newestReady {
            DispatchQueue.main.async { [weak self] in self?.onFrame?(newestReady) }
        }
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    var errorDescription: String? { "No display is available for capture." }
}

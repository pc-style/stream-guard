import AppKit
import CoreImage
import CoreMedia
import PIIGuardCore
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
    private let stateLock = NSLock()
    private var frames: [Frame] = []
    private var stream: SCStream?
    private var targetBoundsStorage: CGRect?
    private var lifecycleGeneration: UInt64 = 0
    private var bufferGeneration: UInt64 = 0
    private var delaySeconds: Double = 2
    private var captureFPS = 10
    private var captureWidth = 1280
    private var captureHeight = 720
    private var bufferPolicy = DelayBufferPolicy(width: 1280, height: 720, delaySeconds: 2, fps: 10)
    private var lastBufferedAt: TimeInterval?

    var targetBounds: CGRect? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return targetBoundsStorage
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stream != nil && targetBoundsStorage != nil
    }

    func start(delaySeconds: Double, fps: Int, width: Int, height: Int, showsCursor: Bool) async throws {
        let (generation, previousStream) = beginLifecycleTransition()

        outputQueue.sync {
            bufferGeneration = generation
            self.delaySeconds = delaySeconds
            captureFPS = fps
            captureWidth = width
            captureHeight = height
            bufferPolicy = DelayBufferPolicy(width: width, height: height, delaySeconds: delaySeconds, fps: fps)
            frames.removeAll(keepingCapacity: true)
            lastBufferedAt = nil
        }

        if let previousStream { try? await previousStream.stopCapture() }
        guard isCurrent(generation) else { throw CaptureError.cancelled }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard isCurrent(generation) else { throw CaptureError.cancelled }
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

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        guard install(newStream, for: generation) else { throw CaptureError.cancelled }

        do {
            try await newStream.startCapture()
        } catch {
            clearInstalledStream(newStream, generation: generation)
            throw error
        }

        guard setTargetBounds(display.frame, for: newStream, generation: generation) else {
            try? await newStream.stopCapture()
            throw CaptureError.cancelled
        }
    }

    func stop() async {
        let (generation, stoppedStream) = beginLifecycleTransition()

        outputQueue.sync {
            bufferGeneration = generation
            frames.removeAll(keepingCapacity: true)
            lastBufferedAt = nil
        }
        if let stoppedStream { try? await stoppedStream.stopCapture() }
    }

    func updateDelay(_ seconds: Double) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            delaySeconds = seconds
            bufferPolicy = DelayBufferPolicy(
                width: captureWidth,
                height: captureHeight,
                delaySeconds: seconds,
                fps: captureFPS
            )
            frames.removeAll(keepingCapacity: true)
            lastBufferedAt = nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        guard self.stream === stream else {
            stateLock.unlock()
            return
        }
        self.stream = nil
        targetBoundsStorage = nil
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        stateLock.unlock()

        outputQueue.async { [weak self] in
            guard let self else { return }
            bufferGeneration = generation
            frames.removeAll(keepingCapacity: true)
            lastBufferedAt = nil
        }
        DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let generation = generation(for: stream) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        var newestReady: CGImage?
        while let first = frames.first, first.readyAt <= now {
            newestReady = first.image
            frames.removeFirst()
        }
        if let newestReady {
            DispatchQueue.main.async { [weak self] in
                guard let self, isCurrent(generation) else { return }
                onFrame?(newestReady)
            }
        }

        guard bufferGeneration == generation,
              frames.count < bufferPolicy.maxFrames,
              lastBufferedAt.map({ now - $0 >= bufferPolicy.sampleInterval }) ?? true,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        frames.append(Frame(readyAt: now + delaySeconds, image: cgImage))
        lastBufferedAt = now
    }

    private func beginLifecycleTransition() -> (generation: UInt64, previousStream: SCStream?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        lifecycleGeneration &+= 1
        let previousStream = stream
        stream = nil
        targetBoundsStorage = nil
        return (lifecycleGeneration, previousStream)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lifecycleGeneration == generation
    }

    private func install(_ stream: SCStream, for generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lifecycleGeneration == generation else { return false }
        self.stream = stream
        return true
    }

    private func clearInstalledStream(_ stream: SCStream, generation: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lifecycleGeneration == generation, self.stream === stream else { return }
        self.stream = nil
        targetBoundsStorage = nil
    }

    private func setTargetBounds(_ bounds: CGRect, for stream: SCStream, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lifecycleGeneration == generation, self.stream === stream else { return false }
        targetBoundsStorage = bounds
        return true
    }

    private func generation(for stream: SCStream) -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard self.stream === stream else { return nil }
        return lifecycleGeneration
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display is available for capture."
        case .cancelled: return "Capture request was superseded."
        }
    }
}

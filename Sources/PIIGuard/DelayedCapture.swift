import AppKit
import CoreImage
import CoreMedia
import PIIGuardCore
import ScreenCaptureKit
import Vision

final class DelayedCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame {
        let readyAt: TimeInterval
        let image: CGImage
        let decision: ProtectionSnapshot
        let geometry: CaptureGeometry?
    }

    var onFrame: ((CGImage) -> Void)?
    var onError: ((String) -> Void)?
    var protectionDecision: ((TimeInterval) -> ProtectionSnapshot?)?

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

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
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
            guard isCurrent(generation) else { return }
            bufferGeneration = generation
            frames.removeAll(keepingCapacity: true)
            lastBufferedAt = nil
        }
        DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let generation = generation(for: stream) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        var newestReady: Frame?
        while let first = frames.first, first.readyAt <= now {
            newestReady = first
            frames.removeFirst()
        }
        if let newestReady {
            // A frame may have been buffered while clean and become ready
            // after an AX invalidation. Re-check dirty state at presentation;
            // the capture-time snapshot still supplies spatially aligned masks.
            let rendered = protectionDecision?(now) == nil
                ? blackFrame(extent: CGRect(x: 0, y: 0, width: newestReady.image.width, height: newestReady.image.height))
                : render(newestReady)
            guard let rendered else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, isCurrent(generation) else { return }
                onFrame?(rendered)
            }
        }

        guard bufferGeneration == generation,
              frames.count < bufferPolicy.maxFrames,
              lastBufferedAt.map({ now - $0 >= bufferPolicy.sampleInterval }) ?? true,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        let decision = protectionDecision?(now) ?? ProtectionSnapshot(generation: generation, capturedAt: now, maskRects: [], blocksFrame: true, reason: "Protection snapshot unavailable")
        let frameGeometry = captureGeometry(from: sampleBuffer, pixelSize: image.extent.size, fallbackBounds: decision.captureBounds)
        frames.append(Frame(readyAt: now + delaySeconds, image: cgImage, decision: decision, geometry: frameGeometry))
        lastBufferedAt = now
    }

    private func render(_ frame: Frame) -> CGImage? {
        var image = CIImage(cgImage: frame.image)
        let extent = image.extent
        guard let globalBounds = frame.decision.captureBounds else {
            return frame.decision.blocksFrame ? blackFrame(extent: extent) : nil
        }
        let geometry = frame.geometry ?? CaptureGeometry(globalBounds: globalBounds, pixelSize: extent.size)
        var rects = frame.decision.maskRects.compactMap { geometry.imageRect(for: $0) }
        let gaps = frame.decision.gapRects.compactMap { geometry.imageRect(for: $0) }
        // AX/OCR are independent positive detectors. Vision does not provide
        // a completeness signal, so a successful request can add masks but
        // cannot prove that an AX coverage gap is safe to reveal.
        rects.append(contentsOf: gaps)
        if frame.decision.usesOCR {
            let ocr = ocrProtection(in: frame.image, crops: gaps, options: frame.decision.detectionOptions)
            rects.append(contentsOf: ocr.masks)
        }
        if frame.decision.blocksFrame { rects = [extent] }
        for rect in rects {
            let clipped = rect.intersection(extent)
            guard !clipped.isNull else { continue }
            image = CIImage(color: .black).cropped(to: clipped).composited(over: image)
        }
        return context.createCGImage(image, from: extent)
    }

    private func blackFrame(extent: CGRect) -> CGImage? {
        context.createCGImage(CIImage(color: .black).cropped(to: extent), from: extent)
    }

    private func ocrProtection(in image: CGImage, crops: [CGRect], options: DetectionOptions) -> (masks: [CGRect], failedCrops: [CGRect]) {
        let engine = DetectionEngine()
        var masks: [CGRect] = []
        var failedCrops: [CGRect] = []
        for crop in crops.prefix(8) {
            let cgCrop = cgImageCropRect(fromCIRect: crop.integral, imageHeight: CGFloat(image.height))
            guard let cropped = image.cropping(to: cgCrop) else {
                failedCrops.append(crop)
                continue
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: cropped).perform([request])
            } catch {
                failedCrops.append(crop)
                continue
            }
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                for detection in engine.detect(in: candidate.string, options: options) {
                    guard let swiftRange = Range(detection.range, in: candidate.string),
                          let box = try? candidate.boundingBox(for: swiftRange) else { continue }
                    // Vision boxes are normalized with a lower-left origin.
                    masks.append(CGRect(x: crop.minX + box.boundingBox.minX * crop.width,
                                        y: crop.minY + box.boundingBox.minY * crop.height,
                                        width: box.boundingBox.width * crop.width,
                                        height: box.boundingBox.height * crop.height).integral)
                }
            }
        }
        // Crops beyond the bounded OCR budget must remain coarse-masked.
        failedCrops.append(contentsOf: crops.dropFirst(8))
        return (masks, failedCrops)
    }

    private func captureGeometry(from sampleBuffer: CMSampleBuffer, pixelSize: CGSize, fallbackBounds: CGRect?) -> CaptureGeometry? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachment = attachments.first else {
            return fallbackBounds.map { CaptureGeometry(globalBounds: $0, pixelSize: pixelSize) }
        }
        func rect(_ key: SCStreamFrameInfo) -> CGRect? {
            if let value = attachment[key] as? NSValue { return value.rectValue }
            if let dictionary = attachment[key] as? [String: Any] {
                return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
            }
            return nil
        }
        let sourceBounds: CGRect?
        if #available(macOS 14.0, *) { sourceBounds = rect(.screenRect) ?? fallbackBounds }
        else { sourceBounds = fallbackBounds }
        guard let sourceBounds else { return nil }
        guard let metadataContent = rect(.contentRect), metadataContent.width > 0, metadataContent.height > 0 else {
            return CaptureGeometry(globalBounds: sourceBounds, pixelSize: pixelSize)
        }
        // ScreenCaptureKit reports output rectangles from the top-left; the
        // renderer and mask geometry use Core Image's bottom-left origin.
        let ciContent = cgImageCropRect(fromCIRect: metadataContent, imageHeight: pixelSize.height)
        return CaptureGeometry(globalBounds: sourceBounds, pixelSize: pixelSize, contentRect: ciContent)
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

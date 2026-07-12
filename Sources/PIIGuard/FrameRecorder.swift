import AVFoundation
import AppKit
import CoreImage
import CoreText

final class FrameRecorder: @unchecked Sendable {
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "dev.pcstyle.piiguard.recorder", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var fps = 10
    private var frameNumber: Int64 = 0
    private var pending = false
    private var finishing = false
    private var blockedImage: CGImage?
    private var blockedImageKey = ""
    private var terminalFailure: String?

    var isRecording: Bool { queue.sync { pending || writer != nil } }

    func start(url: URL, fps: Int) {
        queue.sync {
            outputURL = url
            self.fps = fps
            frameNumber = 0
            finishing = false
            pending = true
            blockedImage = nil
            blockedImageKey = ""
            terminalFailure = nil
        }
    }

    func append(_ source: CGImage, blockedReason: String?) {
        queue.async { [weak self] in
            guard let self, !finishing, pending || writer != nil else { return }
            do {
                if writer == nil { try prepareWriter(width: source.width, height: source.height) }
                guard let writer else { throw RecorderError.cannotStart }
                if writer.status == .failed { throw writer.error ?? RecorderError.writerFailed }
                guard writer.status == .writing, let input, let adaptor else { throw RecorderError.writerFailed }
                guard input.isReadyForMoreMediaData else { return }
                guard let pool = adaptor.pixelBufferPool else { throw RecorderError.pixelBufferPoolUnavailable }

                var buffer: CVPixelBuffer?
                let allocationResult = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard allocationResult == kCVReturnSuccess, let buffer else {
                    throw RecorderError.pixelBufferAllocationFailed(allocationResult)
                }

                let image = try blockedReason.map {
                    try self.protectedImage(width: source.width, height: source.height, reason: $0)
                } ?? source
                context.render(
                    CIImage(cgImage: image),
                    to: buffer,
                    bounds: CGRect(x: 0, y: 0, width: source.width, height: source.height),
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
                let time = CMTime(value: frameNumber, timescale: CMTimeScale(fps))
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? RecorderError.appendFailed
                }
                frameNumber += 1
            } catch {
                failRecording(error)
            }
        }
    }

    func stop(completion: @escaping (URL?, String?) -> Void) {
        queue.async { [weak self] in
            guard let self, !finishing else { return }
            pending = false
            guard let writer else {
                let failure = terminalFailure
                terminalFailure = nil
                DispatchQueue.main.async { completion(nil, failure) }
                return
            }
            finishing = true
            input?.markAsFinished()
            let url = outputURL
            writer.finishWriting {
                self.queue.async {
                    let succeeded = writer.status == .completed
                    let failureMessage = writer.error.map { "Recording failed: \($0.localizedDescription)" }
                    if !succeeded, let url { try? FileManager.default.removeItem(at: url) }
                    self.clearWriterState()
                    self.terminalFailure = nil
                    DispatchQueue.main.async {
                        completion(succeeded ? url : nil, succeeded ? nil : (failureMessage ?? "Recording failed while finalizing the video."))
                    }
                }
            }
        }
    }

    private func prepareWriter(width: Int, height: Int) throws {
        guard let outputURL else { throw RecorderError.missingOutputURL }
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 3)]
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw RecorderError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.cannotStart }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        pending = false
    }

    private func protectedImage(width: Int, height: Int, reason: String) throws -> CGImage {
        let key = "\(width)x\(height):\(reason)"
        if blockedImageKey == key, let blockedImage { return blockedImage }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let drawingContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RecorderError.renderBufferAllocationFailed
        }
        drawingContext.setFillColor(CGColor(gray: 0, alpha: 1))
        drawingContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, max(22, CGFloat(width) / 38), nil)
        let text = NSAttributedString(string: reason, attributes: [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 1)])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        drawingContext.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: (CGFloat(height) - bounds.height) / 2)
        CTLineDraw(line, drawingContext)
        guard let image = drawingContext.makeImage() else { throw RecorderError.renderImageCreationFailed }
        blockedImageKey = key
        blockedImage = image
        return image
    }

    private func failRecording(_ error: Error) {
        let url = outputURL
        let message = "Recording failed: \(error.localizedDescription)"
        terminalFailure = message
        writer?.cancelWriting()
        clearWriterState()
        if let url { try? FileManager.default.removeItem(at: url) }
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    private func clearWriterState() {
        pending = false
        finishing = false
        writer = nil
        input = nil
        adaptor = nil
        outputURL = nil
        blockedImage = nil
        blockedImageKey = ""
    }
}

enum RecorderError: LocalizedError {
    case missingOutputURL
    case cannotAddInput
    case cannotStart
    case writerFailed
    case pixelBufferPoolUnavailable
    case pixelBufferAllocationFailed(CVReturn)
    case renderBufferAllocationFailed
    case renderImageCreationFailed
    case appendFailed

    var errorDescription: String? {
        switch self {
        case .missingOutputURL: return "No recording destination is available."
        case .cannotAddInput: return "The video encoder input could not be configured."
        case .cannotStart: return "The video writer could not start."
        case .writerFailed: return "The video writer stopped unexpectedly."
        case .pixelBufferPoolUnavailable: return "The video buffer pool is unavailable."
        case .pixelBufferAllocationFailed(let code): return "A video frame buffer could not be allocated (\(code))."
        case .renderBufferAllocationFailed: return "The protected-frame rendering buffer could not be allocated."
        case .renderImageCreationFailed: return "The protected recording frame could not be created."
        case .appendFailed: return "A video frame could not be written."
        }
    }
}

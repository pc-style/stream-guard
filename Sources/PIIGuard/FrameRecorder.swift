import AVFoundation
import AppKit
import CoreImage
import CoreText

final class FrameRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.pcstyle.piiguard.recorder", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var fps = 10
    private var frameNumber: Int64 = 0
    private var pending = false
    private var blockedImage: CGImage?
    private var blockedImageKey = ""

    var isRecording: Bool { queue.sync { pending || writer != nil } }

    func start(url: URL, fps: Int) {
        queue.sync {
            self.outputURL = url
            self.fps = fps
            frameNumber = 0
            pending = true
            blockedImage = nil
        }
    }

    func append(_ source: CGImage, blockedReason: String?) {
        queue.async { [weak self] in
            guard let self, pending || writer != nil else { return }
            do {
                if writer == nil { try prepareWriter(width: source.width, height: source.height) }
                guard let writer, writer.status == .writing, let input, input.isReadyForMoreMediaData,
                      let adaptor, let pool = adaptor.pixelBufferPool else { return }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
                let image = blockedReason.map { self.protectedImage(width: source.width, height: source.height, reason: $0) } ?? source
                context.render(CIImage(cgImage: image), to: buffer, bounds: CGRect(x: 0, y: 0, width: source.width, height: source.height), colorSpace: CGColorSpaceCreateDeviceRGB())
                let time = CMTime(value: frameNumber, timescale: CMTimeScale(fps))
                if adaptor.append(buffer, withPresentationTime: time) { frameNumber += 1 }
            } catch {
                pending = false
                writer?.cancelWriting()
                writer = nil
            }
        }
    }

    func stop(completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            pending = false
            guard let writer else { DispatchQueue.main.async { completion(nil) }; return }
            input?.markAsFinished()
            let url = outputURL
            writer.finishWriting {
                self.queue.async {
                    self.writer = nil; self.input = nil; self.adaptor = nil; self.outputURL = nil
                    DispatchQueue.main.async { completion(writer.status == .completed ? url : nil) }
                }
            }
        }
    }

    private func prepareWriter(width: Int, height: Int) throws {
        guard let outputURL else { return }
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
        self.writer = writer; self.input = input; self.adaptor = adaptor; pending = false
    }

    private func protectedImage(width: Int, height: Int, reason: String) -> CGImage {
        let key = "\(width)x\(height):\(reason)"
        if blockedImageKey == key, let blockedImage { return blockedImage }
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, max(22, CGFloat(width) / 38), nil)
        let text = NSAttributedString(string: reason, attributes: [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 1)])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: (CGFloat(height) - bounds.height) / 2)
        CTLineDraw(line, context)
        let image = context.makeImage()!
        blockedImageKey = key; blockedImage = image
        return image
    }
}

enum RecorderError: Error { case cannotAddInput, cannotStart }

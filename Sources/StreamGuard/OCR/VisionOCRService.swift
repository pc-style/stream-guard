import CoreGraphics
import Foundation
import Vision
import StreamGuardCore

final class VisionOCRService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.pcstyle.stream-guard.ocr")
    private var config: OCRConfig

    init(config: OCRConfig) {
        self.config = config
    }

    func updateConfig(_ config: OCRConfig) {
        self.config = config
    }

    func recognize(image: CGImage, completion: @escaping (Result<[String], Error>) -> Void) {
        queue.async {
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let strings = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }
                completion(.success(strings))
            }
            request.recognitionLevel = self.config.recognitionLevel == "accurate" ? .accurate : .fast
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = self.config.minimumTextHeight

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                completion(.failure(error))
            }
        }
    }
}

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
        queue.async {
            self.config = config
        }
    }

    func recognize(image: CGImage, completion: @escaping (Result<[String], Error>) -> Void) {
        recognize(images: [image], completion: completion)
    }

    func recognize(images: [CGImage], completion: @escaping (Result<[String], Error>) -> Void) {
        queue.async {
            var allStrings: [String] = []
            do {
                for image in images {
                    var requestError: Error?
                    let request = self.makeTextRequest { result in
                        switch result {
                        case .success(let strings):
                            allStrings.append(contentsOf: strings)
                        case .failure(let error):
                            requestError = error
                        }
                    }
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])
                    if let requestError {
                        throw requestError
                    }
                }
                completion(.success(allStrings))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func makeTextRequest(collector: @escaping (Result<[String], Error>) -> Void) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                collector(.failure(error))
                return
            }
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            let strings = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            collector(.success(strings))
        }
        request.recognitionLevel = config.recognitionLevel == "accurate" ? .accurate : .fast
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = config.minimumTextHeight
        return request
    }
}

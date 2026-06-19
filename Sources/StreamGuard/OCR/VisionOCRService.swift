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

    func recognize(image: CGImage, completion: @escaping (Result<[OCRObservation], Error>) -> Void) {
        recognize(images: [image], completion: completion)
    }

    func recognize(images: [CGImage], completion: @escaping (Result<[OCRObservation], Error>) -> Void) {
        queue.async {
            do {
                let observations = try self.recognizeAll(images: images)
                completion(.success(observations))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Runs OCR crop-by-crop; `shouldStop` is invoked on the main queue after each crop.
    func recognizeSequential(
        images: [CGImage],
        shouldStop: @escaping ([OCRObservation]) -> Bool,
        completion: @escaping (Result<[OCRObservation], Error>) -> Void
    ) {
        queue.async {
            var allObservations: [OCRObservation] = []
            do {
                for image in images {
                    let cropObservations = try self.recognizeOne(image: image)
                    allObservations.append(contentsOf: cropObservations)
                    let stop = DispatchQueue.main.sync {
                        shouldStop(cropObservations)
                    }
                    if stop {
                        break
                    }
                }
                completion(.success(allObservations))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func recognizeAll(images: [CGImage]) throws -> [OCRObservation] {
        var allObservations: [OCRObservation] = []
        for image in images {
            allObservations.append(contentsOf: try recognizeOne(image: image))
        }
        return allObservations
    }

    private func recognizeOne(image: CGImage) throws -> [OCRObservation] {
        var requestError: Error?
        var observations: [OCRObservation] = []
        let request = makeTextRequest { result in
            switch result {
            case .success(let cropObservations):
                observations = cropObservations
            case .failure(let error):
                requestError = error
            }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        if let requestError {
            throw requestError
        }
        return observations
    }

    private func makeTextRequest(collector: @escaping (Result<[OCRObservation], Error>) -> Void) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                collector(.failure(error))
                return
            }
            let visionObservations = request.results as? [VNRecognizedTextObservation] ?? []
            let observations = visionObservations.compactMap { observation -> OCRObservation? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRObservation(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    boundingBox: NormalizedRect(observation.boundingBox)
                )
            }
            collector(.success(observations))
        }
        request.recognitionLevel = config.recognitionLevel == "accurate" ? .accurate : .fast
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = config.minimumTextHeight
        return request
    }
}

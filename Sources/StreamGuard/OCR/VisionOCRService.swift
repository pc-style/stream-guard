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
            do {
                let allStrings = try self.recognizeAll(images: images)
                completion(.success(allStrings))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Runs OCR crop-by-crop; `shouldStop` is invoked on the main queue after each crop.
    func recognizeSequential(
        images: [CGImage],
        shouldStop: @escaping ([String]) -> Bool,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        queue.async {
            var allStrings: [String] = []
            do {
                for image in images {
                    let cropStrings = try self.recognizeOne(image: image)
                    allStrings.append(contentsOf: cropStrings)
                    let stop = DispatchQueue.main.sync {
                        shouldStop(cropStrings)
                    }
                    if stop {
                        break
                    }
                }
                completion(.success(allStrings))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func recognizeAll(images: [CGImage]) throws -> [String] {
        var allStrings: [String] = []
        for image in images {
            allStrings.append(contentsOf: try recognizeOne(image: image))
        }
        return allStrings
    }

    private func recognizeOne(image: CGImage) throws -> [String] {
        var requestError: Error?
        var strings: [String] = []
        let request = makeTextRequest { result in
            switch result {
            case .success(let cropStrings):
                strings = cropStrings
            case .failure(let error):
                requestError = error
            }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        if let requestError {
            throw requestError
        }
        return strings
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

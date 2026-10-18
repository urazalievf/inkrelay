import Foundation
import Vision

/// On-device handwriting and text recognition with Apple's Vision framework. Nothing leaves the Mac.
public struct VisionTextRecognizer: TextRecognizer {
    public var config: RecognitionConfig

    public init(config: RecognitionConfig = RecognitionConfig()) {
        self.config = config
    }

    public func recognize(fileAt url: URL) throws -> [RecognizedPage] {
        let images = try PageRenderer.images(for: url, scale: config.renderScale, maxPixelDimension: config.maxPixelDimension)
        guard !images.isEmpty else { return [] }
        // Pages are independent, so a notebook is read `concurrency` pages at a time, in order of page number.
        let workers = max(1, min(config.concurrency, images.count))
        var results = [Result<RecognizedPage, Error>?](repeating: nil, count: images.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for index in stride(from: worker, to: images.count, by: workers) {
                let image = images[index]
                let result = Result { () throws -> RecognizedPage in
                    let text = try recognizeText(in: image)
                    return RecognizedPage(number: index + 1, text: text, isBlank: text.isEmpty && InkCoverage.isBlank(image))
                }
                lock.lock()
                results[index] = result
                lock.unlock()
            }
        }
        return try results.map { try $0!.get() }
    }

    func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = config.usesLanguageCorrection
        if !config.vocabulary.isEmpty { request.customWords = config.vocabulary }
        if config.languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = config.languages
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> TextLine? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return TextLine(text: text, box: observation.boundingBox)
        }
        return LayoutBuilder.text(from: lines)
    }

    /// Top to bottom, then left to right. Vision's coordinates put the origin at the bottom left.
    static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        observations.sorted { a, b in
            let lineTolerance = min(a.boundingBox.height, b.boundingBox.height) / 2
            if abs(a.boundingBox.midY - b.boundingBox.midY) > lineTolerance {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
    }
}

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
        return try images.enumerated().map { index, image in
            RecognizedPage(number: index + 1, text: try recognizeText(in: image))
        }
    }

    func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = config.usesLanguageCorrection
        if !config.languages.isEmpty {
            request.recognitionLanguages = config.languages
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        return Self.readingOrder(observations).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
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

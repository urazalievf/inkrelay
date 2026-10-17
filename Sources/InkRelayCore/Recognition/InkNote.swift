import Foundation

/// One tablet export after recognition: the unit every destination receives.
public struct InkNote: Equatable {
    public var title: String
    public var sourceID: String
    public var device: String
    /// The export on disk.
    public var originalURL: URL
    /// Path relative to the source folder, used to mirror folder structure in destinations.
    public var relativePath: String
    public var modified: Date
    public var contentHash: String
    public var pages: [RecognizedPage]

    public init(
        title: String,
        sourceID: String,
        device: String,
        originalURL: URL,
        relativePath: String,
        modified: Date,
        contentHash: String,
        pages: [RecognizedPage]
    ) {
        self.title = title
        self.sourceID = sourceID
        self.device = device
        self.originalURL = originalURL
        self.relativePath = relativePath
        self.modified = modified
        self.contentHash = contentHash
        self.pages = pages
    }
}

public struct RecognizedPage: Equatable {
    /// 1-based, as people count pages.
    public var number: Int
    public var text: String
    /// From AI transcription only: a title in the writer's words, and topic tags.
    public var suggestedTitle: String?
    public var tags: [String]

    public init(number: Int, text: String, suggestedTitle: String? = nil, tags: [String] = []) {
        self.number = number
        self.text = text
        self.suggestedTitle = suggestedTitle
        self.tags = tags
    }
}

/// Turns an export (PDF or image) into text, page by page.
public protocol TextRecognizer {
    func recognize(fileAt url: URL) throws -> [RecognizedPage]
}

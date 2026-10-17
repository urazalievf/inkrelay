import Foundation

/// What a destination does with a note whose export was deleted from its folder.
public enum RemovalPolicy: String, Codable, Equatable {
    /// Leave the note alone (the default).
    case keep
    /// Move it out of the way: an archive folder in Obsidian and Notes. Destinations without archives keep it.
    case archive
    /// Remove it, recoverably where the app allows: Obsidian files go to the Trash, Notes to Recently Deleted,
    /// Google Docs to the Drive trash, review cards are dropped, calendar events are deleted.
    case delete
}

/// The export that went away, as destinations need it to find their copy.
public struct RemovedExport: Equatable {
    public var sourceID: String
    public var relativePath: String

    public init(sourceID: String, relativePath: String) {
        self.sourceID = sourceID
        self.relativePath = relativePath
    }

    public var title: String { ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension }
}

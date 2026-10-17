import Foundation

/// Turns exports that aren't PDFs or images into PDFs InkRelay can read, cached by sync key.
/// Today that's Supernote's native `.note`, which its Dropbox, Google Drive and OneDrive sync writes as-is.
public enum ExportConverter {
    public static let nativeTypes: Set<String> = ["note"]

    /// The file itself, or a fresh PDF made from it.
    public static func readableURL(for url: URL, key: String, cache: URL) throws -> URL {
        guard nativeTypes.contains(url.pathExtension.lowercased()) else { return url }
        let output = cachedURL(for: key, cache: cache)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SupernoteNote(data: Data(contentsOf: url)).writePDF(to: output)
        return output
    }

    static func cachedURL(for key: String, cache: URL) -> URL {
        cache.appendingPathComponent((key as NSString).deletingPathExtension + ".pdf")
    }

    static func discard(key: String, cache: URL) {
        try? FileManager.default.removeItem(at: cachedURL(for: key, cache: cache))
    }
}

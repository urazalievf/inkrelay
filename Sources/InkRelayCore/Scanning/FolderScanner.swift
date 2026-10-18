import Foundation

/// A tablet export found in a source folder.
public struct ScannedFile: Equatable {
    public var url: URL
    /// Path relative to the source folder, with `/` separators. Used as the sync key.
    public var relativePath: String
    public var size: Int64
    public var modified: Date
}

/// Lists the exports in a source folder, recursively, skipping hidden files and cloud-client temp files.
public enum FolderScanner {
    public static func scan(_ source: SourceConfig, fileManager: FileManager = .default) throws -> [ScannedFile] {
        let root = source.url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScanError.folderMissing(source.id, root.path)
        }

        let types = Set(source.fileTypes.map { $0.lowercased() })
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let filtered = !source.exclude.isEmpty || !source.folders.isEmpty
        // A folder macOS won't let InkRelay read still enumerates, as empty; the error handler is the only sign.
        var rootError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                if url.standardizedFileURL.resolvingSymlinksInPath().path == root.path { rootError = error }
                return true
            }
        ) else {
            throw ScanError.folderMissing(source.id, root.path)
        }

        var files: [ScannedFile] = []
        for case let url as URL in enumerator {
            if filtered, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if !source.entersFolder(relativePath(of: url.standardizedFileURL.resolvingSymlinksInPath(), in: root)) { enumerator.skipDescendants() }
                continue
            }
            guard types.contains(url.pathExtension.lowercased()) else { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            if filtered, !source.includes(relativePath(of: resolved, in: root)) { continue }
            files.append(ScannedFile(
                url: resolved,
                relativePath: relativePath(of: resolved, in: root),
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        if files.isEmpty, let rootError { throw ScanError.unreadable(source.id, root.path, rootError.localizedDescription) }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// What's in a folder by file type, for explaining a source that finds nothing. Reads at most `limit` entries.
    public static func census(of folder: URL, fileManager: FileManager = .default, limit: Int = 500) -> (counts: [String: Int], total: Int) {
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([:], 0)
        }
        var counts: [String: Int] = [:]
        var total = 0
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            total += 1
            counts[url.pathExtension.isEmpty ? "(none)" : url.pathExtension.lowercased(), default: 0] += 1
            if total >= limit { break }
        }
        return (counts, total)
    }

    static func relativePath(of url: URL, in root: URL) -> String {
        let rootComponents = root.pathComponents
        let components = url.pathComponents
        guard components.starts(with: rootComponents) else { return url.lastPathComponent }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

public enum ScanError: Error, LocalizedError {
    case folderMissing(String, String)
    case unreadable(String, String, String)

    public var errorDescription: String? {
        switch self {
        case .folderMissing(let id, let path):
            return "Source \"\(id)\": no folder at \(path). Check the path, and that the cloud app (Google Drive, Dropbox or OneDrive) is running."
        case .unreadable(let id, let path, let reason):
            return "Source \"\(id)\": \(path) can't be read (\(reason)). Allow InkRelay in System Settings → Privacy & Security → Files and Folders."
        }
    }
}

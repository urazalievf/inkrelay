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
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ScanError.folderMissing(source.id, root.path)
        }

        var files: [ScannedFile] = []
        for case let url as URL in enumerator {
            guard types.contains(url.pathExtension.lowercased()) else { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            files.append(ScannedFile(
                url: resolved,
                relativePath: relativePath(of: resolved, in: root),
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
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

    public var errorDescription: String? {
        switch self {
        case .folderMissing(let id, let path):
            return "Source \"\(id)\": no folder at \(path). Check the path, and that the cloud app (Google Drive, Dropbox or OneDrive) is running."
        }
    }
}

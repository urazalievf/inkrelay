import Foundation

/// Shared constants for InkRelay.
public enum InkRelayCore {
    public static let version = "0.2.0"

    /// `~/Library/Application Support/InkRelay`, where the config and sync state live.
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/InkRelay", isDirectory: true)
    }

    public static var defaultConfigURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    public static var defaultStateURL: URL {
        supportDirectory.appendingPathComponent("state.json")
    }
}

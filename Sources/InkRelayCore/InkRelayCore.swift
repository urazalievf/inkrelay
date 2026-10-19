import Foundation

/// Shared constants for InkRelay.
public enum InkRelayCore {
    public static let version = "0.10.1"

    /// `~/Library/Application Support/InkRelay`, where the config and sync state live.
    /// The user's home folder on the Mac; the app's own container on iPhone and iPad.
    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static var supportDirectory: URL {
        home
            .appendingPathComponent("Library/Application Support/InkRelay", isDirectory: true)
    }

    public static var defaultConfigURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    public static var defaultStateURL: URL {
        supportDirectory.appendingPathComponent("state.json")
    }
}

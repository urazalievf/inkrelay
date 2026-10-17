import Foundation

/// Reads and writes `config.json`.
public enum ConfigStore {
    public static func load(from url: URL = InkRelayCore.defaultConfigURL) throws -> RelayConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConfigError.missing(url) }
        let data = try Data(contentsOf: url)
        let config: RelayConfig
        do {
            config = try JSONDecoder().decode(RelayConfig.self, from: data)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.invalid("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        try config.validate()
        return config
    }

    public static func save(_ config: RelayConfig, to url: URL = InkRelayCore.defaultConfigURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    /// A starting config that points at the usual Google Drive and iCloud Obsidian locations.
    /// The paths are placeholders the user edits before the first sync.
    public static var example: RelayConfig {
        RelayConfig(
            sources: [
                SourceConfig(
                    id: "viwoods",
                    device: "Viwoods AiPaper",
                    path: "~/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/Viwoods"
                ),
            ],
            destinations: [
                .obsidian(.init(
                    id: "obsidian",
                    vaultPath: "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault"
                )),
                .appleNotes(.init(id: "apple-notes")),
                .reviewStack(.init(id: "review")),
            ]
        )
    }
}

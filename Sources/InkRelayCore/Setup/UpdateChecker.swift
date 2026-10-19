import Foundation

/// A published release, as the release feed describes it.
public struct ReleaseInfo: Equatable {
    public var version: String
    /// The release page, where the download is.
    public var url: URL
    public var notes: String

    public init(version: String, url: URL, notes: String = "") {
        self.version = version
        self.url = url
        self.notes = notes
    }
}

/// Asks the release feed for the newest version. Nothing about this Mac is sent: it's one GET with no body,
/// no identifier and no cookies, once a day at most.
public struct UpdateChecker {
    /// The public repository that holds only the release downloads; the source repository is private, so its
    /// releases answer 404 to everyone else. The release workflow publishes here and the site links here.
    public static let releasesRepository = "urazalievf/inkrelay-releases"
    public static let feed = URL(string: "https://api.github.com/repos/\(releasesRepository)/releases?per_page=5")!
    /// Where people download by hand, when the feed has no release yet.
    public static let downloads = URL(string: "https://github.com/\(releasesRepository)/releases")!

    let feedURL: URL
    let transport: HTTPTransport

    public init(feedURL: URL = UpdateChecker.feed, transport: HTTPTransport = URLSessionTransport()) {
        self.feedURL = feedURL
        self.transport = transport
    }

    /// The newest published release, or nil when none has been published. A feed that can't be read (a private
    /// or renamed repository answers 404) is an error, never "up to date".
    public func latest() throws -> ReleaseInfo? {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("InkRelay/\(InkRelayCore.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try transport.send(request)
        guard response.statusCode == 200 else { throw UpdateError.feedUnavailable(response.statusCode) }
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UpdateError.feedUnavailable(response.statusCode)
        }
        for object in list where object["draft"] as? Bool != true && object["prerelease"] as? Bool != true {
            guard let tag = object["tag_name"] as? String, let page = (object["html_url"] as? String).flatMap(URL.init(string:)) else { continue }
            return ReleaseInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: page, notes: object["body"] as? String ?? "")
        }
        return nil
    }

    /// A release newer than `current`, or nil.
    public func check(current: String = InkRelayCore.version) throws -> ReleaseInfo? {
        guard let release = try latest(), Self.isNewer(release.version, than: current) else { return nil }
        return release
    }

    /// `MAJOR.MINOR.PATCH[.FIX]`, compared number by number; a missing FIX is 0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            var numbers = version.split(separator: ".").map { Int($0) ?? 0 }
            while numbers.count < 4 { numbers.append(0) }
            return numbers
        }
        let a = parts(candidate), b = parts(current)
        for (x, y) in zip(a, b) where x != y { return x > y }
        return false
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case feedUnavailable(Int)

    public var errorDescription: String? {
        switch self {
        case .feedUnavailable(let status):
            return status == 404
                ? "The release feed couldn't be read (404), so InkRelay can't tell whether it's up to date. Look at \(UpdateChecker.downloads.absoluteString)."
                : "The release feed answered \(status). Try again later, or look at \(UpdateChecker.downloads.absoluteString)."
        }
    }
}

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
    public static let feed = URL(string: "https://api.github.com/repos/urazalievf/inkrelay/releases/latest")!
    /// Where people download by hand, when the feed has no release yet.
    public static let downloads = URL(string: "https://github.com/urazalievf/inkrelay/releases")!

    let feedURL: URL
    let transport: HTTPTransport

    public init(feedURL: URL = UpdateChecker.feed, transport: HTTPTransport = URLSessionTransport()) {
        self.feedURL = feedURL
        self.transport = transport
    }

    /// The newest release, or nil when none has been published.
    public func latest() throws -> ReleaseInfo? {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("InkRelay/\(InkRelayCore.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try transport.send(request)
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw UpdateError.feedUnavailable(response.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw UpdateError.feedUnavailable(response.statusCode)
        }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { return nil }
        return ReleaseInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: page, notes: object["body"] as? String ?? "")
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
        case .feedUnavailable(let status): return "The release feed answered \(status). Try again later, or look at \(UpdateChecker.downloads.absoluteString)."
        }
    }
}

import Foundation

// The shapes Viwoods Cloud returns. Only the fields InkRelay reads are declared; everything else is ignored.

/// One of the tablet's apps, as listed by `resourceSync/getRootFolder`.
public struct ViwoodsRootFolder: Decodable, Equatable {
    public var name: String
    public var appType: Int
    public var count: Int
}

/// The apps InkRelay can pull. Values are the cloud's `appType` numbers.
public enum ViwoodsApp: Int, CaseIterable {
    case paper = 1
    case meeting = 2
    case knowledgeBase = 4
    case memo = 6

    public init?(name: String) {
        switch name.lowercased() {
        case "paper": self = .paper
        case "meeting": self = .meeting
        case "memo": self = .memo
        case "knowledgebase", "knowledge base": self = .knowledgeBase
        default: return nil
        }
    }

    /// Folder name under the cache, mirrored into destinations.
    public var folderName: String {
        switch self {
        case .paper: return "Paper"
        case .meeting: return "Meeting"
        case .knowledgeBase: return "Knowledge Base"
        case .memo: return "Memo"
        }
    }
}

/// Where sent files land: Learning (the reader) or Paper (notebooks you can write on). Values are app types.
public enum ViwoodsImportTarget: Int, Codable {
    case paper = 1
    case learning = 3

    var folderType: String { self == .paper ? "paper" : "learning" }

    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self).lowercased() {
        case "paper": self = .paper
        case "learning": self = .learning
        default: throw ConfigError.invalid("viwoodsCloud send targets take \"app\": \"learning\" or \"paper\".")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(folderType)
    }
}

/// One page of `resourceSync/getPage`: the files and folders inside one cloud folder.
public struct ViwoodsResourcePage: Decodable, Equatable {
    public var count: Int
    public var list: [ViwoodsResource]
}

public struct ViwoodsResource: Decodable, Equatable {
    public var resourceId: String
    public var name: String
    public var resourceType: Int
    public var lastModifiedTime: Int64?
    public var isDelete: Int?
    public var encrypt: Int?
    public var childSize: Int?

    static let folderType = 0
    static let templateFolderType = 5

    public var isFolder: Bool { resourceType == Self.folderType && !resourceId.isEmpty }
    /// Template folders and the virtual tabs of Knowledge Base have nothing InkRelay can pull.
    public var isSkippable: Bool { resourceType == Self.templateFolderType || resourceId.isEmpty || isDelete == 1 }
    public var isEncrypted: Bool { encrypt == 1 }
}

/// A Paper or Meeting notebook from `paperSync/get` and `meetingSync/get`, after inflating the gzip body.
public struct ViwoodsNotebook: Decodable, Equatable {
    public struct Info: Decodable, Equatable {
        public var id: String
        public var fileName: String
        public var lastModifiedTime: Int64?
        public var userModifiedTime: Int64?
        public var isDeleted: Int?
    }

    public struct PageEntry: Decodable, Equatable {
        public var page: PageInfo
    }

    public struct PageInfo: Decodable, Equatable {
        public var id: String
        public var order: Int
        public var isDeleted: Int?
    }

    /// Where each page's files live on the CDN. `fileName` tells the kind: `screenshotBmp_<page>.png` is the
    /// rendered page, `mainBmp_` the ink layer alone, `path_` the strokes, `Thumbnail_` the preview.
    public struct ResourceRef: Decodable, Equatable {
        public var fileName: String
        public var remoteUrl: String
        public var ownerPageId: String?
    }

    public var note: Info
    public var pages: [PageEntry]
    public var resourceRefs: [ResourceRef]

    /// The rendered image of each live page, in reading order.
    public func pageImageURLs() -> [URL] {
        let live = pages.filter { $0.page.isDeleted != 1 }.sorted { $0.page.order < $1.page.order }
        return live.compactMap { entry in
            let refs = resourceRefs.filter { $0.ownerPageId == entry.page.id }
            let chosen = refs.first { $0.fileName.hasPrefix("screenshotBmp_") }
                ?? refs.first { $0.fileName.hasPrefix("mainBmp_") }
            return chosen.flatMap { URL(string: $0.remoteUrl) }
        }
    }
}

/// A memo from `memoSync/get`, after inflating the gzip body.
public struct ViwoodsMemo: Decodable, Equatable {
    public struct Info: Decodable, Equatable {
        public var id: String
        public var fileName: String
        public var lastModifiedTime: Int64?
    }

    public struct Page: Decodable, Equatable {
        public var id: String
        public var order: Int
        /// Rendered page image on the CDN.
        public var pageShotFileName: String?
        public var pageFileName: String?
    }

    public var memoFileInfo: Info
    public var memoPageInfos: [Page]

    public func pageImageURLs() -> [URL] {
        memoPageInfos.sorted { $0.order < $1.order }.compactMap { page in
            (page.pageShotFileName ?? page.pageFileName).flatMap { URL(string: $0) }
        }
    }
}

/// `resourceDailySync/getDateList`: which days of a month have planner content.
public struct ViwoodsDailyDate: Decodable, Equatable {
    public var date: String
    public var hasTaskNote: Bool?
    public var hasTodo: Bool?
}

/// `resourceDailySync/getList`: the planner's entries for a date range and type.
public struct ViwoodsDailyItem: Decodable, Equatable {
    public var id: String
    public var date: String
    public var name: String?
    public var type: Int
    public var pageOrder: Int?
    public var isFinish: Int?
    public var lastModifiedTime: Int64?
    /// Rendered page image for handwritten entries.
    public var url: String?
    public var content: String?
    /// 0 important and urgent, 1 urgent, 2 important, anything else none.
    public var level: Int?
    public var classification: Int?
    public var isDelete: Int?

    public enum Kind: Int {
        /// Handwritten pages on the Notes tab.
        case notes = 0
        /// Handwritten day pages on the Tasks tab.
        case tasks = 1
        /// Typed to-do items.
        case todo = 2
    }
}

/// Planner dates arrive as `2026-1-13`; destinations want `2026-01-13`.
public enum ViwoodsDate {
    public static func normalize(_ text: String) -> String? {
        let parts = text.split(separator: "-").map(String.init)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

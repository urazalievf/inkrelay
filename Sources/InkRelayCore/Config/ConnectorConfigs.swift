import Foundation

extension DestinationConfig {
    /// Planner pages and to-dos as all-day events in a Google calendar InkRelay creates. Needs the `google` section.
    public struct GoogleCalendarConfig: Codable, Equatable {
        public var id: String
        /// Name of the calendar InkRelay creates in the account.
        public var calendar: String
        public var pageTitle: String

        public init(id: String, calendar: String = "Viwoods", pageTitle: String = "Daily plan") {
            self.id = id
            self.calendar = calendar
            self.pageTitle = pageTitle
        }

        private enum CodingKeys: String, CodingKey { case id, calendar, pageTitle }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            calendar = try container.decodeIfPresent(String.self, forKey: .calendar) ?? "Viwoods"
            pageTitle = try container.decodeIfPresent(String.self, forKey: .pageTitle) ?? "Daily plan"
        }
    }

    /// Each note as a Google Doc in a Drive folder InkRelay creates. Needs the `google` section.
    public struct GoogleDocsConfig: Codable, Equatable {
        public var id: String
        public var folder: String

        public init(id: String, folder: String = "Ink") {
            self.id = id
            self.folder = folder
        }

        private enum CodingKeys: String, CodingKey { case id, folder }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? "Ink"
        }
    }

    /// Planner pages and to-dos as all-day events in an Outlook calendar. Needs the `microsoft` section.
    public struct OutlookCalendarConfig: Codable, Equatable {
        public var id: String
        /// Found by name, created if missing.
        public var calendar: String
        public var pageTitle: String
        /// IANA name such as `America/Chicago`. Missing uses the Mac's time zone.
        public var timeZone: String?

        public init(id: String, calendar: String = "Viwoods", pageTitle: String = "Daily plan", timeZone: String? = nil) {
            self.id = id
            self.calendar = calendar
            self.pageTitle = pageTitle
            self.timeZone = timeZone
        }

        private enum CodingKeys: String, CodingKey { case id, calendar, pageTitle, timeZone }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            calendar = try container.decodeIfPresent(String.self, forKey: .calendar) ?? "Viwoods"
            pageTitle = try container.decodeIfPresent(String.self, forKey: .pageTitle) ?? "Daily plan"
            timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
        }
    }

    /// Each note as a OneNote page with its page images. Needs the `microsoft` section.
    public struct OneNoteConfig: Codable, Equatable {
        public var id: String
        /// Found by name, created if missing.
        public var notebook: String

        public init(id: String, notebook: String = "Ink") {
            self.id = id
            self.notebook = notebook
        }

        private enum CodingKeys: String, CodingKey { case id, notebook }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            notebook = try container.decodeIfPresent(String.self, forKey: .notebook) ?? "Ink"
        }
    }

    /// The read-later stack: every new or changed page and every to-do becomes a card to go through
    /// at http://127.0.0.1:<port> while `inkrelay watch` runs, or with `inkrelay review open`.
    public struct ReviewStackConfig: Codable, Equatable {
        public var id: String
        public var port: Int
        /// At most this many cards a day; the rest wait for tomorrow.
        public var dailyLimit: Int
        /// Bring a card back this many days after each "Done", in order. Empty means done is done.
        public var resurfaceDays: [Int]

        public init(id: String, port: Int = 7788, dailyLimit: Int = 25, resurfaceDays: [Int] = []) {
            self.id = id
            self.port = port
            self.dailyLimit = dailyLimit
            self.resurfaceDays = resurfaceDays
        }

        private enum CodingKeys: String, CodingKey { case id, port, dailyLimit, resurfaceDays }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 7788
            dailyLimit = try container.decodeIfPresent(Int.self, forKey: .dailyLimit) ?? 25
            resurfaceDays = try container.decodeIfPresent([Int].self, forKey: .resurfaceDays) ?? []
        }

        func validate() throws {
            guard (1024...65535).contains(port) else { throw ConfigError.invalid("reviewStack.port must be between 1024 and 65535.") }
            guard dailyLimit >= 1 else { throw ConfigError.invalid("reviewStack.dailyLimit must be at least 1.") }
            guard resurfaceDays.allSatisfy({ $0 >= 1 }) else { throw ConfigError.invalid("reviewStack.resurfaceDays must be whole days, 1 or more.") }
        }
    }

    /// Each note as a Notion page, under `parentPageId` or as a row of `databaseId` (one of the two).
    /// The integration token is kept in the Keychain by `inkrelay notion login`.
    public struct NotionConfig: Codable, Equatable {
        public var id: String
        public var parentPageId: String?
        public var databaseId: String?
        /// Upload the page images as well as the text.
        public var includeImages: Bool

        public init(id: String, parentPageId: String? = nil, databaseId: String? = nil, includeImages: Bool = true) {
            self.id = id
            self.parentPageId = parentPageId
            self.databaseId = databaseId
            self.includeImages = includeImages
        }

        private enum CodingKeys: String, CodingKey { case id, parentPageId, databaseId, includeImages }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            parentPageId = try container.decodeIfPresent(String.self, forKey: .parentPageId)
            databaseId = try container.decodeIfPresent(String.self, forKey: .databaseId)
            includeImages = try container.decodeIfPresent(Bool.self, forKey: .includeImages) ?? true
        }

        func validate() throws {
            guard (parentPageId == nil) != (databaseId == nil) else {
                throw ConfigError.invalid("Notion destination \"\(id)\" needs exactly one of parentPageId or databaseId.")
            }
        }
    }

    /// Tasks written on pages, and Viwoods Daily to-dos, as Apple Reminders.
    public struct AppleRemindersConfig: Codable, Equatable {
        public var id: String
        /// List name; `{device}` and `{source}` are filled in, so each tablet can have its own list.
        public var list: String

        public init(id: String, list: String = "Ink") {
            self.id = id
            self.list = list
        }

        private enum CodingKeys: String, CodingKey { case id, list }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            list = try container.decodeIfPresent(String.self, forKey: .list) ?? "Ink"
        }
    }

    var needsGoogle: Bool {
        switch self {
        case .googleCalendar, .googleDocs: return true
        default: return false
        }
    }

    var needsMicrosoft: Bool {
        switch self {
        case .outlookCalendar, .oneNote: return true
        default: return false
        }
    }
}

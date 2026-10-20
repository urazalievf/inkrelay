import CryptoKit
import Foundation

/// What this install may use: everything, for the trial or with a license, or the free parts.
public struct Entitlement: Equatable {
    public enum Plan: Equatable {
        case pro
        case free
    }

    public enum Basis: Equatable {
        case license(License)
        /// The trial's last day.
        case trial(endsAt: Date)
        case trialEnded(Date)
        case none
    }

    public var plan: Plan
    public var basis: Basis
    /// Why a key on file doesn't count (expired, changed, unreadable), when there is one. The plan is then the
    /// trial or free, and this says why instead of asking for a key the person already entered.
    public var rejection: String?
    /// A genuine key on file whose time is up, usually a yearly key not yet followed by its renewal key. People
    /// are asked to renew rather than told their key was refused. `rejection` still says it expired.
    public var expiredLicense: License?

    /// How many days before a key's last day the menu starts saying a renewal key is due.
    public static let renewalNoticeDays = 14

    public static let pro = Entitlement(plan: .pro, basis: .none)
    public static let free = Entitlement(plan: .free, basis: .none)

    public init(plan: Plan, basis: Basis, rejection: String? = nil, expiredLicense: License? = nil) {
        self.plan = plan
        self.basis = basis
        self.rejection = rejection
        self.expiredLicense = expiredLicense
    }

    public var isPro: Bool { plan == .pro }

    /// When the trial ended, if it did.
    public var trialEndedOn: Date? {
        if case .trialEnded(let date) = basis { return date }
        return nil
    }

    /// Whole days left in the trial, rounded up; nil outside a trial.
    public func trialDaysLeft(now: Date = Date()) -> Int? {
        guard case .trial(let endsAt) = basis else { return nil }
        return max(Int((endsAt.timeIntervalSince(now) / 86_400).rounded(.up)), 0)
    }

    /// One line for the menu and `inkrelay license`.
    public func summary(now: Date = Date()) -> String {
        if let expiredLicense, !isPro { return "Free; Pro for \(expiredLicense.name) ended \(expiredLicense.expiryText(style: .abbreviated) ?? "")" }
        if let rejection, !isPro { return "Free; the key on file wasn't accepted (\(rejection))" }
        switch basis {
        case .license(let license):
            if let until = license.expiryText(style: .abbreviated) {
                return "Pro, licensed to \(license.name) until \(until)"
            }
            return "Pro, licensed to \(license.name)"
        case .trial(let endsAt):
            let hoursLeft = endsAt.timeIntervalSince(now) / 3600
            if hoursLeft <= 24 { return "Pro trial, last day" }
            let days = Int((hoursLeft / 24).rounded(.up))
            return "Pro trial, \(days) day\(days == 1 ? "" : "s") left"
        case .trialEnded(let date):
            return "Free; the Pro trial ended \(date.formatted(date: .abbreviated, time: .omitted))"
        case .none:
            return plan == .pro ? "Pro" : "Free"
        }
    }
}

/// Which parts need Pro. Free covers what a Mac can do alone: export folders, Obsidian and the Apple apps.
public enum ProFeatures {
    /// What the plan means for this config, in one line: what pauses when the trial ends, or that nothing does.
    public static func outlook(for config: RelayConfig?, entitlement: Entitlement, now: Date = Date()) -> String? {
        guard let config else { return nil }
        let used = used(in: config)
        switch entitlement.basis {
        case .license(let license):
            // A yearly key near its end: the renewal emails the next key, and entering it keeps everything running.
            guard let days = license.daysLeft(at: now), days <= Entitlement.renewalNoticeDays, !used.isEmpty else { return nil }
            let when = days <= 0 ? "today" : "on \(license.expiryText(style: .abbreviated) ?? "")"
            return "Pro ends \(when). Renewing emails a new key; enter it and nothing pauses."
        case .trial:
            return used.isEmpty ? "Everything you use is in Free; nothing stops when the trial ends." : "After the trial: " + used.joined(separator: ", ") + " pause."
        case .trialEnded, .none:
            return used.isEmpty ? nil : "Paused: " + used.joined(separator: ", ") + "."
        }
    }

    public static func isPro(_ destination: DestinationConfig) -> Bool {
        switch destination {
        case .obsidian, .appleNotes, .appleCalendar, .appleReminders: return false
        case .googleCalendar, .googleDocs, .outlookCalendar, .oneNote, .notion, .reviewStack: return true
        }
    }

    /// The Pro parts a config uses, named for people.
    public static func used(in config: RelayConfig) -> [String] {
        var names: [String] = []
        if config.viwoodsCloud != nil { names.append("Viwoods Cloud") }
        if config.kindleMail != nil { names.append("Kindle by email") }
        if config.allSources.contains(where: { $0.recognizer == .claude }) { names.append("AI transcription") }
        for destination in config.destinations where isPro(destination) {
            let name = displayName(destination)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// What people call a destination, rather than its id.
    public static func displayName(_ destination: DestinationConfig) -> String {
        switch destination {
        case .reviewStack: return "review stack"
        case .googleCalendar: return "Google Calendar"
        case .googleDocs: return "Google Docs"
        case .outlookCalendar: return "Outlook Calendar"
        case .oneNote: return "OneNote"
        case .notion: return "Notion"
        case .obsidian: return "Obsidian"
        case .appleNotes: return "Apple Notes"
        case .appleCalendar: return "Apple Calendar"
        case .appleReminders: return "Apple Reminders"
        }
    }
}

/// Reads the license and the trial from the files beside the config, and writes the trial's start on first use.
public struct EntitlementStore {
    public static let trialDays = 14

    public let supportDirectory: URL
    let publicKey: Curve25519.Signing.PublicKey?

    public init(supportDirectory: URL, publicKey: Curve25519.Signing.PublicKey? = LicensePublisher.publicKey) {
        self.supportDirectory = supportDirectory
        self.publicKey = publicKey
    }

    var licenseURL: URL { supportDirectory.appendingPathComponent("license.json") }
    var trialURL: URL { supportDirectory.appendingPathComponent("trial.json") }

    struct LicenseFile: Codable {
        var key: String
    }

    struct TrialFile: Codable {
        var startedAt: Date
    }

    /// The license on file, checked again every time so a tampered or expired file never passes.
    public func license(now: Date = Date()) throws -> License? {
        guard let data = try? Data(contentsOf: licenseURL) else { return nil }
        let file = try JSONDecoder().decode(LicenseFile.self, from: data)
        let license = try verify(file.key)
        guard license.isValid(at: now) else { throw LicenseError.expired(license.expiryText() ?? "") }
        return license
    }

    public func verify(_ key: String) throws -> License {
        guard let publicKey else { throw LicenseError.badSignature }
        return try LicenseKey.verify(key, publicKey: publicKey)
    }

    /// Checks the key and keeps it. Returns the license it carries.
    @discardableResult
    public func enter(_ key: String, now: Date = Date()) throws -> License {
        let license = try verify(key)
        guard license.isValid(at: now) else { throw LicenseError.expired(license.expiryText() ?? "") }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(LicenseFile(key: key.filter { !$0.isWhitespace }))
        try data.write(to: licenseURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: licenseURL.path)
        return license
    }

    public func remove() {
        try? FileManager.default.removeItem(at: licenseURL)
    }

    /// The key on file when it's genuine but past its last day, or nil.
    public func expiredLicense(now: Date = Date()) -> License? {
        guard let data = try? Data(contentsOf: licenseURL), let file = try? JSONDecoder().decode(LicenseFile.self, from: data),
              let license = try? verify(file.key), !license.isValid(at: now) else { return nil }
        return license
    }

    /// Why a key on file doesn't count, or nil when there's none or it's fine.
    public func licenseProblem(now: Date = Date()) -> String? {
        guard FileManager.default.fileExists(atPath: licenseURL.path) else { return nil }
        do {
            _ = try license(now: now)
            return nil
        } catch let error as LicenseError {
            return error.localizedDescription
        } catch {
            return "license.json beside the config can't be read; enter the key again"
        }
    }

    /// When the trial started; the first call starts it.
    public func trialStart(now: Date = Date()) -> Date {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: trialURL), let file = try? decoder.decode(TrialFile.self, from: data) {
            return file.startedAt
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? encoder.encode(TrialFile(startedAt: now)).write(to: trialURL, options: .atomic)
        return now
    }

    public func current(now: Date = Date()) -> Entitlement {
        // The trial clock starts on the first run, licensed or not, so an expired license doesn't open a fresh trial.
        let start = trialStart(now: now)
        if let license = try? license(now: now) {
            return Entitlement(plan: .pro, basis: .license(license))
        }
        let rejection = licenseProblem(now: now)
        let expired = expiredLicense(now: now)
        let endsAt = Calendar.current.date(byAdding: .day, value: Self.trialDays, to: start) ?? start
        if now < endsAt { return Entitlement(plan: .pro, basis: .trial(endsAt: endsAt), rejection: rejection, expiredLicense: expired) }
        return Entitlement(plan: .free, basis: .trialEnded(endsAt), rejection: rejection, expiredLicense: expired)
    }
}

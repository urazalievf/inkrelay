import Foundation
import InkRelayCore

let usage = """
inkrelay \(InkRelayCore.version): relay handwritten notes from e-ink tablets into Apple Notes and Obsidian

Usage:
  inkrelay setup                    Set up step by step: tablet, folders, vault, Apple apps
  inkrelay doctor [--notes-roundtrip] [--no-apps]
                                    Check folders, permissions, sign-ins and the background agent
  inkrelay init [--config PATH]     Write an example config to edit
  inkrelay sync [--config PATH]     Sync once and exit
  inkrelay watch [--config PATH]    Sync now, then whenever a source folder changes
  inkrelay status [--config PATH]   Show sources, destinations and what's been synced
  inkrelay viwoods login            Save a Viwoods Cloud token copied from cloud.viwoods.com
  inkrelay viwoods pull             Pull Viwoods Cloud into the local cache without syncing
  inkrelay google login             Sign in to Google for the googleCalendar and googleDocs destinations
  inkrelay microsoft login          Sign in to Microsoft for the outlookCalendar and oneNote destinations
  inkrelay notion login             Save a Notion integration token in the Keychain
  inkrelay ai login                 Save an Anthropic API key for AI transcription
  inkrelay ai status                This month's AI transcription spend
  inkrelay send LINK|FILE [--to ID] Send an article or document to the tablet (EPUB or PDF)
  inkrelay convert NOTE PDF          Turn a Supernote .note notebook into a PDF
  inkrelay mcp                      Serve InkRelay to AI assistants over MCP (stdio)
  inkrelay review                   List today's read-later stack
  inkrelay review open              Open the stack in the browser (serves it until Ctrl-C)
  inkrelay review done|later ID     Mark a card done, or push it to tomorrow
  inkrelay version

The config lives at \(InkRelayCore.defaultConfigURL.path) unless --config says otherwise.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func log(_ message: String) {
    let time = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    print("[\(time)] \(message)")
}

// Line-buffer stdout so `watch` logs reach a file (the launch agent's log) as they happen.
setvbuf(stdout, nil, _IOLBF, 0)

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "help" : arguments.removeFirst()

var configURL = InkRelayCore.defaultConfigURL
if let flag = arguments.firstIndex(of: "--config") {
    guard arguments.indices.contains(flag + 1) else { fail("--config needs a path.") }
    configURL = URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath)
    // Subcommands read their own arguments positionally, so the flag can go anywhere.
    arguments.removeSubrange(flag...(flag + 1))
}
// Sync state sits next to the config, so separate configs never share state.
let stateURL = configURL.deletingLastPathComponent().appendingPathComponent("state.json")
let tokenURL = RelayEngine.tokenURL(besideState: stateURL)
// Tokens, the review stack and other per-config data live next to the config.
let supportDirectory = configURL.deletingLastPathComponent()

func reviewStackConfig(_ config: RelayConfig) -> DestinationConfig.ReviewStackConfig? {
    for destination in config.destinations {
        if case .reviewStack(let stack) = destination { return stack }
    }
    return nil
}

func openInBrowser(_ url: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try? process.run()
}

func loadConfig() -> RelayConfig {
    do {
        return try ConfigStore.load(from: configURL)
    } catch {
        fail(error.localizedDescription)
    }
}

func printReport(_ report: SyncReport) {
    log(report.summary)
    for warning in report.warnings { log("  ! \(warning)") }
    for failure in report.failures {
        let destination = failure.destinationID.map { " → \($0)" } ?? ""
        log("  ✗ \(failure.item)\(destination): \(failure.message)")
    }
}

switch command {
case "setup":
    func ask(_ question: String, default answer: String = "") -> String {
        print(question + (answer.isEmpty ? " " : " [\(answer)] "), terminator: "")
        let reply = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces) ?? ""
        return reply.isEmpty ? answer : reply
    }
    func yes(_ question: String, default answer: Bool) -> Bool {
        ask(question + (answer ? " (Y/n)" : " (y/N)")).lowercased().first.map { $0 == "y" } ?? answer
    }
    func pick(_ title: String, _ options: [String], allowOther: String? = nil, allowNone: String? = nil) -> Int? {
        print("\n" + title)
        for (index, option) in options.enumerated() { print("  \(index + 1). \(option)") }
        if let allowOther { print("  \(options.count + 1). \(allowOther)") }
        if let allowNone { print("  0. \(allowNone)") }
        while true {
            let reply = ask(">", default: options.isEmpty ? (allowOther != nil ? String(options.count + 1) : "0") : "1")
            if let number = Int(reply), (allowNone != nil && number == 0) || (1...(options.count + (allowOther == nil ? 0 : 1))).contains(number) {
                return number == 0 ? nil : number - 1
            }
            print("Type a number from the list.")
        }
    }

    print("InkRelay setup. Press Return to take the suggestion in [brackets].")
    if FileManager.default.fileExists(atPath: configURL.path), !yes("A config already exists at \(configURL.path). Replace it? The old one is kept as config.json.bak.", default: false) {
        exit(0)
    }
    let detector = SetupDetector()
    let presets = TabletPreset.all
    let tablet = presets[pick("Which tablet?", presets.map(\.name)) ?? 0]
    var choices = SetupChoices(tablet: tablet)
    if tablet.hasCloudSource {
        choices.useViwoodsCloud = yes("\nPull notebooks and the Daily planner straight from Viwoods Cloud? (Turn on Viwoods Cloud on the tablet.)", default: true)
    }
    if tablet.name == "Kindle Scribe" {
        choices.kindleMail = yes("\nPick up notebooks you share from the Kindle by email, from Mail? (macOS asks once to let InkRelay read Mail.)", default: true)
    }
    if !(choices.useViwoodsCloud || choices.kindleMail) || yes("Also watch an export folder?", default: false) {
        print("\n" + tablet.exportHint)
        let clouds = detector.cloudFolders()
        let labels = clouds.map { "\($0.provider)\($0.account.isEmpty ? "" : " (\($0.account))"): \(detector.tilde($0.url))" }
        if let chosen = pick("Where does the tablet export to?", labels, allowOther: "Another folder", allowNone: choices.useViwoodsCloud || choices.kindleMail ? "No export folder" : nil) {
            if chosen < clouds.count {
                let base = detector.tilde(clouds[chosen].url)
                choices.exportFolder = ask("Folder inside it (the tablet's export folder):", default: base + "/" + tablet.name.split(separator: " ").first!)
            } else {
                choices.exportFolder = ask("Folder path:")
            }
        }
    }
    let vaults = detector.obsidianVaults()
    if let chosen = pick("Obsidian vault to file notes into?", vaults.map(detector.tilde), allowOther: "Another folder", allowNone: "No Obsidian") {
        choices.obsidianVault = chosen < vaults.count ? detector.tilde(vaults[chosen]) : ask("Vault path:")
    }
    if yes("\nFile notes into Apple Notes?", default: true) {
        var account: String? = nil
        if yes("List your Notes accounts to pick one? (macOS asks once to let InkRelay control Notes.)", default: false),
           let accounts = try? SetupDetector.notesAccounts(), let chosen = pick("Which Notes account?", accounts) {
            account = accounts[chosen]
        }
        choices.appleNotesAccount = .some(account)
    }
    choices.appleCalendar = yes("Put planner pages and to-dos in Apple Calendar?", default: tablet.hasCloudSource)
    choices.appleReminders = yes("Turn written tasks (☐, [ ], TODO) into Apple Reminders?", default: true)
    choices.reviewStack = yes("Keep a read-later review stack of new pages?", default: true)
    if choices.appleNotesAccount != nil, SharedLedger.iCloudDriveFolder != nil {
        choices.shareWithPhone = yes("Also use InkRelay on an iPhone or iPad? Share what's filed in Notes through iCloud Drive so it isn't filed twice.", default: false)
    }

    do {
        let config = try choices.config()
        if FileManager.default.fileExists(atPath: configURL.path) {
            let backup = configURL.deletingLastPathComponent().appendingPathComponent("config.json.bak")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: configURL, to: backup)
        }
        try ConfigStore.save(config, to: configURL)
        print("\nWrote \(configURL.path).")
        if choices.useViwoodsCloud { print("Next: run `inkrelay viwoods login` so InkRelay can read Viwoods Cloud.") }
        print("Google, Microsoft, Notion and AI transcription need an account of your own first; the README explains each.")
        if (!choices.useViwoodsCloud || FileManager.default.fileExists(atPath: tokenURL.path)) && yes("\nRun the first sync now?", default: true) {
            let report = try RelayEngine.live(config: config, stateURL: stateURL).syncOnce()
            printReport(report)
        }
        print("When it looks right, run scripts/install-agent.sh to keep syncing in the background, and `inkrelay doctor` to check everything.")
    } catch {
        fail(error.localizedDescription)
    }

case "doctor":
    let config = loadConfig()
    let includeApps = !arguments.contains("--no-apps")
    if includeApps, config.destinations.contains(where: { if case .appleNotes = $0 { return true }; if case .appleCalendar = $0 { return true }; if case .appleReminders = $0 { return true }; return false }) {
        print("Checking Apple apps; macOS may ask once to let inkrelay control them.\n")
    }
    var checks = [DoctorCheck(.ok, "Config", configURL.path)] + Doctor(config: config, supportDirectory: supportDirectory).checks(includeApps: includeApps)
    if arguments.contains("--notes-roundtrip") {
        let account = config.destinations.compactMap { destination -> String?? in
            if case .appleNotes(let notes) = destination { return .some(notes.account) }
            return nil
        }.first ?? nil
        checks += NotesRoundTrip(account: account).run()
    }
    for check in checks {
        print("\(check.status.rawValue) \(check.title)" + (check.detail.isEmpty ? "" : ": \(check.detail)"))
    }
    let problems = checks.filter { $0.status == .problem }.count
    print(problems == 0 ? "\nAll good." : "\n\(problems) thing(s) to fix.")
    exit(problems == 0 ? 0 : 1)

case "init":
    if FileManager.default.fileExists(atPath: configURL.path) {
        print("A config already exists at \(configURL.path). Edit it, or delete it to start over.")
        exit(0)
    }
    do {
        try ConfigStore.save(ConfigStore.example, to: configURL)
    } catch {
        fail("Couldn't write \(configURL.path): \(error.localizedDescription)")
    }
    print("""
    Wrote \(configURL.path).

    Edit it before the first sync:
      • sources[].path: the folder your tablet exports to. Cloud folders are under ~/Library/CloudStorage.
      • destinations: your Obsidian vault path; remove a destination you don't use.
    Then run `inkrelay sync`.
    """)

case "sync":
    let config = loadConfig()
    do {
        let report = try RelayEngine.live(config: config, stateURL: stateURL).syncOnce()
        printReport(report)
        exit(report.failures.isEmpty ? 0 : 1)
    } catch {
        fail(error.localizedDescription)
    }

case "watch":
    let config = loadConfig()
    let engine: RelayEngine
    do {
        engine = try RelayEngine.live(config: config, stateURL: stateURL)
    } catch {
        fail(error.localizedDescription)
    }

    // Folder events and the rescan timer both feed one trigger stream. Keeping only the newest
    // trigger means a burst of changes during a sync becomes a single follow-up pass.
    let (triggers, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var reviewServer: ReviewServer?
    if let stack = reviewStackConfig(config) {
        let context = DestinationContext(config: config, supportDirectory: supportDirectory)
        let calendars = DestinationFactory.eventWriters(in: DestinationFactory.make(config.destinations, context: context))
        let server = ReviewServer(store: ReviewStore(directory: context.reviewDirectory), config: stack, calendars: calendars)
        do {
            log("Review stack at \(try server.start())")
            reviewServer = server
        } catch {
            log("Review stack unavailable: \(error.localizedDescription)")
        }
    }
    let watcher = FolderWatcher(urls: config.sources.map(\.url)) { continuation.yield("folder change") }
    if !config.sources.isEmpty, !watcher.start() {
        log("Folder events unavailable; relying on rescans every \(config.rescanIntervalSeconds)s.")
    }
    if config.viwoodsCloud != nil {
        log("Viwoods Cloud is polled every \(config.rescanIntervalSeconds)s.")
    }
    let timer = DispatchSource.makeTimerSource()
    timer.schedule(deadline: .now() + .seconds(config.rescanIntervalSeconds), repeating: .seconds(config.rescanIntervalSeconds))
    timer.setEventHandler { continuation.yield("rescan") }
    timer.resume()

    log("Watching \(config.allSources.count) source(s). Press Ctrl-C to stop.")
    continuation.yield("startup")
    let logFile = ProcessInfo.processInfo.environment["INKRELAY_LOG"].map { URL(fileURLWithPath: $0) }
    for await reason in triggers {
        if let logFile, LogTrimmer.trim(logFile) { log("Trimmed the log to its newest lines.") }
        log("Syncing (\(reason))…")
        let report = engine.syncOnce()
        printReport(report)
        if report.deferred > 0 {
            // Some files were still being written; look again once they've had time to settle.
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(config.settleSeconds + 1)) { continuation.yield("settled files") }
        }
    }
    withExtendedLifetime((watcher, reviewServer)) {}

case "status":
    let config = loadConfig()
    let state = (try? StateStore(url: stateURL))?.state ?? SyncState()
    print("Config: \(configURL.path)")
    print("Sources:")
    for source in config.allSources {
        let exists = FileManager.default.fileExists(atPath: source.url.path)
        let tracked = state.files.keys.filter { $0.hasPrefix(source.id + "/") }.count
        print("  \(source.id) (\(source.device)): \(source.url.path)\(exists ? "" : "  [missing]"), \(tracked) tracked")
    }
    print("Destinations:")
    for destination in config.destinations {
        let delivered = state.files.values.filter { $0.destinations[destination.id]?.contentHash == $0.contentHash }.count
        print("  \(destination.id) (\(destination.kind)): \(delivered) up to date")
    }

case "viwoods":
    let subcommand = arguments.first ?? ""
    switch subcommand {
    case "login":
        let store = FileCredentialStore(url: tokenURL)
        print("""
        Easiest: open the InkRelay menu bar app and choose Sign In to Viwoods; it signs in on Viwoods' own page.

        Here, InkRelay signs in with the access token the web portal already holds, because the portal's
        sign-in form needs a slider captcha. To copy it:
          1. Open https://cloud.viwoods.com in Chrome or Safari and sign in.
          2. Open the developer tools (Option-Command-I), then Application (Chrome) or Storage (Safari) → Local Storage.
          3. Copy the value of Access-Token and paste it here. It is saved to \(tokenURL.path), readable only by you.
        The token is refreshed automatically from then on.

        """)
        print("Access-Token: ", terminator: "")
        guard let token = readLine(strippingNewline: true), !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            fail("No token entered.")
        }
        do {
            let folders = try ViwoodsClient(credentials: store).login(token: token)
            print("Signed in. Cloud contents: " + folders.map { "\($0.name) \($0.count)" }.joined(separator: ", ") + ".")
            if (try? ConfigStore.load(from: configURL))?.viwoodsCloud == nil {
                print("Add a \"viwoodsCloud\": {} section to \(configURL.path) to pull it on every sync.")
            }
        } catch {
            fail(error.localizedDescription)
        }

    case "pull":
        let config = loadConfig()
        guard let cloud = config.viwoodsCloud else { fail("The config has no viwoodsCloud section.") }
        do {
            let destinations = DestinationFactory.make(config.destinations, context: DestinationContext(config: config, supportDirectory: supportDirectory))
            let client = ViwoodsClient(credentials: FileCredentialStore(url: tokenURL))
            let puller = try ViwoodsCloudPuller(config: cloud, client: client, plans: DestinationFactory.plans(in: destinations))
            let report = puller.pull()
            log(report.summary + " → \(cloud.cacheURL.path)")
            for failure in report.failures { log("  ✗ \(failure)") }
            exit(report.failures.isEmpty ? 0 : 1)
        } catch {
            fail(error.localizedDescription)
        }

    default:
        fail("Usage: inkrelay viwoods login | pull")
    }

case "google":
    guard arguments.first == "login" else { fail("Usage: inkrelay google login") }
    let config = loadConfig()
    guard let google = config.google else {
        fail("""
        Add a "google" section to \(configURL.path) first:
          "google": { "clientId": "…apps.googleusercontent.com", "clientSecret": "…" }
        Create the client in Google Cloud Console → APIs & Services → Credentials → OAuth client ID → Desktop app,
        with the Google Calendar API and Google Drive API enabled for the project.
        """)
    }
    let account = GoogleAccount(config: google, supportDirectory: supportDirectory)
    do {
        try account.login { url in
            print("Opening Google sign-in in your browser. If it doesn't open, visit:\n\(url.absoluteString)\n")
            openInBrowser(url)
        }
        print("Signed in to Google. InkRelay can only see calendars and Drive files it creates.")
    } catch {
        fail(error.localizedDescription)
    }

case "microsoft":
    guard arguments.first == "login" else { fail("Usage: inkrelay microsoft login") }
    let config = loadConfig()
    guard let microsoft = config.microsoft else {
        fail("""
        Add a "microsoft" section to \(configURL.path) first:
          "microsoft": { "clientId": "…", "tenant": "common" }
        Register an app in Microsoft Entra (portal.azure.com → App registrations), allow personal Microsoft accounts,
        turn on "Allow public client flows", and add the delegated Graph permissions Calendars.ReadWrite and Notes.ReadWrite.
        """)
    }
    do {
        try MicrosoftAccount(config: microsoft, supportDirectory: supportDirectory).login { message in print(message) }
        print("Signed in to Microsoft.")
    } catch {
        fail(error.localizedDescription)
    }

case "notion":
    guard arguments.first == "login" else { fail("Usage: inkrelay notion login") }
    print("""
    Create an internal integration at https://www.notion.so/profile/integrations with "Insert content" and
    "Update content" capabilities, then share the parent page or database with it (••• → Connections).
    Paste the integration secret here; it's kept in your login Keychain, not in the config.

    """)
    print("Integration secret: ", terminator: "")
    guard let token = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces), !token.isEmpty else { fail("No token entered.") }
    let keychain = KeychainStore()
    do {
        try keychain.setSecret(token, for: NotionDestination.keychainAccount)
        let name = try NotionDestination(config: .init(id: "check", parentPageId: "-"), secrets: keychain).whoAmI()
        print("Saved. Connected as \(name).")
    } catch {
        try? keychain.deleteSecret(for: NotionDestination.keychainAccount)
        fail(error.localizedDescription)
    }

case "ai":
    let config = loadConfig()
    let ai = config.ai ?? AITranscriptionConfig()
    let claudeSources = config.allSources.filter { $0.recognizer == .claude }.map(\.id)
    switch arguments.first ?? "" {
    case "login":
        print("""
        AI transcription sends each page image of the sources that opt in ("recognizer": "claude") to Anthropic's API,
        which returns the text. Nothing else leaves the Mac, and Vision stays the default for every other source.
        Model: \(ai.model), effort \(ai.effort), spending capped at $\(String(format: "%.2f", ai.monthlyBudgetUSD)) a month.
        Sources opted in: \(claudeSources.isEmpty ? "none yet" : claudeSources.joined(separator: ", ")).

        Create a key at https://platform.claude.com/settings/keys and paste it here. It's kept in your login Keychain.

        """)
        print("API key: ", terminator: "")
        guard let key = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { fail("No key entered.") }
        var check = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        check.setValue(key, forHTTPHeaderField: "x-api-key")
        check.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (_, response) = try URLSessionTransport().send(check)
            guard response.statusCode == 200 else { fail("Anthropic didn't accept the key (HTTP \(response.statusCode)).") }
            try KeychainStore().setSecret(key, for: ClaudeTextRecognizer.keychainAccount)
            print("Saved.")
        } catch {
            fail(error.localizedDescription)
        }
    case "status":
        let recognizer = ClaudeTextRecognizer(config: ai, supportDirectory: supportDirectory, fallback: VisionTextRecognizer())
        let (spent, pages) = recognizer.spentThisMonth()
        print("AI transcription: \(ai.model), effort \(ai.effort)")
        print("This month: $\(String(format: "%.2f", spent)) of $\(String(format: "%.2f", ai.monthlyBudgetUSD)) for \(pages) page(s)")
        print("Key: " + (recognizer.apiKey() == nil ? "missing; run `inkrelay ai login`" : "saved"))
        print("Sources using it: " + (claudeSources.isEmpty ? "none" : claudeSources.joined(separator: ", ")))
    default:
        fail("Usage: inkrelay ai login | status")
    }

case "send":
    let config = loadConfig()
    guard let input = arguments.first(where: { !$0.hasPrefix("--") }) else { fail("Usage: inkrelay send LINK|FILE [--to TARGET] [--title TITLE]") }
    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    guard !config.sendTargets.isEmpty else {
        fail("Add a \"sendTargets\" list to \(configURL.path), for example a folder your tablet imports from:\n  \"sendTargets\": [{ \"kind\": \"folder\", \"id\": \"drive\", \"path\": \"~/Library/CloudStorage/…/Viwoods/Import\" }]")
    }
    let wanted = option("--to")
    guard let target = wanted.map({ id in config.sendTargets.first { $0.id == id } }) ?? config.sendTargets.first else {
        fail("No send target with id \"\(wanted ?? "")\". Known: \(config.sendTargets.map(\.id).joined(separator: ", ")).")
    }
    let sender = Sender(viwoods: { ViwoodsClient(credentials: FileCredentialStore(url: tokenURL)) })
    do {
        let file = try sender.prepare(input, title: option("--title"))
        print(try sender.deliver(file, to: target))
    } catch {
        fail(error.localizedDescription)
    }

case "mcp":
    // stdout carries only MCP messages from here on; anything else goes to stderr.
    setvbuf(stdout, nil, _IONBF, 0)
    FileHandle.standardError.write(Data("InkRelay MCP server \(InkRelayCore.version), config \(configURL.path)\n".utf8))
    MCPServer(configURL: configURL).run()

case "convert":
    guard arguments.count >= 2 else { fail("Usage: inkrelay convert NOTEBOOK.note OUTPUT.pdf") }
    do {
        let input = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath)
        let output = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
        let note = try SupernoteNote(data: Data(contentsOf: input))
        try note.writePDF(to: output)
        print("Wrote \(note.pages.count) page(s) to \(output.path).")
    } catch {
        fail(error.localizedDescription)
    }

case "review":
    let config = loadConfig()
    guard let stack = reviewStackConfig(config) else {
        fail("Add a destination with \"kind\": \"reviewStack\" to \(configURL.path) to collect pages for later.")
    }
    let store = ReviewStore(directory: DestinationContext(config: config, supportDirectory: supportDirectory).reviewDirectory)
    let subcommand = arguments.first ?? "list"
    switch subcommand {
    case "list":
        do {
            let (cards, due) = try store.stack(now: Date(), limit: stack.dailyLimit)
            if cards.isEmpty {
                print("All caught up. New pages and to-dos land here as your tablet syncs.")
            } else {
                print("\(cards.count) card(s) today" + (due > cards.count ? ", \(due - cards.count) more waiting" : "") + ":")
                for card in cards {
                    let line = card.text.split(separator: "\n").first.map(String.init) ?? ""
                    print("  \(card.id.prefix(6))  \(card.title) · \(card.subtitle)" + (line.isEmpty ? "" : "\n          \(line)"))
                }
                print("\nOpen them with `inkrelay review open`, or `inkrelay review done <id>`.")
            }
        } catch {
            fail(error.localizedDescription)
        }

    case "done", "later":
        guard arguments.count >= 2 else { fail("Usage: inkrelay review \(subcommand) <card id>") }
        do {
            guard let id = try store.resolve(arguments[1]) else { fail("No single card starts with \"\(arguments[1])\".") }
            if subcommand == "done" {
                try store.markDone(id, now: Date(), resurfaceDays: stack.resurfaceDays)
            } else {
                try store.snooze(id, now: Date())
            }
            print(subcommand == "done" ? "Done." : "Back tomorrow.")
        } catch {
            fail(error.localizedDescription)
        }

    case "open", "serve":
        let calendars = DestinationFactory.eventWriters(in: DestinationFactory.make(config.destinations, context: DestinationContext(config: config, supportDirectory: supportDirectory)))
        let server = ReviewServer(store: store, config: stack, calendars: calendars)
        let url: URL
        do {
            url = try server.start()
        } catch {
            // `inkrelay watch` may already be serving it on the configured port.
            let running = URL(string: "http://127.0.0.1:\(stack.port)")!
            if subcommand == "open" {
                print("The stack is already being served at \(running.absoluteString) (by `inkrelay watch`?). Opening it.")
                openInBrowser(running)
                exit(0)
            }
            fail(error.localizedDescription)
        }
        print("Review stack at \(url.absoluteString). Press Ctrl-C to stop.")
        if subcommand == "open" { openInBrowser(url) }
        withExtendedLifetime(server) { dispatchMain() }

    default:
        fail("Usage: inkrelay review [list | open | serve | done ID | later ID]")
    }

case "version", "--version", "-v":
    print(InkRelayCore.version)

case "help", "--help", "-h":
    print(usage)

default:
    fail("Unknown command \"\(command)\".\n\n\(usage)")
}

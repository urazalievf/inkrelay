import Foundation
import InkRelayCore

let usage = """
inkrelay \(InkRelayCore.version): relay handwritten notes from e-ink tablets into Apple Notes and Obsidian

Usage:
  inkrelay init [--config PATH]     Write an example config to edit
  inkrelay sync [--config PATH]     Sync once and exit
  inkrelay watch [--config PATH]    Sync now, then whenever a source folder changes
  inkrelay status [--config PATH]   Show sources, destinations and what's been synced
  inkrelay viwoods login            Save a Viwoods Cloud token copied from cloud.viwoods.com
  inkrelay viwoods pull             Pull Viwoods Cloud into the local cache without syncing
  inkrelay google login             Sign in to Google for the googleCalendar and googleDocs destinations
  inkrelay microsoft login          Sign in to Microsoft for the outlookCalendar and oneNote destinations
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
        let server = ReviewServer(store: ReviewStore(directory: DestinationContext(config: config, supportDirectory: supportDirectory).reviewDirectory), config: stack)
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
    for await reason in triggers {
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
        InkRelay signs in to Viwoods Cloud with the access token the web portal already holds, because the portal's
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
        let server = ReviewServer(store: store, config: stack)
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

import Foundation

/// One MCP tool: its definition for `tools/list` and what it does for `tools/call`.
struct MCPTool {
    var name: String
    var title: String
    var description: String
    var properties: [String: [String: Any]] = [:]
    var required: [String] = []
    var readOnly: Bool
    var destructive = false
    var idempotent = false
    var openWorld = false
    var run: (MCPServer, [String: Any]) throws -> [String: Any]

    var definition: [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
            "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive, "idempotentHint": idempotent, "openWorldHint": openWorld],
        ]
    }
}

extension MCPServer {
    static let paging: [String: [String: Any]] = [
        "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "How many to return."],
        "offset": ["type": "integer", "minimum": 0, "description": "How many to skip, for the next page (use next_offset)."],
    ]
    static let sourceFilter: [String: Any] = ["type": "string", "description": "Only this source id, as inkrelay_status lists them, such as \"viwoods-cloud\"."]

    static let tools: [MCPTool] = [
        MCPTool(
            name: "inkrelay_status",
            title: "InkRelay status",
            description: "Where notes come from and go to: each source with how many exports it tracks, each destination, when the last sync ran, how many notes are searchable and how many review cards are waiting.",
            readOnly: true, idempotent: true
        ) { server, _ in try server.status() },

        MCPTool(
            name: "inkrelay_list_notes",
            title: "List handwritten notes",
            description: "Relayed notes, most recently changed first, with a short preview of the recognized text. Use the id with inkrelay_get_note.",
            properties: paging.merging(["source": sourceFilter]) { $1 },
            readOnly: true, idempotent: true
        ) { server, arguments in
            let (slice, meta) = page(server.notes(source: arguments["source"] as? String), arguments, defaultLimit: 20)
            return meta.merging(["notes": slice.map(server.summary)]) { $1 }
        },

        MCPTool(
            name: "inkrelay_search_notes",
            title: "Search handwritten notes",
            description: "Finds notes whose title or recognized handwriting contains every word of the query (case and accents ignored). Returns the matching page and a snippet around the hit. Handwriting recognition misreads words, so try a shorter or alternative query if nothing matches.",
            properties: paging.merging([
                "query": ["type": "string", "minLength": 1, "description": "Words to find, such as \"bank call\"."],
                "source": sourceFilter,
            ]) { $1 },
            required: ["query"],
            readOnly: true, idempotent: true
        ) { server, arguments in
            guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                throw MCPToolError("query is required.")
            }
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            func contains(_ text: String) -> Bool { words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
            let hits = server.notes(source: arguments["source"] as? String).compactMap { note -> [String: Any]? in
                let page = note.pages.first { contains(note.title + "\n" + $0.text) }
                guard page != nil || contains(note.title) else { return nil }
                var hit = server.summary(note)
                hit["page"] = page?.number ?? 1
                hit["snippet"] = snippet(page?.text ?? note.text, around: words.first)
                hit["preview"] = nil
                return hit
            }
            let (slice, meta) = page(hits, arguments, defaultLimit: 10)
            return meta.merging(["query": query, "results": slice]) { $1 }
        },

        MCPTool(
            name: "inkrelay_get_note",
            title: "Read a handwritten note",
            description: "The full recognized text of one note, page by page, with its source, the original file on this Mac, the destinations it was delivered to, suggested title and tags (when AI transcription read it), and the tasks written on it.",
            properties: ["id": ["type": "string", "minLength": 4, "description": "The note id from inkrelay_list_notes or inkrelay_search_notes (the first few characters are enough when unique)."]],
            required: ["id"],
            readOnly: true, idempotent: true
        ) { server, arguments in
            guard let id = arguments["id"] as? String, let note = server.archive.note(id: id) else {
                throw MCPToolError("No note with id \"\(arguments["id"] as? String ?? "")\". Use inkrelay_list_notes or inkrelay_search_notes to find one.")
            }
            let state = (try? StateStore(url: server.stateURL))?.state ?? SyncState()
            var output = server.summary(note)
            output["preview"] = nil
            output["original"] = note.originalPath
            output["delivered_to"] = state.files[note.key]?.destinations.keys.sorted() ?? []
            output["pages"] = note.pages.map { page -> [String: Any] in
                var item: [String: Any] = ["number": page.number, "text": page.text]
                if let title = page.suggestedTitle { item["suggested_title"] = title }
                if !page.tags.isEmpty { item["tags"] = page.tags }
                return item
            }
            output["tasks"] = TaskExtractor.tasks(in: note.text, itemKey: note.key, plannerDate: nil).map(taskJSON)
            return output
        },

        MCPTool(
            name: "inkrelay_list_tasks",
            title: "List written tasks",
            description: "Tasks written on pages (checkbox lines such as ☐ or [ ], and TODO lines) across all notes, with their due date when one was written and the note they're on.",
            properties: paging.merging([
                "status": ["type": "string", "enum": ["open", "done", "all"], "description": "Which tasks: open (default), done, or all."],
                "source": sourceFilter,
            ]) { $1 },
            readOnly: true, idempotent: true
        ) { server, arguments in
            let status = arguments["status"] as? String ?? "open"
            guard ["open", "done", "all"].contains(status) else { throw MCPToolError("status must be open, done or all.") }
            let tasks = server.notes(source: arguments["source"] as? String).flatMap { note -> [[String: Any]] in
                let planner = note.relativePath.hasPrefix("Daily/") ? note.title : nil
                return TaskExtractor.tasks(in: note.text, itemKey: note.key, plannerDate: planner)
                    .filter { status == "all" || ($0.isDone == (status == "done")) }
                    .map { taskJSON($0).merging(["note_id": note.id, "note_title": note.title]) { $1 } }
            }
            let (slice, meta) = page(tasks, arguments, defaultLimit: 50)
            return meta.merging(["status": status, "tasks": slice]) { $1 }
        },

        MCPTool(
            name: "inkrelay_review_stack",
            title: "Today's review stack",
            description: "The read-later cards due today: new or changed pages, planner to-dos, and suggested events found in the notes. Act on one with inkrelay_review_card.",
            properties: ["limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "How many cards (default: the stack's daily limit)."]],
            readOnly: true, idempotent: true
        ) { server, arguments in
            let (stack, store) = try server.reviewStack()
            let (cards, due) = try store.stack(now: server.now(), limit: arguments["limit"] as? Int ?? stack.dailyLimit)
            return [
                "due": due,
                "cards": cards.map { card -> [String: Any] in
                    var item: [String: Any] = ["id": card.id, "kind": card.kind.rawValue, "title": card.title, "subtitle": card.subtitle, "text": card.text]
                    if let event = card.event { item["event"] = ["title": event.title, "start": iso(event.start), "end": iso(event.end)] }
                    return item
                },
            ]
        },

        MCPTool(
            name: "inkrelay_review_card",
            title: "Act on a review card",
            description: "done takes a card out of the stack (or schedules it to come back if resurfacing is on), later brings it back tomorrow morning, and accept adds a suggested event to every configured calendar. Only use accept when the user asked for the event.",
            properties: [
                "id": ["type": "string", "minLength": 4, "description": "Card id from inkrelay_review_stack (a unique prefix works)."],
                "action": ["type": "string", "enum": ["done", "later", "accept"], "description": "What to do with the card."],
            ],
            required: ["id", "action"],
            readOnly: false, openWorld: true
        ) { server, arguments in
            let (stack, store) = try server.reviewStack()
            guard let given = arguments["id"] as? String, let id = try store.resolve(given) else {
                throw MCPToolError("No single card matches \"\(arguments["id"] as? String ?? "")\". Use inkrelay_review_stack for current ids.")
            }
            let action = arguments["action"] as? String ?? ""
            let card: ReviewCard?
            switch action {
            case "done": card = try store.markDone(id, now: server.now(), resurfaceDays: stack.resurfaceDays)
            case "later": card = try store.snooze(id, now: server.now())
            case "accept":
                guard let event = try store.load().cards[id]?.event else { throw MCPToolError("That card isn't a suggested event.") }
                let config = try server.config()
                let calendars = DestinationFactory.eventWriters(in: DestinationFactory.make(config.destinations, context: DestinationContext(config: config, supportDirectory: server.supportDirectory)))
                guard !calendars.isEmpty else { throw MCPToolError("No calendar destination is configured (appleCalendar, googleCalendar or outlookCalendar).") }
                for calendar in calendars { _ = try calendar.addEvent(event) }
                card = try store.markDone(id, now: server.now(), resurfaceDays: [])
            default:
                throw MCPToolError("action must be done, later or accept.")
            }
            guard let card else { throw MCPToolError("That card is gone.") }
            return ["id": card.id, "status": card.status.rawValue, "due": iso(card.dueAt), "action": action]
        },

        MCPTool(
            name: "inkrelay_sync_now",
            title: "Sync now",
            description: "Runs one sync pass: pulls Viwoods Cloud and Kindle email if configured, reads new or changed exports, and delivers them to every destination. Exports deleted at the source are handled by the user's onDelete settings. Waits for a pass the app or agent is running to finish first.",
            readOnly: false, destructive: true, openWorld: true
        ) { server, _ in
            let report = try server.sync(try server.config(), server.stateURL)
            return [
                "summary": report.summary, "found": report.scanned, "synced": report.synced, "unchanged": report.unchanged,
                "renamed": report.renamed, "removed": report.removed, "still_being_written": report.deferred,
                "problems": report.failures.map { $0.item + ($0.destinationID.map { " → \($0)" } ?? "") + ": " + $0.message },
                "warnings": report.warnings,
            ]
        },

        MCPTool(
            name: "inkrelay_send_to_tablet",
            title: "Send to the tablet",
            description: "Sends a web article (as a clean EPUB) or a PDF, EPUB, HTML, Markdown or text file on this Mac to the tablet, through a configured send target: a folder the tablet imports from, Send to Kindle, or Viwoods Cloud.",
            properties: [
                "input": ["type": "string", "minLength": 1, "description": "An https link or a file path on this Mac."],
                "target": ["type": "string", "description": "Send target id from the config; the first one when left out."],
                "title": ["type": "string", "description": "Book title to use instead of the page's."],
            ],
            required: ["input"],
            readOnly: false, openWorld: true
        ) { server, arguments in
            guard let send = server.send else { throw MCPToolError("Sending to the tablet works on the Mac only.") }
            guard let input = arguments["input"] as? String, !input.isEmpty else { throw MCPToolError("input is required.") }
            return ["result": try send(try server.config(), input, arguments["target"] as? String, arguments["title"] as? String)]
        },
    ]

    static func taskJSON(_ task: ExtractedTask) -> [String: Any] {
        var item: [String: Any] = ["text": task.text, "done": task.isDone]
        if let due = task.due {
            item["due"] = task.dueHasTime ? iso(due) : ReviewStackDestination.friendlyDate(PlannerEvent.dayFormatter.string(from: due))
        }
        return item
    }

    func status() throws -> [String: Any] {
        let config = try config()
        let state = (try? StateStore(url: stateURL))?.state ?? SyncState()
        let lastSync = state.files.values.flatMap { $0.destinations.values.map(\.syncedAt) }.max()
        var output: [String: Any] = [
            "version": InkRelayCore.version,
            "config": configURL.path,
            "sources": config.allSources.map { source -> [String: Any] in
                [
                    "id": source.id, "device": source.device, "folder": source.url.path,
                    "folder_exists": FileManager.default.fileExists(atPath: source.url.path),
                    "tracked": state.files.keys.filter { $0.hasPrefix(source.id + "/") }.count,
                    "recognizer": source.recognizer.rawValue,
                ]
            },
            "destinations": config.destinations.map { ["id": $0.id, "kind": $0.kind] },
            "notes_searchable": archive.all().count,
        ]
        let entitlement = EntitlementStore(supportDirectory: stateURL.deletingLastPathComponent()).current(now: now())
        output["plan"] = entitlement.summary(now: now())
        let paused = ProFeatures.used(in: config)
        if !entitlement.isPro, !paused.isEmpty { output["paused_pro_features"] = paused }
        if let lastSync { output["last_sync"] = Self.iso(lastSync) }
        if let (stack, store) = try? reviewStack() {
            output["review_cards_due"] = (try? store.stack(now: now(), limit: stack.dailyLimit).due) ?? 0
        }
        return output
    }

    func reviewStack() throws -> (DestinationConfig.ReviewStackConfig, ReviewStore) {
        let config = try config()
        guard let stack = RelayRunner.reviewStack(in: config) else {
            throw MCPToolError("The review stack isn't turned on. Add a destination with \"kind\": \"reviewStack\".")
        }
        return (stack, ReviewStore(directory: DestinationContext(config: config, supportDirectory: supportDirectory).reviewDirectory))
    }
}

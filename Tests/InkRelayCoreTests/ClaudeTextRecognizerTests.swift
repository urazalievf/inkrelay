import XCTest
@testable import InkRelayCore

final class ClaudeTextRecognizerTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var transport: FakeTransport!
    private var vision: FakeRecognizer!
    private var secrets: MemorySecretStore!
    private var clock = Date(timeIntervalSince1970: 1_792_000_000) // October 2026

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        transport = FakeTransport()
        vision = FakeRecognizer()
        vision.text = "vision text"
        secrets = MemorySecretStore(["anthropic": "sk-ant-test"])
    }

    override func tearDown() {
        folder.remove()
    }

    private func recognizer(_ config: AITranscriptionConfig = AITranscriptionConfig(), pages: Int = 1, environment: [String: String] = [:]) -> ClaudeTextRecognizer {
        ClaudeTextRecognizer(
            config: config, supportDirectory: folder.url, fallback: vision, secrets: secrets, transport: transport,
            renderImages: { _ in (1...pages).map { Data("jpeg-\($0)".utf8) } },
            environment: environment, now: { [unowned self] in self.clock }
        )
    }

    /// Answers every page in the request with the same text, as `{"pages": [...]}`.
    private func answer(text: String = "Q4 planning\n\n- ship the stack", title: String = "Q4 planning", tags: [String] = ["Planning"], stop: String = "end_turn", model: String = "claude-opus-5-5", input: Int = 3000, output: Int = 500) {
        transport.handlers["v1/messages"] = { sent in
            let content = ((sent.body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
            let numbers = content.compactMap { ($0["text"] as? String).flatMap { $0.hasPrefix("Page ") ? Int($0.split(separator: " ")[1]) : nil } }
            let payload = try JSONSerialization.data(withJSONObject: ["pages": numbers.map { ["page": $0, "text": text, "title": title, "tags": tags] }])
            return (200, try jsonData([
                "model": model, "stop_reason": stop,
                "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": String(decoding: payload, as: UTF8.self)]],
                "usage": ["input_tokens": input, "output_tokens": output],
            ]))
        }
    }

    private let file = URL(fileURLWithPath: "/tmp/Meeting notes.pdf")

    func testSendsEachPageAsAnImageWithStructuredOutputAndTheDefaultFallback() throws {
        answer()
        let pages = try recognizer().recognize(fileAt: file)

        XCTAssertEqual(pages, [RecognizedPage(number: 1, text: "Q4 planning\n\n- ship the stack", suggestedTitle: "Q4 planning", tags: ["planning"])])
        let sent = try XCTUnwrap(transport.requests(to: "v1/messages").first)
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(sent.body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(sent.body["fallbacks"] as? String, "default")
        XCTAssertNil(sent.body["thinking"], "always on for this model; sending disabled would be a 400")
        let output = try XCTUnwrap(sent.body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "medium")
        XCTAssertEqual((output["format"] as? [String: Any])?["type"] as? String, "json_schema")
        let content = try XCTUnwrap(((sent.body["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        let source = try XCTUnwrap((content[0]["source"]) as? [String: String])
        XCTAssertEqual(source["media_type"], "image/jpeg")
        XCTAssertEqual(source["data"], Data("jpeg-1".utf8).base64EncodedString())
        XCTAssertEqual(content[1]["text"] as? String, "Page 1 of 1 of the notebook \"Meeting notes\".")
        XCTAssertTrue(vision.calls.isEmpty)
    }

    func testRecordsWhatEachPageCostAndStopsAtTheMonthlyBudget() throws {
        answer(input: 3000, output: 500) // $0.012 + $0.010 at Opus 5.5 prices
        let budget = AITranscriptionConfig(monthlyBudgetUSD: 0.10, batchSize: 1)
        _ = try recognizer(budget, pages: 2).recognize(fileAt: file)
        let spent = recognizer(budget).spentThisMonth()
        XCTAssertEqual(spent.pages, 2)
        XCTAssertEqual(spent.usd, 0.044, accuracy: 0.0001)

        // The worst case for one more page is $0.064, which no longer fits under $0.10.
        let capped = recognizer(budget, pages: 1)
        let pages = try capped.recognize(fileAt: file)
        XCTAssertEqual(pages.first?.text, "vision text")
        XCTAssertEqual(transport.requests(to: "v1/messages").count, 2, "no request once the budget is used up")
        XCTAssertTrue(capped.takeFallbacks().first?.contains("monthly AI budget") == true)

        clock = Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: clock)!
        XCTAssertEqual(recognizer(budget).spentThisMonth().usd, 0, "a new month starts from zero")
    }

    func testDeclinedTruncatedOrBrokenAnswersFallBackToVisionForThatPage() throws {
        for stop in ["refusal", "max_tokens"] {
            answer(stop: stop)
            let claude = recognizer()
            XCTAssertEqual(try claude.recognize(fileAt: file).first?.text, "vision text", stop)
            XCTAssertEqual(claude.takeFallbacks().count, 1)
        }
        transport.reply("v1/messages", status: 529, ["error": ["message": "Overloaded"]])
        let overloaded = recognizer()
        XCTAssertEqual(try overloaded.recognize(fileAt: file).first?.text, "vision text")
        XCTAssertTrue(overloaded.takeFallbacks().first?.contains("HTTP 529: Overloaded") == true)
    }

    func testPagesGoInBatchesAndASourceCanHaveItsOwnCap() throws {
        answer(input: 3000, output: 500)
        let claude = recognizer(AITranscriptionConfig(batchSize: 3), pages: 5)
        let pages = try claude.recognize(fileAt: file)
        XCTAssertEqual(pages.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(transport.requests(to: "v1/messages").count, 2, "three pages, then two")
        let first = try XCTUnwrap(transport.requests(to: "v1/messages").first)
        let content = try XCTUnwrap(((first.body["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertEqual(content.filter { $0["type"] as? String == "image" }.count, 3)
        XCTAssertEqual(content.last?["text"] as? String, "Transcribe each page above as one entry in pages, with its page number.")
        XCTAssertEqual(recognizer().spentThisMonth().pages, 5)

        // One answer short of a page: the whole batch goes to Vision rather than guessing which page is missing.
        transport.handlers["v1/messages"] = { _ in
            let payload = try JSONSerialization.data(withJSONObject: ["pages": [["page": 1, "text": "only one", "title": "", "tags": []]]])
            return (200, try jsonData(["model": "claude-opus-5-5", "stop_reason": "end_turn", "content": [["type": "text", "text": String(decoding: payload, as: UTF8.self)]], "usage": ["input_tokens": 1, "output_tokens": 1]]))
        }
        let short = recognizer(AITranscriptionConfig(batchSize: 2), pages: 2)
        let result = try short.recognize(fileAt: file)
        XCTAssertFalse(result.map(\.text).contains("only one"))
        XCTAssertEqual(short.takeFallbacks().count, 2, "both pages went to Vision")

        // A per-source cap inside the overall budget.
        answer(input: 3000, output: 500)
        let capped = recognizer(AITranscriptionConfig(monthlyBudgetUSD: 50, batchSize: 1), pages: 1)
        capped.currentSource = ("drive", 0.01)
        XCTAssertEqual(try capped.recognize(fileAt: file).first?.text, "vision text")
        XCTAssertTrue(capped.takeFallbacks().first?.contains("budget of $0.01 for drive") == true)
        capped.currentSource = ("cloud", 1)
        XCTAssertEqual(try capped.recognize(fileAt: file).first?.text, "Q4 planning\n\n- ship the stack")
    }

    func testABatchShrinksToWhatTheBudgetStillAllows() throws {
        answer(input: 3000, output: 500)
        // Worst case is about $0.064 a page: $0.15 is room for two at once. They cost far less than the worst
        // case, so the third still fits afterwards, on its own.
        let claude = recognizer(AITranscriptionConfig(monthlyBudgetUSD: 0.15, batchSize: 4), pages: 3)
        let pages = try claude.recognize(fileAt: file)
        XCTAssertEqual(pages.map(\.text), Array(repeating: "Q4 planning\n\n- ship the stack", count: 3))
        let requests = transport.requests(to: "v1/messages")
        XCTAssertEqual(requests.count, 2, "two pages, then one; not four refused")
        func images(_ index: Int) throws -> Int {
            let content = try XCTUnwrap(((requests[index].body["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
            return content.filter { $0["type"] as? String == "image" }.count
        }
        XCTAssertEqual(try images(0), 2)
        XCTAssertEqual(try images(1), 1)
    }

    func testWithoutAKeyNothingIsSentAndVisionReadsEverything() throws {
        secrets.secrets = [:]
        let pages = try recognizer(pages: 2).recognize(fileAt: file)
        XCTAssertEqual(pages.map(\.number), [1, 2])
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertEqual(vision.calls.count, 1, "Vision reads the file once for all pages")
    }

    func testTheEnvironmentKeyWorksWhenTheKeychainHasNone() throws {
        secrets.secrets = [:]
        answer()
        _ = try recognizer(environment: ["ANTHROPIC_API_KEY": "sk-ant-env"]).recognize(fileAt: file)
        XCTAssertEqual(transport.sent.first?.request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-env")
    }

    func testModelsWithoutServerFallbackDontSendIt() throws {
        answer(model: "claude-haiku-5-5")
        _ = try recognizer(AITranscriptionConfig(model: "claude-haiku-5-5")).recognize(fileAt: file)
        let sent = try XCTUnwrap(transport.sent.first)
        XCTAssertNil(sent.body["fallbacks"])
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testTheEngineUsesClaudeOnlyForSourcesThatOptIn() throws {
        let exports = try TemporaryFolder()
        defer { exports.remove() }
        try exports.write("ai/One.pdf", "one")
        try exports.write("local/Two.pdf", "two")
        answer()
        let destination = FakeDestination(id: "vault")
        let config = RelayConfig(
            sources: [
                SourceConfig(id: "ai", device: "Viwoods", path: exports.url.appendingPathComponent("ai").path, recognizer: .claude),
                SourceConfig(id: "local", device: "Boox", path: exports.url.appendingPathComponent("local").path),
            ],
            destinations: [.appleNotes(.init(id: "vault"))],
            settleSeconds: 0
        )
        let engine = RelayEngine(
            config: config, store: try StateStore(url: folder.url.appendingPathComponent("state.json")),
            recognizer: vision, destinations: [destination], aiRecognizer: recognizer()
        )

        _ = engine.syncOnce()

        let texts = Dictionary(uniqueKeysWithValues: destination.upserts.map { ($0.note.sourceID, $0.note.pages.first?.text ?? "") })
        XCTAssertEqual(texts["ai"], "Q4 planning\n\n- ship the stack")
        XCTAssertEqual(texts["local"], "vision text")
    }

    func testSuggestionsLandInObsidianFrontmatter() {
        let note = makeNote(pages: [RecognizedPage(number: 1, text: "x", suggestedTitle: "Q4 planning", tags: ["planning", "work"])])
        let markdown = MarkdownRenderer.render(note, embedPath: nil, tags: ["ink"])
        XCTAssertTrue(markdown.contains("suggested_title: \"Q4 planning\""))
        XCTAssertTrue(markdown.contains("suggested_tags: [\"planning\", \"work\"]"))
    }

    func testConfigDefaultsAndValidation() throws {
        XCTAssertEqual(try JSONDecoder().decode(AITranscriptionConfig.self, from: Data("{}".utf8)), AITranscriptionConfig())
        XCTAssertThrowsError(try AITranscriptionConfig(effort: "extreme").validate())
        XCTAssertThrowsError(try AITranscriptionConfig(batchSize: 9).validate())
        let source = try JSONDecoder().decode(SourceConfig.self, from: Data(#"{"id":"s","path":"/x","recognizer":"claude"}"#.utf8))
        XCTAssertEqual(source.recognizer, .claude)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(SourceConfig(id: "s", device: "d", path: "/x")), as: UTF8.self).contains("recognizer"))
    }
}

import Foundation

/// The `ai` section of the config: transcription by Claude for sources with `"recognizer": "claude"`.
public struct AITranscriptionConfig: Codable, Equatable {
    public var model: String
    /// `low`, `medium`, `high`, `xhigh` or `max`. Higher reads harder handwriting better and costs more.
    public var effort: String
    /// Spending stops for the month at this many US dollars; Vision reads the rest for free.
    public var monthlyBudgetUSD: Double
    /// Let the API retry a declined page on Anthropic's recommended fallback model.
    public var serverFallback: Bool
    /// Pages sent in one request. More means fewer requests and less prompt overhead; one keeps answers short.
    public var batchSize: Int

    public init(model: String = "claude-opus-5-5", effort: String = "medium", monthlyBudgetUSD: Double = 5, serverFallback: Bool = true, batchSize: Int = 4) {
        self.model = model
        self.effort = effort
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.serverFallback = serverFallback
        self.batchSize = batchSize
    }

    private enum CodingKeys: String, CodingKey { case model, effort, monthlyBudgetUSD, serverFallback, batchSize }

    public init(from decoder: Decoder) throws {
        let defaults = AITranscriptionConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        effort = try container.decodeIfPresent(String.self, forKey: .effort) ?? defaults.effort
        monthlyBudgetUSD = try container.decodeIfPresent(Double.self, forKey: .monthlyBudgetUSD) ?? defaults.monthlyBudgetUSD
        serverFallback = try container.decodeIfPresent(Bool.self, forKey: .serverFallback) ?? defaults.serverFallback
        batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? defaults.batchSize
    }

    func validate() throws {
        guard ["low", "medium", "high", "xhigh", "max"].contains(effort) else {
            throw ConfigError.invalid("ai.effort must be low, medium, high, xhigh or max.")
        }
        guard monthlyBudgetUSD >= 0 else { throw ConfigError.invalid("ai.monthlyBudgetUSD can't be negative.") }
        guard (1...8).contains(batchSize) else { throw ConfigError.invalid("ai.batchSize must be between 1 and 8.") }
    }
}

/// US dollars per million tokens, as published for each model. Unknown models are priced like the most
/// expensive one, so the cap errs on the side of spending less.
enum ModelPricing {
    static let table: [String: (input: Double, output: Double)] = [
        "claude-fable-5-1": (10, 50), "claude-fable-5": (10, 50),
        "claude-opus-5-5": (4, 20), "claude-opus-5": (5, 25), "claude-opus-4-8": (5, 25), "claude-opus-4-7": (5, 25),
        "claude-sonnet-5-5": (2, 10), "claude-sonnet-5": (2, 10), "claude-sonnet-4-6": (3, 15),
        "claude-haiku-5-5": (0.10, 0.50), "claude-haiku-4-5": (1, 5),
    ]

    static func price(_ model: String) -> (input: Double, output: Double) {
        table[model] ?? (10, 50)
    }

    static func cost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let price = price(model)
        return (Double(inputTokens) * price.input + Double(outputTokens) * price.output) / 1_000_000
    }

    /// Models that accept `fallbacks: "default"`.
    static let serverFallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
}

/// What has been spent this month, kept next to the config.
struct SpendingLedger: Codable, Equatable {
    var month: String
    var spentUSD: Double
    var pages: Int
    /// Spend by source id, for per-source caps.
    var bySource: [String: Double]?
}

/// Reads handwriting with Claude: each page image goes to the Messages API, which returns the
/// transcription as Markdown plus a suggested title and tags. Opt-in per source, because the page
/// images leave the Mac. Falls back to Vision for any page it can't do: no key, over the monthly budget,
/// a declined request, a network or API error.
public final class ClaudeTextRecognizer: TextRecognizer {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let keychainAccount = "anthropic"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// A page is about 1,600 px tall; this many tokens covers the image, the prompt and the answer with room to spare.
    static let estimatedInputTokens = 3_500
    static let estimatedOutputTokens = 2_500

    public let config: AITranscriptionConfig
    private let secrets: SecretStore
    private let transport: HTTPTransport
    private let fallback: TextRecognizer
    private let ledgerFile: SecretFile<SpendingLedger>
    private let renderImages: (URL) throws -> [Data]
    private let now: () -> Date
    private let environment: [String: String]
    /// Pages that Vision read instead, with the reason, for the sync log.
    public private(set) var fallbacks: [String] = []
    /// The source whose export is being read, set by the engine, for its own budget.
    public var currentSource: (id: String, budgetUSD: Double?)?

    public init(
        config: AITranscriptionConfig,
        supportDirectory: URL,
        fallback: TextRecognizer,
        secrets: SecretStore = KeychainStore(),
        transport: HTTPTransport = URLSessionTransport(),
        renderImages: @escaping (URL) throws -> [Data] = { try PageImages.jpegs(for: $0, maxPixelDimension: 1600, quality: 0.85) },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.secrets = secrets
        self.transport = transport
        self.fallback = fallback
        self.renderImages = renderImages
        self.environment = environment
        self.now = now
        ledgerFile = SecretFile(url: supportDirectory.appendingPathComponent("ai-usage.json"))
    }

    public func recognize(fileAt url: URL) throws -> [RecognizedPage] {
        let images = try renderImages(url)
        guard !images.isEmpty else { return try fallback.recognize(fileAt: url) }
        var visionPages: [RecognizedPage]?
        func vision(_ number: Int, _ reason: String) throws -> RecognizedPage {
            fallbacks.append("\(url.lastPathComponent) page \(number): \(reason)")
            if visionPages == nil { visionPages = try fallback.recognize(fileAt: url) }
            return visionPages!.first { $0.number == number } ?? RecognizedPage(number: number, text: "")
        }

        guard let apiKey = self.apiKey() else {
            return try (1...images.count).map { try vision($0, "no Anthropic API key; run `inkrelay ai login`") }
        }
        let title = url.deletingPathExtension().lastPathComponent
        var results: [RecognizedPage] = []
        var index = 0
        let size = max(1, min(config.batchSize, 8))
        while index < images.count {
            // A batch is as big as the budget still allows, so the last few dollars read the last few pages.
            let affordable = pagesAffordable()
            guard affordable > 0 else {
                index += 1
                results.append(try vision(index, budgetProblem(pages: 1) ?? "monthly AI budget reached"))
                continue
            }
            let batch = Array(images[index..<min(index + min(size, affordable), images.count)])
            let numbers = Array((index + 1)...(index + batch.count))
            index += batch.count
            do {
                results += try transcribe(batch, numbers: numbers, of: images.count, title: title, apiKey: apiKey)
            } catch let error as TranscriptionError {
                for number in numbers { results.append(try vision(number, error.description)) }
            } catch {
                for number in numbers { results.append(try vision(number, error.localizedDescription)) }
            }
        }
        return results
    }

    /// Hands over the pages Vision had to read since the last call.
    public func takeFallbacks() -> [String] {
        defer { fallbacks = [] }
        return fallbacks
    }

    public func apiKey() -> String? {
        if let stored = try? secrets.secret(for: Self.keychainAccount), !stored.isEmpty { return stored }
        if let fromEnvironment = environment["ANTHROPIC_API_KEY"], !fromEnvironment.isEmpty { return fromEnvironment }
        return nil
    }

    // MARK: Budget

    static func month(of date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    func ledger() -> SpendingLedger {
        let month = Self.month(of: now())
        guard let stored = try? ledgerFile.load(), stored.month == month else { return SpendingLedger(month: month, spentUSD: 0, pages: 0) }
        return stored
    }

    var worstCasePerPage: Double {
        ModelPricing.cost(model: config.model, inputTokens: Self.estimatedInputTokens, outputTokens: Self.estimatedOutputTokens)
    }

    /// How many more pages fit under both caps at the worst case, so neither is overshot by a request.
    func pagesAffordable() -> Int {
        let current = ledger()
        var remaining = config.monthlyBudgetUSD - current.spentUSD
        if let source = currentSource, let budget = source.budgetUSD {
            remaining = min(remaining, budget - (current.bySource?[source.id] ?? 0))
        }
        return max(Int((remaining / worstCasePerPage).rounded(.down)), 0)
    }

    /// Why the next request can't go out, or nil.
    func budgetProblem(pages: Int) -> String? {
        let worstCase = worstCasePerPage * Double(pages)
        let current = ledger()
        if current.spentUSD + worstCase > config.monthlyBudgetUSD {
            return "monthly AI budget of $\(config.monthlyBudgetUSD) reached"
        }
        if let source = currentSource, let budget = source.budgetUSD, (current.bySource?[source.id] ?? 0) + worstCase > budget {
            return "monthly AI budget of $\(budget) for \(source.id) reached"
        }
        return nil
    }

    private func record(cost: Double, pages: Int) {
        var current = ledger()
        current.spentUSD += cost
        current.pages += pages
        if let source = currentSource {
            var bySource = current.bySource ?? [:]
            bySource[source.id, default: 0] += cost
            current.bySource = bySource
        }
        try? ledgerFile.save(current)
    }

    /// This month's spend, for `inkrelay ai status`.
    public func spentThisMonth() -> (usd: Double, pages: Int) {
        let current = ledger()
        return (current.spentUSD, current.pages)
    }

    // MARK: Request

    static let systemPrompt = """
    You transcribe pages of handwritten notes photographed from an e-ink tablet. Write down what the page says, \
    in the order a person would read it, without adding, correcting or summarizing anything. Rebuild the structure \
    the writer meant: join lines that wrap into paragraphs, keep list items as Markdown list items, keep numbering, \
    write open and ticked checkboxes as ☐ and ☑, and use Markdown headings only for text the writer set apart as a \
    heading. Put notes written in the margin at the end as > quoted lines. Write a word you can't read as [illegible]. \
    For title, give a short title for the page in the writer's own words. For tags, give up to five lowercase topic \
    words, or none if the page has no clear topic. A blank page has empty text.
    """

    /// One entry per page sent, in the same order, so a batch comes back as a list.
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "pages": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "page": ["type": "integer"],
                        "text": ["type": "string"],
                        "title": ["type": "string"],
                        "tags": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["page", "text", "title", "tags"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["pages"],
        "additionalProperties": false,
    ]

    func requestBody(_ images: [Data], numbers: [Int], of pages: Int, title: String) -> [String: Any] {
        var content: [[String: Any]] = []
        for (image, number) in zip(images, numbers) {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]])
            content.append(["type": "text", "text": "Page \(number) of \(pages) of the notebook \"\(title)\"."])
        }
        if images.count > 1 {
            content.append(["type": "text", "text": "Transcribe each page above as one entry in pages, with its page number."])
        }
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": min(16_000 * images.count, 64_000),
            "system": Self.systemPrompt,
            "output_config": ["effort": config.effort, "format": ["type": "json_schema", "schema": Self.schema]],
            "messages": [["role": "user", "content": content]],
        ]
        if usesServerFallback { body["fallbacks"] = "default" }
        return body
    }

    func requestBody(_ image: Data, page: Int, of pages: Int, title: String) -> [String: Any] {
        requestBody([image], numbers: [page], of: pages, title: title)
    }

    var usesServerFallback: Bool { config.serverFallback && ModelPricing.serverFallbackModels.contains(config.model) }

    private func transcribe(_ images: [Data], numbers: [Int], of pages: Int, title: String, apiKey: String) throws -> [RecognizedPage] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300 + 120 * Double(images.count - 1)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if usesServerFallback { request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(images, numbers: numbers, of: pages, title: title))

        let (data, response) = try transport.send(request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard response.statusCode == 200 else {
            throw TranscriptionError.api(response.statusCode, CloudAPIError.message(in: object))
        }
        // Billed whatever the outcome, so recorded before anything else is checked.
        let usage = object["usage"] as? [String: Any] ?? [:]
        let input = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
        let output = usage["output_tokens"] as? Int ?? 0
        record(cost: ModelPricing.cost(model: object["model"] as? String ?? config.model, inputTokens: input, outputTokens: output), pages: images.count)

        if object["stop_reason"] as? String == "refusal" { throw TranscriptionError.declined }
        if object["stop_reason"] as? String == "max_tokens" { throw TranscriptionError.truncated }
        let content = object["content"] as? [[String: Any]] ?? []
        guard let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let entries = json["pages"] as? [[String: Any]] else {
            throw TranscriptionError.unreadableReply
        }
        // Matched by page number, then by position, so a model that miscounts still lines up.
        return try numbers.enumerated().map { position, number in
            guard let entry = entries.first(where: { $0["page"] as? Int == number }) ?? (entries.indices.contains(position) ? entries[position] : nil),
                  let transcription = entry["text"] as? String else {
                throw TranscriptionError.unreadableReply
            }
            let suggested = (entry["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let tags = (entry["tags"] as? [String] ?? []).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return RecognizedPage(number: number, text: transcription, suggestedTitle: suggested, tags: Array(tags.prefix(5)))
        }
    }
}

enum TranscriptionError: Error, CustomStringConvertible {
    case api(Int, String)
    case declined
    case truncated
    case unreadableReply

    var description: String {
        switch self {
        case .api(let status, let message): return "Anthropic API returned HTTP \(status)\(message.isEmpty ? "" : ": \(message)")"
        case .declined: return "the model declined the page"
        case .truncated: return "the answer was cut off"
        case .unreadableReply: return "the answer wasn't the expected JSON"
        }
    }
}

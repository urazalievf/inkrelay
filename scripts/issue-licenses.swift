// Issues Pro keys for a Lemon Squeezy store and emails them through Mail, keeping the signing key on this Mac.
// Run it after a sale, or from a daily launchd job.
//
//   swift scripts/issue-licenses.swift --store 12345 --founder 777 --yearly 778          dry run: what still needs a key
//   swift scripts/issue-licenses.swift --store 12345 --founder 777 --yearly 778 --send   issues and emails them
//   swift scripts/issue-licenses.swift --order 987 --founder 777 --send                  one Founder order
//   swift scripts/issue-licenses.swift --invoice 654 --yearly 778 --send                 one yearly invoice
//
// Founder orders (the one-time product) get a key for keeps. The yearly subscription gets a key for the paid
// year plus 14 days' grace from its first invoice, and a new one from every paid renewal, so the next key
// arrives before the last one ends. Refunded, void and unpaid invoices, mid-year plan changes ("updated") and
// test-mode purchases get none (add --include-test to try the flow). Keys are checked offline, so a key
// already sent can't be taken back; a refund after that keeps working until the key's date.
//
// Needs the store's API key in the environment as LEMONSQUEEZY_API_KEY (Settings → API in Lemon Squeezy),
// and `scripts/make-license.swift --init` done once. Orders and invoices already handled are listed in
// ~/Library/Application Support/InkRelay/licensing/issued.json, so nothing is sent twice.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("✗ " + message + "\n").utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

let send = CommandLine.arguments.contains("--send")
let includeTest = CommandLine.arguments.contains("--include-test")
let founderProduct = option("--founder")
let yearlyProduct = option("--yearly")
/// Days a yearly key keeps working past its paid year, so a renewal that's retried or picked up a day late
/// never pauses anything.
let graceDays = 14
let keyFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/InkRelay/licensing", isDirectory: true)
let issuedURL = keyFolder.appendingPathComponent("issued.json")
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let makeLicense = repository.appendingPathComponent("scripts/make-license.swift").path
let apiBase = ProcessInfo.processInfo.environment["LEMONSQUEEZY_API_URL"] ?? "https://api.lemonsqueezy.com/v1/"

guard let apiKey = ProcessInfo.processInfo.environment["LEMONSQUEEZY_API_KEY"], !apiKey.isEmpty else {
    fail("Set LEMONSQUEEZY_API_KEY in the environment (Lemon Squeezy → Settings → API).")
}
let usage = """
Usage: swift scripts/issue-licenses.swift --store ID [--founder PRODUCT] [--yearly PRODUCT] [--send]
       swift scripts/issue-licenses.swift --order ID --founder PRODUCT [--send]
       swift scripts/issue-licenses.swift --invoice ID --yearly PRODUCT [--send]
"""
let store = option("--store"), singleOrder = option("--order"), singleInvoice = option("--invoice")
guard (store != nil && (founderProduct != nil || yearlyProduct != nil))
        || (singleOrder != nil && founderProduct != nil)
        || (singleInvoice != nil && yearlyProduct != nil) else {
    print(usage)
    exit(1)
}

func get(_ path: String) -> [String: Any] {
    var request = URLRequest(url: URL(string: apiBase + path)!)
    request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
    let done = DispatchSemaphore(value: 0)
    var result: (Data?, Int) = (nil, 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        result = (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        done.signal()
    }.resume()
    done.wait()
    guard result.1 == 200, let data = result.0, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        fail("Lemon Squeezy answered HTTP \(result.1) for \(path).")
    }
    return object
}

/// Every page of a list.
func getAll(_ path: String) -> [[String: Any]] {
    var items: [[String: Any]] = []
    var page = 1
    while true {
        let reply = get("\(path)&page[size]=100&page[number]=\(page)")
        let batch = reply["data"] as? [[String: Any]] ?? []
        items += batch
        let meta = (reply["meta"] as? [String: Any])?["page"] as? [String: Any]
        if batch.isEmpty || page >= (meta?["lastPage"] as? Int ?? page) { break }
        page += 1
    }
    return items
}

func string(_ value: Any?) -> String {
    if let text = value as? String { return text }
    if let number = value as? Int { return String(number) }
    return ""
}

/// Something that gets one key: a Founder order, or a paid invoice of the yearly subscription.
struct Sale {
    /// Its entry in issued.json: the order id as before, `invoice:<id>` for invoices.
    var record: String
    var label: String
    var email: String
    var name: String
    /// The key's last day, `yyyy-MM-dd`; nil for keeps.
    var expiresOn: String?
    var renewal: Bool
    var subscription: String?
    var created: String
}

let issued = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: issuedURL))) as? [String: String]) ?? [:]
var sales: [Sale] = []

// Founder: one-time orders of that product.
if let founderProduct {
    let orders: [[String: Any]]
    if let singleOrder {
        orders = (get("orders/\(singleOrder)")["data"] as? [String: Any]).map { [$0] } ?? []
    } else if let store, singleInvoice == nil {
        orders = getAll("orders?filter[store_id]=\(store)")
    } else {
        orders = []
    }
    for item in orders {
        let id = string(item["id"])
        let attributes = item["attributes"] as? [String: Any] ?? [:]
        let first = attributes["first_order_item"] as? [String: Any] ?? [:]
        guard attributes["status"] as? String == "paid", string(first["product_id"]) == founderProduct,
              includeTest || attributes["test_mode"] as? Bool != true,
              let email = attributes["user_email"] as? String, !email.isEmpty else { continue }
        sales.append(Sale(record: id, label: "Founder order #\(string(attributes["order_number"]))", email: email,
                          name: attributes["user_name"] as? String ?? "", expiresOn: nil, renewal: false, subscription: nil,
                          created: string(attributes["created_at"])))
    }
}

/// `yyyy-MM-dd` of an API timestamp, a year and the grace period later.
func yearLater(_ timestamp: String) -> String? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = timestamp.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
          let end = calendar.date(byAdding: DateComponents(year: 1, day: graceDays), to: day) else { return nil }
    let out = calendar.dateComponents([.year, .month, .day], from: end)
    return String(format: "%04d-%02d-%02d", out.year!, out.month!, out.day!)
}

// Yearly: paid invoices of subscriptions to that product, the first one and each renewal.
if let yearlyProduct {
    let invoices: [[String: Any]]
    if let singleInvoice {
        invoices = (get("subscription-invoices/\(singleInvoice)")["data"] as? [String: Any]).map { [$0] } ?? []
    } else if let store, singleOrder == nil {
        invoices = getAll("subscription-invoices?filter[store_id]=\(store)&filter[status]=paid")
    } else {
        invoices = []
    }
    var products: [String: String] = [:]
    for item in invoices {
        let id = string(item["id"])
        let attributes = item["attributes"] as? [String: Any] ?? [:]
        let reason = attributes["billing_reason"] as? String ?? ""
        let subscription = string(attributes["subscription_id"])
        guard attributes["status"] as? String == "paid", attributes["refunded"] as? Bool != true,
              reason == "initial" || reason == "renewal", !subscription.isEmpty,
              includeTest || attributes["test_mode"] as? Bool != true,
              let email = attributes["user_email"] as? String, !email.isEmpty,
              let expiresOn = yearLater(string(attributes["created_at"])) else { continue }
        if products[subscription] == nil {
            let found = (get("subscriptions/\(subscription)")["data"] as? [String: Any])?["attributes"] as? [String: Any]
            products[subscription] = string(found?["product_id"])
        }
        guard products[subscription] == yearlyProduct else { continue }
        sales.append(Sale(record: "invoice:\(id)", label: "Yearly invoice \(id) (\(reason))", email: email,
                          name: attributes["user_name"] as? String ?? "", expiresOn: expiresOn, renewal: reason == "renewal",
                          subscription: subscription, created: string(attributes["created_at"])))
    }
}

// Only the newest paid invoice of a subscription needs a key; older ones still without one (a first run that
// catches up, say) are marked done rather than sending someone a stack of keys.
var pending = sales.filter { issued[$0.record] == nil }
var superseded: [(Sale, Sale)] = []
let newest = Dictionary(grouping: pending.filter { $0.subscription != nil }, by: { $0.subscription! })
    .mapValues { $0.max { $0.created < $1.created }! }
pending = pending.filter { sale in
    guard let subscription = sale.subscription, let latest = newest[subscription], latest.record != sale.record else { return true }
    superseded.append((sale, latest))
    return false
}

print("\(sales.count) paid sale(s), \(pending.count) still without a key.")
for sale in pending {
    print("  \(sale.label): \(sale.name) <\(sale.email)>, key \(sale.expiresOn.map { "through \($0)" } ?? "for keeps")")
}
for (old, latest) in superseded {
    print("  \(old.label): skipped, \(latest.label) is newer")
}
guard !pending.isEmpty || !superseded.isEmpty else { exit(0) }
guard send else {
    print("Dry run. Add --send to issue keys and email them.")
    exit(0)
}

func longDate(_ day: String) -> String {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: day) else { return day }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateFormat = "MMMM d, yyyy"
    return formatter.string(from: date)
}

var record = issued
func save() {
    do {
        try FileManager.default.createDirectory(at: keyFolder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: issuedURL, options: .atomic)
    } catch {
        fail("Couldn't write \(issuedURL.path): \(error.localizedDescription)")
    }
}
for (old, latest) in superseded {
    record[old.record] = "superseded by \(latest.record)"
}
save()

for sale in pending {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [makeLicense, "--name", sale.name.isEmpty ? sale.email : sale.name, "--email", sale.email]
        + (sale.expiresOn.map { ["--expires", $0] } ?? [])
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    let key = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    process.waitUntilExit()
    guard process.terminationStatus == 0, key.hasPrefix("INK1.") else { fail("Couldn't issue a key for \(sale.label).") }

    let subject: String
    let opening: String
    let terms: String
    if let expiresOn = sale.expiresOn {
        let until = longDate(expiresOn)
        subject = sale.renewal ? "Your InkRelay Pro key for the coming year" : "Your InkRelay Pro license"
        opening = sale.renewal ? "Thank you for renewing InkRelay Pro. Here is the key for the coming year." : "Thank you for subscribing to InkRelay Pro."
        terms = "The key works offline on every Mac you use, through \(until). Each renewal emails a new key a year on; enter it the same way. If you cancel, Pro keeps working until \(until)."
    } else {
        subject = "Your InkRelay Pro license"
        opening = "Thank you for buying InkRelay Pro as a Founder."
        terms = "The key works offline on every Mac you use, for keeps."
    }
    let body = """
    \(opening)

    Your license key:

    \(key)

    In InkRelay's menu choose Enter License… and paste the key, or run: inkrelay license enter \(key)

    \(terms) Keep this email; if you lose the key, reply and it will be sent again.
    """
    let script = """
    tell application "Mail"
        set m to make new outgoing message with properties {subject:\(subject.debugDescription), content:\(body.debugDescription), visible:false}
        tell m to make new to recipient with properties {address:\(sale.email.debugDescription)}
        send m
    end tell
    """
    let mail = Process()
    mail.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    mail.arguments = ["-e", script]
    try mail.run()
    mail.waitUntilExit()
    guard mail.terminationStatus == 0 else { fail("Mail couldn't send to \(sale.email); the key for \(sale.label) is: \(key)") }
    record[sale.record] = ISO8601DateFormatter().string(from: Date())
    save()
    print("• Sent a key to \(sale.email) for \(sale.label).")
}

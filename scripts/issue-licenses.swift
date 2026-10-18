// Issues Pro keys for paid orders from a Lemon Squeezy store and emails them through Mail, keeping the
// signing key on this Mac. Run it after a sale, or from a daily launchd job.
//
//   swift scripts/issue-licenses.swift --store 12345 --product 777          dry run: paid orders of that product without a key
//   swift scripts/issue-licenses.swift --store 12345 --product 777 --send   issues and emails them
//   swift scripts/issue-licenses.swift --order 987 --send                   one order
//
// Only orders of the given product count, and test-mode orders never do (add --include-test to try the flow).
//
// Needs the store's API key in the environment as LEMONSQUEEZY_API_KEY (Settings → API in Lemon Squeezy),
// and `scripts/make-license.swift --init` done once. Orders already handled are listed in
// ~/Library/Application Support/InkRelay/licensing/issued.json, so nothing is sent twice.
import CryptoKit
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
let keyFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/InkRelay/licensing", isDirectory: true)
let issuedURL = keyFolder.appendingPathComponent("issued.json")
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let makeLicense = repository.appendingPathComponent("scripts/make-license.swift").path

guard let apiKey = ProcessInfo.processInfo.environment["LEMONSQUEEZY_API_KEY"], !apiKey.isEmpty else {
    fail("Set LEMONSQUEEZY_API_KEY in the environment (Lemon Squeezy → Settings → API).")
}
guard (option("--store") != nil && option("--product") != nil) || option("--order") != nil else {
    print("Usage: swift scripts/issue-licenses.swift --store ID --product ID [--send]   or   --order ID [--send]")
    exit(1)
}
let wantedProduct = option("--product")
let includeTest = CommandLine.arguments.contains("--include-test")

struct Order {
    var id: String
    var number: Int
    var email: String
    var name: String
    var product: String
    var productID: String
    var paid: Bool
    var test: Bool
}

func get(_ path: String) throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://api.lemonsqueezy.com/v1/" + path)!)
    request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
    let done = DispatchSemaphore(value: 0)
    var result: (Data?, Int) = (nil, 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        result = (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        done.signal()
    }.resume()
    done.wait()
    guard result.1 == 200, let data = result.0, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fail("Lemon Squeezy answered HTTP \(result.1) for \(path).")
    }
    return object
}

func order(from item: [String: Any]) -> Order? {
    guard let id = item["id"] as? String, let attributes = item["attributes"] as? [String: Any] else { return nil }
    let first = attributes["first_order_item"] as? [String: Any] ?? [:]
    return Order(
        id: id,
        number: attributes["order_number"] as? Int ?? 0,
        email: attributes["user_email"] as? String ?? "",
        name: attributes["user_name"] as? String ?? "",
        product: first["product_name"] as? String ?? "",
        productID: (first["product_id"] as? Int).map(String.init) ?? (first["product_id"] as? String ?? ""),
        paid: attributes["status"] as? String == "paid",
        test: attributes["test_mode"] as? Bool == true
    )
}

var orders: [Order] = []
if let single = option("--order") {
    if let data = try get("orders/\(single)")["data"] as? [String: Any], let found = order(from: data) { orders = [found] }
} else if let store = option("--store") {
    var page = 1
    while true {
        let reply = try get("orders?filter[store_id]=\(store)&page[size]=100&page[number]=\(page)")
        let items = (reply["data"] as? [[String: Any]] ?? []).compactMap(order(from:))
        orders += items
        let meta = (reply["meta"] as? [String: Any])?["page"] as? [String: Any]
        if items.isEmpty || page >= (meta?["lastPage"] as? Int ?? page) { break }
        page += 1
    }
}

let issued = (try? JSONSerialization.jsonObject(with: Data(contentsOf: issuedURL)) as? [String: String]) ?? [:]
let pending = orders.filter { item in
    item.paid && !item.email.isEmpty && issued[item.id] == nil
        && (wantedProduct == nil || item.productID == wantedProduct)
        && (includeTest || !item.test)
}
print("\(orders.count) order(s), \(pending.count) paid and still without a key.")
guard !pending.isEmpty else { exit(0) }

for item in pending {
    print("  #\(item.number) \(item.name) <\(item.email)> \(item.product)")
}
guard send else {
    print("Dry run. Add --send to issue keys and email them.")
    exit(0)
}

var record = issued
for item in pending {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [makeLicense, "--name", item.name.isEmpty ? item.email : item.name, "--email", item.email]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    let key = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    process.waitUntilExit()
    guard process.terminationStatus == 0, key.hasPrefix("INK1.") else { fail("Couldn't issue a key for order \(item.number).") }

    let body = """
    Thank you for buying InkRelay Pro.

    Your license key:

    \(key)

    In InkRelay's menu choose Enter License… and paste the key, or run: inkrelay license enter \(key)

    The key works offline on every Mac you use, for keeps. Keep this email; if you lose the key, reply and it will be sent again.
    """
    let script = """
    tell application "Mail"
        set m to make new outgoing message with properties {subject:"Your InkRelay Pro license", content:\(body.debugDescription), visible:false}
        tell m to make new to recipient with properties {address:\(item.email.debugDescription)}
        send m
    end tell
    """
    let mail = Process()
    mail.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    mail.arguments = ["-e", script]
    try mail.run()
    mail.waitUntilExit()
    guard mail.terminationStatus == 0 else { fail("Mail couldn't send to \(item.email); the key for order \(item.number) is: \(key)") }
    record[item.id] = ISO8601DateFormatter().string(from: Date())
    try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: issuedURL, options: .atomic)
    print("• Sent a key to \(item.email) for order #\(item.number).")
}

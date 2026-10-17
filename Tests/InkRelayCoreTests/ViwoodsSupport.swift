import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import InkRelayCore

/// Answers requests from a script keyed by URL path (API calls) or full URL (downloads).
final class FakeTransport: HTTPTransport {
    struct Sent {
        var request: URLRequest
        var path: String
        var body: [String: Any]
    }

    typealias Handler = (Sent) throws -> (Int, Data)

    var handlers: [String: Handler] = [:]
    var sent: [Sent] = []

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let path = String(url.path.dropFirst())
        let record = Sent(request: request, path: path, body: body)
        sent.append(record)
        guard let handler = handlers[path] ?? handlers[url.absoluteString] else {
            XCTFail("unexpected request to \(url)")
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let (status, data) = try handler(record)
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    /// Registers a 200 envelope with the given payload.
    func answer(_ path: String, _ payload: Any) {
        handlers[path] = { _ in (200, try Self.envelope(payload)) }
    }

    static func envelope(_ payload: Any, code: Int = 200) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["code": code, "msg": "success", "data": payload])
    }

    /// A notebook or memo body the way the cloud sends it: gzip, base64, inside an envelope.
    static func blobEnvelope(_ json: Any) throws -> Data {
        let raw = try JSONSerialization.data(withJSONObject: json)
        return try envelope(["data": gzip(raw).base64EncodedString(), "uuid": "x"])
    }

    /// Foundation deflates but doesn't write gzip framing; the trailer is ignored by the reader, so zeros do.
    static func gzip(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        out += deflated
        out += Data(repeating: 0, count: 8)
        return out
    }
}

/// A tiny PNG, for pages.
func makePNG(width: Int = 12, height: Int = 16, gray: CGFloat = 0) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

final class FakePlanDestination: PlanDestination {
    struct Upsert: Equatable {
        var todo: DailyTodo
        var previous: String?
    }

    let id: String
    var upserts: [Upsert] = []

    init(id: String = "calendar") {
        self.id = id
    }

    func upsert(_ todo: DailyTodo, previous: String?) throws -> String {
        upserts.append(Upsert(todo: todo, previous: previous))
        return previous ?? "event-\(todo.id)"
    }
}

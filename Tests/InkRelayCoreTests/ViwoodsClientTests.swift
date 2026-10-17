import CryptoKit
import XCTest
@testable import InkRelayCore

final class ViwoodsClientTests: XCTestCase {
    private var transport: FakeTransport!
    private var store: MemoryCredentialStore!
    private var client: ViwoodsClient!

    override func setUp() {
        transport = FakeTransport()
        store = MemoryCredentialStore(credentials: ViwoodsCredentials(token: "tok-1", updatedAt: Date()))
        client = ViwoodsClient(transport: transport, credentials: store)
    }

    func testSignsSortedParametersWithTheKeyAndSendsTheSameBody() throws {
        let request = try ViwoodsClient.request(path: "api/v1/paperSync/get", body: ["uuid": .string("abc")], token: "tok-1")

        let joined = "uri=/api/v1/paperSync/get&uuid=abc" + ViwoodsClient.signingKey
        let expected = Insecure.MD5.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sign"), expected)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Access-Token"), "tok-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Machine-Model"), "web")
        XCTAssertEqual(request.url?.absoluteString, "https://api.viwoods.com/api/v1/paperSync/get")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        XCTAssertEqual(body?["uuid"] as? String, "abc")
        XCTAssertEqual(body?["uri"] as? String, "/api/v1/paperSync/get")
    }

    func testIntegersAreSignedAndSentAsNumbers() throws {
        let request = try ViwoodsClient.request(path: "p", body: ["b": .int(-1), "a": .string("x")], token: nil)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        XCTAssertEqual(body?["b"] as? Int, -1)
        XCTAssertEqual(ViwoodsClient.sign(["b": .int(-1), "a": .string("x"), "uri": .string("/p")]), request.value(forHTTPHeaderField: "Sign"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testListsAcrossPages() throws {
        var calls = 0
        transport.handlers["api/v1/resourceSync/getPage"] = { sent in
            calls += 1
            let index = sent.body["pageIndex"] as? Int ?? 0
            XCTAssertEqual(sent.body["appType"] as? Int, 1)
            XCTAssertEqual(sent.body["resourceId"] as? String, "parent")
            let item: [String: Any] = ["resourceId": "n\(index)", "name": "Note \(index)", "resourceType": 1, "lastModifiedTime": 5]
            return (200, try FakeTransport.envelope(["count": 2, "pageIndex": index, "pageSize": 100, "list": [item]]))
        }

        let items = try client.contents(of: .paper, parent: "parent")

        XCTAssertEqual(items.map(\.name), ["Note 1", "Note 2"])
        XCTAssertEqual(calls, 2)
    }

    func testRefreshesTheTokenOnceWhenTheCloudSaysItExpired() throws {
        var tokensSeen: [String] = []
        transport.handlers["api/v1/resourceSync/getRootFolder"] = { sent in
            let token = sent.request.value(forHTTPHeaderField: "Access-Token") ?? ""
            tokensSeen.append(token)
            if token == "tok-1" { return (200, try FakeTransport.envelope(NSNull(), code: 10104)) }
            return (200, try FakeTransport.envelope([["name": "Paper", "appType": 1, "count": 3]]))
        }
        transport.handlers[ViwoodsClient.refreshPath] = { sent in
            XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
            return (200, try FakeTransport.envelope(["token": "tok-2"]))
        }

        let folders = try client.rootFolders()

        XCTAssertEqual(folders, [ViwoodsRootFolder(name: "Paper", appType: 1, count: 3)])
        XCTAssertEqual(tokensSeen, ["tok-1", "tok-2"])
        XCTAssertEqual(store.credentials?.token, "tok-2", "the refreshed token is saved for next time")
    }

    func testHTTP401WithFailedRefreshAsksToLogInAgain() {
        transport.handlers["api/v1/resourceSync/getRootFolder"] = { _ in (401, Data()) }
        transport.handlers[ViwoodsClient.refreshPath] = { _ in (200, try FakeTransport.envelope(NSNull(), code: 401)) }

        XCTAssertThrowsError(try client.rootFolders()) { error in
            XCTAssertEqual(error as? ViwoodsError, .notLoggedIn)
        }
    }

    func testIncorrectTokenAsksToLogInWithoutRefreshing() {
        transport.handlers["api/v1/resourceSync/getRootFolder"] = { _ in
            (200, try JSONSerialization.data(withJSONObject: ["code": 10015, "msg": "Incorrect token"]))
        }
        XCTAssertThrowsError(try client.rootFolders()) { error in
            XCTAssertEqual(error as? ViwoodsError, .notLoggedIn)
        }
        XCTAssertEqual(transport.sent.map(\.path), ["api/v1/resourceSync/getRootFolder"])
    }

    func testNoStoredTokenAsksToLogIn() {
        let client = ViwoodsClient(transport: transport, credentials: MemoryCredentialStore())
        XCTAssertThrowsError(try client.rootFolders()) { error in
            XCTAssertEqual(error as? ViwoodsError, .notLoggedIn)
        }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testOtherErrorCodesSurfaceTheCloudsMessage() {
        transport.handlers["api/v1/paperSync/get"] = { _ in
            (200, try JSONSerialization.data(withJSONObject: ["code": 500, "msg": "boom"]))
        }
        XCTAssertThrowsError(try client.notebook(.paper, uuid: "u")) { error in
            XCTAssertEqual(error as? ViwoodsError, .api("api/v1/paperSync/get", 500, "boom"))
        }
    }

    func testInflatesNotebookBodies() throws {
        let notebook: [String: Any] = [
            "note": ["id": "n1", "fileName": "ll", "lastModifiedTime": 7],
            "pages": [["page": ["id": "p2", "order": 1]], ["page": ["id": "p1", "order": 0]]],
            "resourceRefs": [
                ["fileName": "Thumbnail_p1.png", "remoteUrl": "https://cdn/thumb1.png", "ownerPageId": "p1"],
                ["fileName": "screenshotBmp_p1.png", "remoteUrl": "https://cdn/shot1.png", "ownerPageId": "p1"],
                ["fileName": "mainBmp_p2.png", "remoteUrl": "https://cdn/main2.png", "ownerPageId": "p2"],
            ],
        ]
        transport.handlers["api/v1/paperSync/get"] = { _ in (200, try FakeTransport.blobEnvelope(notebook)) }

        let decoded = try client.notebook(.paper, uuid: "n1")

        XCTAssertEqual(decoded.note.fileName, "ll")
        XCTAssertEqual(decoded.pageImageURLs().map(\.absoluteString), ["https://cdn/shot1.png", "https://cdn/main2.png"],
                       "pages come in order, the rendered page is preferred and the ink layer is the fallback")
    }

    func testMeetingNotesUseTheMeetingEndpoint() throws {
        transport.handlers["api/v1/meetingSync/get"] = { _ in
            (200, try FakeTransport.blobEnvelope(["note": ["id": "m", "fileName": "Standup"], "pages": [], "resourceRefs": []]))
        }
        XCTAssertEqual(try client.notebook(.meeting, uuid: "m").note.fileName, "Standup")
    }

    func testLoginVerifiesTheTokenBeforeSaving() throws {
        let fresh = MemoryCredentialStore()
        let client = ViwoodsClient(transport: transport, credentials: fresh)
        transport.answer("api/v1/resourceSync/getRootFolder", [["name": "Memo", "appType": 6, "count": 1]])

        let folders = try client.login(token: "  \"pasted-token\"\n")

        XCTAssertEqual(folders.first?.name, "Memo")
        XCTAssertEqual(fresh.credentials?.token, "pasted-token", "quotes and whitespace from the paste are dropped")
    }

    func testFileCredentialStoreKeepsTheTokenPrivate() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = FileCredentialStore(url: folder.url.appendingPathComponent("nested/viwoods-token.json"))

        XCTAssertNil(try store.load())
        try store.save(ViwoodsCredentials(token: "t", updatedAt: Date(timeIntervalSince1970: 1)))

        XCTAssertEqual(try store.load()?.token, "t")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testGzipRejectsOtherData() {
        XCTAssertThrowsError(try Gzip.decompress(Data("plain".utf8)))
        XCTAssertEqual(try Gzip.decompress(try FakeTransport.gzip(Data("round trip".utf8))), Data("round trip".utf8))
    }

    func testPlannerDatesAreZeroPadded() {
        XCTAssertEqual(ViwoodsDate.normalize("2026-1-13"), "2026-01-13")
        XCTAssertEqual(ViwoodsDate.normalize("2026-10-02"), "2026-10-02")
        XCTAssertNil(ViwoodsDate.normalize("yesterday"))
        XCTAssertNil(ViwoodsDate.normalize("2026-13-01"))
    }
}

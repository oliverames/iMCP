import XCTest

final class CloudflareTokenCheckTests: XCTestCase {
    private func parse(_ json: String, status: Int = 200) -> CloudflareTokenVerification {
        CloudflareTokenVerification.parse(data: Data(json.utf8), statusCode: status)
    }

    func testActiveTokenIsValid() {
        let verdict = parse(#"{"success":true,"result":{"id":"x","status":"active"},"errors":[]}"#)
        XCTAssertEqual(verdict, .valid(expiresOn: nil))
        XCTAssertEqual(verdict.summary, "Token is valid.")
    }

    func testExpiryShowsTheDateOnly() {
        let verdict = parse(
            #"{"success":true,"result":{"status":"active","expires_on":"2027-01-31T23:59:59Z"}}"#
        )
        XCTAssertEqual(verdict.summary, "Token is valid. It expires on 2027-01-31.")
    }

    func testExpiredAndDisabledAreNotActive() {
        XCTAssertEqual(
            parse(#"{"success":true,"result":{"status":"expired"}}"#),
            .notActive("This token has expired. Create a new one.")
        )
        guard case .notActive(let text) = parse(#"{"success":true,"result":{"status":"disabled"}}"#) else {
            return XCTFail("disabled should not be active")
        }
        XCTAssertTrue(text.contains("disabled"))
    }

    func testRejectedTokenCarriesCloudflaresReason() {
        let verdict = parse(
            #"{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}],"result":null}"#,
            status: 401
        )
        XCTAssertEqual(verdict, .rejected("Cloudflare did not accept this token: Invalid API Token"))
        XCTAssertFalse(verdict.isValid)
    }

    func testUnreadableAnswerIsRejected() {
        XCTAssertFalse(parse("<html>", status: 502).isValid)
        XCTAssertFalse(parse(#"{"success":true,"result":{"status":"active"}}"#, status: 500).isValid)
    }

    func testVerifyCallUsesTheUserEndpointWithBearerAuth() async throws {
        final class Box: @unchecked Sendable { var request: URLRequest? }
        let box = Box()
        let client = CloudflareAPIClient(apiToken: "secret-token") { request in
            box.request = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"success":true,"result":{"status":"active"}}"#.utf8), response)
        }
        let verdict = try await client.verifyToken()
        XCTAssertTrue(verdict.isValid)
        XCTAssertEqual(box.request?.url?.absoluteString, "https://api.cloudflare.com/client/v4/user/tokens/verify")
        XCTAssertEqual(box.request?.httpMethod, "GET")
        XCTAssertEqual(box.request?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testPermissionLinesNameEveryRequiredPermission() {
        let lines = CloudflareChecklist.permissionLines
        XCTAssertEqual(lines.count, CloudflareChecklist.requiredPermissions.count)
        XCTAssertTrue(lines.contains { $0.contains("DNS") && $0.contains("Edit") })
        XCTAssertTrue(lines.contains { $0.contains("Cloudflare Tunnel") && $0.contains("Edit") })
        XCTAssertEqual(CloudflareChecklist.apiTokensURL.host, "dash.cloudflare.com")
    }

    @MainActor
    func testTokenSignInStoresOnlyInTheInjectedStorageAndCanBeRemoved() async throws {
        let suite = "imcp-cf-token-\(UUID().uuidString)"
        let defaults = TestDefaults.suite(named: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = InMemoryCloudflareSecretStorage()
        let controller = CloudflareTunnelController(
            secretStorage: storage,
            defaults: defaults,
            httpTransport: { request in
                let path = request.url!.path
                let body: String
                if path.hasSuffix("/user/tokens/verify") {
                    body = #"{"success":true,"result":{"status":"active"}}"#
                } else {
                    body =
                        #"{"success":true,"result":[{"id":"z1","name":"example.com","status":"active","account":{"id":"a1","name":"A"}}]}"#
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(body.utf8), response)
            },
            certSearchURLs: []
        )
        let verdict = await controller.checkAPIToken("tok")
        XCTAssertTrue(verdict.isValid)
        await controller.signIn(withAPIToken: "tok")
        XCTAssertEqual(try storage.load()?.apiToken, "tok")
        XCTAssertEqual(controller.zones.map(\.name), ["example.com"])
        XCTAssertTrue(controller.isSignedInWithToken)

        controller.logOut()
        XCTAssertNil(try storage.load())
        XCTAssertFalse(controller.isSignedInWithToken)
        XCTAssertNil(controller.account)
    }
}

final class CloudflareIngressTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(method: String, body: Data?)] = []
        func add(_ method: String, _ body: Data?) { lock.withLock { items.append((method, body)) } }
        var all: [(method: String, body: Data?)] { lock.withLock { items } }
    }

    private func client(
        log: Log,
        getStatus: Int = 200,
        getBody: String
    ) -> CloudflareAPIClient {
        CloudflareAPIClient(apiToken: "tok") { request in
            let method = request.httpMethod ?? "GET"
            log.add(method, request.httpBody)
            let isGet = method == "GET"
            let body = isGet ? getBody : #"{"success":true,"result":{}}"#
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: isGet ? getStatus : 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }

    private func putConfig(_ log: Log) throws -> [String: Any] {
        let put = try XCTUnwrap(log.all.first { $0.method == "PUT" })
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(put.body)) as? [String: Any]
        return try XCTUnwrap(json?["config"] as? [String: Any])
    }

    func testAFailedReadAbortsWithoutWriting() async {
        let log = Log()
        let client = client(
            log: log,
            getStatus: 500,
            getBody: #"{"success":false,"errors":[{"code":1000,"message":"boom"}]}"#
        )
        do {
            try await client.configureTunnelIngress(
                accountID: "a",
                tunnelID: "t",
                hostname: "imcp.example.com",
                serviceURL: "http://localhost:1"
            )
            XCTFail("a failed read must abort")
        } catch {}
        XCTAssertEqual(log.all.map(\.method), ["GET"], "nothing may be written after a failed read")
    }

    func testAnUnreadableReadAbortsWithoutWriting() async {
        let log = Log()
        let client = client(log: log, getBody: "<html>")
        do {
            try await client.configureTunnelIngress(
                accountID: "a",
                tunnelID: "t",
                hostname: "imcp.example.com",
                serviceURL: "http://localhost:1"
            )
            XCTFail("an unreadable read must abort")
        } catch {}
        XCTAssertEqual(log.all.map(\.method), ["GET"])
    }

    func testExistingRulesKeepTheirPathOriginRequestAndTheConfigurationAround() async throws {
        let log = Log()
        let existing = """
            {"success":true,"result":{"tunnel_id":"t","version":3,"config":{
              "originRequest":{"connectTimeout":10},
              "warp-routing":{"enabled":true},
              "ingress":[
                {"hostname":"imcp.example.com","path":"/api/*","service":"http://localhost:9",
                 "originRequest":{"noTLSVerify":true}},
                {"hostname":"imcp.example.com","service":"http://localhost:old"},
                {"hostname":"other.example.com","service":"http://localhost:5",
                 "originRequest":{"httpHostHeader":"x"}},
                {"service":"http_status:418"}
              ]}}}
            """
        let client = client(log: log, getBody: existing)
        try await client.configureTunnelIngress(
            accountID: "a",
            tunnelID: "t",
            hostname: "imcp.example.com",
            serviceURL: "http://localhost:1"
        )
        let config = try putConfig(log)
        XCTAssertEqual((config["originRequest"] as? [String: Int])?["connectTimeout"], 10)
        XCTAssertEqual((config["warp-routing"] as? [String: Bool])?["enabled"], true)

        let rules = try XCTUnwrap(config["ingress"] as? [[String: Any]])
        let summary = rules.map { rule in
            [
                rule["hostname"] as? String ?? "-",
                rule["path"] as? String ?? "-",
                rule["service"] as? String ?? "",
            ].joined(separator: "|")
        }
        XCTAssertEqual(
            summary,
            [
                "imcp.example.com|/api/*|http://localhost:9",
                "imcp.example.com|-|http://localhost:1",
                "other.example.com|-|http://localhost:5",
                "-|-|http_status:418",
            ]
        )
        XCTAssertEqual((rules[0]["originRequest"] as? [String: Bool])?["noTLSVerify"], true)
        XCTAssertEqual((rules[2]["originRequest"] as? [String: String])?["httpHostHeader"], "x")
    }

    func testANewTunnelWithANullConfigGetsTheRuleAndACatchAll() async throws {
        for body in [
            #"{"success":true,"result":{"tunnel_id":"t","config":null}}"#,
            #"{"success":true,"result":null}"#,
            #"{"success":true,"result":{"tunnel_id":"t"}}"#,
        ] {
            let log = Log()
            let client = client(log: log, getBody: body)
            try await client.configureTunnelIngress(
                accountID: "a",
                tunnelID: "t",
                hostname: "imcp.example.com",
                serviceURL: "http://localhost:1"
            )
            let rules = try XCTUnwrap(putConfig(log)["ingress"] as? [[String: Any]], body)
            XCTAssertEqual(rules.count, 2, body)
            XCTAssertEqual(rules[0]["hostname"] as? String, "imcp.example.com", body)
            XCTAssertEqual(rules[1]["service"] as? String, "http_status:404", body)
        }
    }
}

import Network
import XCTest

final class WindshieldDemoUITests: XCTestCase {
    private static let fixtureBody = #"{"message":"windshield-smoke-test"}"#

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCapturedRequestAppearsInInspectorWithResponseBody() throws {
        let fixture = try LocalHTTPFixtureServer(body: Self.fixtureBody)
        addTeardownBlock {
            fixture.stop()
        }

        let app = XCUIApplication()
        app.launchEnvironment["WINDSHIELD_DEMO_SAMPLE_URL"] = fixture.url.absoluteString
        app.launch()

        let sampleButton = app.buttons["Send sample GET"]
        XCTAssertTrue(sampleButton.waitForExistence(timeout: 5))
        sampleButton.tap()

        let expectedResult = "HTTP 200, \(Self.fixtureBody.utf8.count) bytes received."
        XCTAssertTrue(app.staticTexts[expectedResult].waitForExistence(timeout: 10))

        app.buttons["Open Windshield"].tap()
        XCTAssertTrue(app.navigationBars["Windshield"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Clear traffic"].waitForExistence(timeout: 5))

        let transaction = element(
            containingLabel: "GET 127.0.0.1/fixture, 200",
            in: app
        )
        XCTAssertTrue(transaction.waitForExistence(timeout: 5))
        transaction.tap()

        XCTAssertTrue(app.navigationBars["Request"].waitForExistence(timeout: 5))
        let performance = app.staticTexts["Performance"]
        for _ in 0 ..< 4 where !performance.exists {
            app.swipeUp()
        }
        XCTAssertTrue(performance.waitForExistence(timeout: 5))

        let responseKind = app.staticTexts["JSON"]
        for _ in 0 ..< 6 where !responseKind.exists {
            app.swipeUp()
        }
        XCTAssertTrue(responseKind.waitForExistence(timeout: 5))

        let responseBody = element(
            containingLabel: "windshield-smoke-test",
            in: app
        )
        for _ in 0 ..< 4 where !responseBody.exists {
            app.swipeUp()
        }
        XCTAssertTrue(responseBody.waitForExistence(timeout: 5))

        let bodySearch = app.textFields["Search response body"]
        XCTAssertTrue(bodySearch.waitForExistence(timeout: 5))
        bodySearch.tap()
        bodySearch.typeText("smoke")
        XCTAssertTrue(app.staticTexts["1 match"].waitForExistence(timeout: 5))
    }

    private func element(
        containingLabel text: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }
}

private final class LocalHTTPFixtureServer: @unchecked Sendable {
    private static let maximumRequestHeaderByteCount = 16 * 1024

    enum ServerError: Error {
        case didNotStart
        case missingPort
        case invalidURL
    }

    private final class RequestState: @unchecked Sendable {
        var data = Data()
    }

    private final class ConnectionRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        private var isStopped = false

        func track(_ connection: NWConnection) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard !isStopped else {
                return false
            }
            connections.append(connection)
            return true
        }

        func cancelAll() {
            lock.lock()
            isStopped = true
            let activeConnections = connections
            connections.removeAll()
            lock.unlock()

            activeConnections.forEach { $0.cancel() }
        }
    }

    let url: URL

    private let listener: NWListener
    private let connections: ConnectionRegistry

    init(body: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "dev.windshield.demo-ui-tests.fixture")
        let ready = DispatchSemaphore(value: 0)
        let bodyData = Data(body.utf8)
        let connections = ConnectionRegistry()

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { connection in
            guard connections.track(connection) else {
                connection.cancel()
                return
            }
            connection.start(queue: queue)
            Self.receiveRequest(
                on: connection,
                body: bodyData,
                state: RequestState()
            )
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw ServerError.didNotStart
        }
        guard case .ready = listener.state else {
            listener.cancel()
            throw ServerError.didNotStart
        }
        guard let port = listener.port else {
            listener.cancel()
            throw ServerError.missingPort
        }
        guard let url = URL(
            string: "http://127.0.0.1:\(port.rawValue)/fixture?source=ui-test"
        ) else {
            listener.cancel()
            throw ServerError.invalidURL
        }

        self.listener = listener
        self.connections = connections
        self.url = url
    }

    func stop() {
        listener.cancel()
        connections.cancelAll()
    }

    private static func receiveRequest(
        on connection: NWConnection,
        body: Data,
        state: RequestState
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { data, _, isComplete, error in
            if let data {
                state.data.append(data)
            }

            guard state.data.count <= maximumRequestHeaderByteCount else {
                connection.cancel()
                return
            }

            if state.data.range(of: Data("\r\n\r\n".utf8)) != nil {
                sendResponse(body: body, on: connection)
                return
            }

            guard !isComplete, error == nil else {
                connection.cancel()
                return
            }

            receiveRequest(on: connection, body: body, state: state)
        }
    }

    private static func sendResponse(body: Data, on connection: NWConnection) {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
            "X-Windshield-Fixture: smoke-test",
            "",
            "",
        ].joined(separator: "\r\n")

        var response = Data(headers.utf8)
        response.append(body)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }
}

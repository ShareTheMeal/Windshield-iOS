import Foundation
import Network
import XCTest

#if DEBUG
    @testable import Windshield

    final class WindshieldTransportTests: XCTestCase {
        func testProductionTransportReportsRedirectWithoutFollowingIt() throws {
            let server = try TransportLoopbackServer(
                routes: [
                    "/redirect": .redirect(location: "/final"),
                    "/final": .response(body: Data("followed".utf8)),
                ]
            )
            let port = try server.start()
            defer { server.stop() }

            let redirect = expectation(description: "The transport reports the redirect")
            let unexpectedCompletion = expectation(
                description: "The redirected transport task does not also complete"
            )
            unexpectedCompletion.isInverted = true
            let observer = TransportObserverSpy(
                redirectExpectation: redirect,
                completionExpectation: unexpectedCompletion
            )
            let task = WindshieldURLSessionTransport.shared.makeTask(
                for: request(port: port, path: "/redirect"),
                observer: observer
            )

            task.resume()

            wait(for: [redirect], timeout: 3)
            wait(for: [unexpectedCompletion], timeout: 0.2)
            XCTAssertEqual(observer.redirectResponse?.statusCode, 302)
            XCTAssertEqual(observer.redirectRequest?.url?.path, "/final")
            XCTAssertEqual(observer.eventNames, ["redirect"])
            XCTAssertEqual(server.requestTargets, ["/redirect"])
        }

        func testConfiguredInterceptorCompletesAMultiHopRedirect() async throws {
            let recorder = WindshieldTransactionRecorder.shared
            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()

            let responseBody = Data("finished".utf8)
            let server = try TransportLoopbackServer(
                routes: [
                    "/start": .redirect(location: "/middle"),
                    "/middle": .redirect(location: "/final"),
                    "/final": .response(body: responseBody),
                ]
            )
            let port = try server.start()
            defer { server.stop() }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WindshieldURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            let (receivedData, receivedResponse) = try await session.data(
                for: request(port: port, path: "/start")
            )
            XCTAssertEqual(receivedData, responseBody)
            XCTAssertEqual((receivedResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(server.requestTargets, ["/start", "/middle", "/final"])
            await recorder.flush()
            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()
        }

        func testProductionTransportReportsAConnectionFailure() throws {
            let server = try TransportLoopbackServer(
                routes: ["/failure": .closeConnection]
            )
            let port = try server.start()
            defer { server.stop() }

            let completion = expectation(description: "The transport reports the failure")
            let observer = TransportObserverSpy(completionExpectation: completion)
            let task = WindshieldURLSessionTransport.shared.makeTask(
                for: request(port: port, path: "/failure"),
                observer: observer
            )

            task.resume()

            wait(for: [completion], timeout: 3)
            XCTAssertNotNil(observer.completionError)
            XCTAssertEqual(observer.eventNames, ["complete"])
            XCTAssertFalse(server.requestTargets.isEmpty)
            XCTAssertTrue(server.requestTargets.allSatisfy { $0 == "/failure" })
        }

        func testCancellingProductionTransportSuppressesObserverCallbacks() throws {
            let server = try TransportLoopbackServer(
                routes: ["/held": .holdConnection]
            )
            let port = try server.start()
            defer { server.stop() }

            let unexpectedCallback = expectation(
                description: "No callback is delivered after cancellation"
            )
            unexpectedCallback.isInverted = true
            let observer = TransportObserverSpy(anyCallbackExpectation: unexpectedCallback)
            let task = WindshieldURLSessionTransport.shared.makeTask(
                for: request(port: port, path: "/held"),
                observer: observer
            )

            task.resume()
            XCTAssertTrue(server.waitForRequest(timeout: 2))
            task.cancel()

            wait(for: [unexpectedCallback], timeout: 0.5)
            XCTAssertTrue(observer.eventNames.isEmpty)
            XCTAssertEqual(server.requestTargets, ["/held"])
        }

        private func request(port: NWEndpoint.Port, path: String) -> URLRequest {
            URLRequest(
                url: URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")!
            )
        }
    }

    private final class TransportObserverSpy: WindshieldTransportObserver,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private let redirectExpectation: XCTestExpectation?
        private let completionExpectation: XCTestExpectation?
        private let anyCallbackExpectation: XCTestExpectation?
        private var events: [String] = []
        private var storedRedirectRequest: URLRequest?
        private var storedRedirectResponse: HTTPURLResponse?
        private var storedCompletionError: Error?

        init(
            redirectExpectation: XCTestExpectation? = nil,
            completionExpectation: XCTestExpectation? = nil,
            anyCallbackExpectation: XCTestExpectation? = nil
        ) {
            self.redirectExpectation = redirectExpectation
            self.completionExpectation = completionExpectation
            self.anyCallbackExpectation = anyCallbackExpectation
        }

        var eventNames: [String] {
            lock.withLock { events }
        }

        var redirectRequest: URLRequest? {
            lock.withLock { storedRedirectRequest }
        }

        var redirectResponse: HTTPURLResponse? {
            lock.withLock { storedRedirectResponse }
        }

        var completionError: Error? {
            lock.withLock { storedCompletionError }
        }

        func transportDidReceive(_: URLResponse) {
            record("response")
        }

        func transportDidReceive(_: Data) {
            record("data")
        }

        func transportDidComplete(with error: Error?) {
            lock.withLock {
                events.append("complete")
                storedCompletionError = error
            }
            anyCallbackExpectation?.fulfill()
            completionExpectation?.fulfill()
        }

        func transportDidRedirect(to request: URLRequest, response: HTTPURLResponse) {
            lock.withLock {
                events.append("redirect")
                storedRedirectRequest = request
                storedRedirectResponse = response
            }
            anyCallbackExpectation?.fulfill()
            redirectExpectation?.fulfill()
        }

        func transportDidReceive(
            _: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            record("challenge")
            completionHandler(.performDefaultHandling, nil)
        }

        private func record(_ event: String) {
            lock.withLock {
                events.append(event)
            }
            anyCallbackExpectation?.fulfill()
        }
    }

    private final class TransportLoopbackServer: @unchecked Sendable {
        enum Route {
            case response(body: Data)
            case redirect(location: String)
            case closeConnection
            case holdConnection
        }

        private enum ServerError: Error {
            case didNotStart
            case missingPort
        }

        private final class ConnectionState: @unchecked Sendable {
            var requestData = Data()
        }

        private let routes: [String: Route]
        private let listener: NWListener
        private let queue = DispatchQueue(label: "dev.windshield.tests.transport-loopback")
        private let lock = NSLock()
        private let requestSignal = DispatchSemaphore(value: 0)
        private var recordedRequestTargets: [String] = []
        private var connections: [NWConnection] = []

        init(routes: [String: Route]) throws {
            self.routes = routes
            listener = try NWListener(using: .tcp, on: .any)
        }

        var requestTargets: [String] {
            lock.withLock { recordedRequestTargets }
        }

        func start() throws -> NWEndpoint.Port {
            let startSignal = DispatchSemaphore(value: 0)
            let result = LockedTransportServerStartResult()

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port {
                        result.set(.success(port))
                    } else {
                        result.set(.failure(ServerError.missingPort))
                    }
                    startSignal.signal()

                case let .failed(error):
                    result.set(.failure(error))
                    startSignal.signal()

                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)

            guard startSignal.wait(timeout: .now() + 2) == .success else {
                throw ServerError.didNotStart
            }

            guard let startResult = result.get() else {
                throw ServerError.didNotStart
            }
            return try startResult.get()
        }

        func stop() {
            listener.cancel()
            let activeConnections = lock.withLock { connections }
            activeConnections.forEach { $0.cancel() }
        }

        func waitForRequest(timeout: TimeInterval) -> Bool {
            requestSignal.wait(timeout: .now() + timeout) == .success
        }

        private func handle(_ connection: NWConnection) {
            lock.withLock {
                connections.append(connection)
            }
            connection.start(queue: queue)
            receiveRequest(on: connection, state: ConnectionState())
        }

        private func receiveRequest(
            on connection: NWConnection,
            state: ConnectionState
        ) {
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 65536
            ) { [weak self] data, _, isComplete, error in
                guard let self else {
                    connection.cancel()
                    return
                }

                if let data {
                    state.requestData.append(data)
                    if Self.hasCompleteRequest(state.requestData) {
                        respond(on: connection, to: state.requestData)
                        return
                    }
                }

                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receiveRequest(on: connection, state: state)
                }
            }
        }

        private func respond(on connection: NWConnection, to requestData: Data) {
            let requestTarget = Self.requestTarget(from: requestData)
            lock.withLock {
                recordedRequestTargets.append(requestTarget)
            }
            requestSignal.signal()

            switch routes[requestTarget] ?? .response(body: Data()) {
            case let .response(body):
                send(
                    status: "200 OK",
                    headers: ["Content-Type: text/plain"],
                    body: body,
                    on: connection
                )

            case let .redirect(location):
                send(
                    status: "302 Found",
                    headers: ["Location: \(location)"],
                    body: Data(),
                    on: connection
                )

            case .closeConnection:
                connection.cancel()

            case .holdConnection:
                break
            }
        }

        private func send(
            status: String,
            headers: [String],
            body: Data,
            on connection: NWConnection
        ) {
            let responseHeaders = ([
                "HTTP/1.1 \(status)",
            ] + headers + [
                "Content-Length: \(body.count)",
                "Connection: close",
                "",
                "",
            ]).joined(separator: "\r\n")
            let response = Data(responseHeaders.utf8) + body

            connection.send(
                content: response,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in
                    connection.cancel()
                }
            )
        }

        private static func requestTarget(from data: Data) -> String {
            String(decoding: data, as: UTF8.self)
                .components(separatedBy: "\r\n")
                .first?
                .split(separator: " ")
                .dropFirst()
                .first
                .map(String.init) ?? ""
        }

        private static func hasCompleteRequest(_ data: Data) -> Bool {
            guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
                return false
            }

            let headers = String(
                decoding: data[..<headerRange.lowerBound],
                as: UTF8.self
            )
            let contentLength = headers
                .components(separatedBy: "\r\n")
                .first {
                    $0.lowercased().hasPrefix("content-length:")
                }
                .flatMap {
                    Int(
                        $0.split(separator: ":", maxSplits: 1)
                            .last?
                            .trimmingCharacters(in: .whitespaces) ?? ""
                    )
                } ?? 0
            let headerByteCount = data.distance(
                from: data.startIndex,
                to: headerRange.upperBound
            )
            return data.count >= headerByteCount + contentLength
        }
    }

    private final class LockedTransportServerStartResult: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<NWEndpoint.Port, Error>?

        func set(_ result: Result<NWEndpoint.Port, Error>) {
            lock.withLock {
                self.result = result
            }
        }

        func get() -> Result<NWEndpoint.Port, Error>? {
            lock.withLock { result }
        }
    }

    private extension NSLock {
        func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock()
            defer { unlock() }
            return try body()
        }
    }
#endif

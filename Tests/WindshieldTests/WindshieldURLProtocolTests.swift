import Foundation
import Network
import XCTest

#if DEBUG
    @testable import Windshield

    final class WindshieldURLProtocolTests: XCTestCase {
        func testCanInitAcceptsOnlyHTTPAndHTTPSRequests() {
            XCTAssertTrue(WindshieldURLProtocol.canInit(with: request(url: "http://example.com")))
            XCTAssertTrue(WindshieldURLProtocol.canInit(with: request(url: "https://example.com")))
            XCTAssertFalse(WindshieldURLProtocol.canInit(with: request(url: "file:///tmp/example")))
            XCTAssertFalse(WindshieldURLProtocol.canInit(with: request(url: "data:text/plain,hello")))
        }

        func testCanInitRejectsAnAlreadyHandledRequest() throws {
            let mutableRequest = try NSMutableURLRequest(url: XCTUnwrap(URL(string: "https://example.com")))
            URLProtocol.setProperty(
                true,
                forKey: WindshieldURLProtocol.handledRequestKey,
                in: mutableRequest
            )

            XCTAssertFalse(WindshieldURLProtocol.canInit(with: mutableRequest as URLRequest))
        }

        func testCanonicalRequestPreservesTheOriginalRequest() {
            var original = request(url: "https://example.com/items")
            original.httpMethod = "POST"
            original.setValue("application/json", forHTTPHeaderField: "Content-Type")

            XCTAssertEqual(WindshieldURLProtocol.canonicalRequest(for: original), original)
        }

        func testStartLoadingPassesAHandledCopyToTheTransportAndLogsRequestDetails() throws {
            var original = request(url: "https://example.com/items")
            original.httpMethod = "PATCH"
            original.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let context = makeContext(request: original)
            context.protocolInstance.startLoading()

            let transportedRequest = try XCTUnwrap(context.transport.request)
            XCTAssertEqual(transportedRequest.url, original.url)
            XCTAssertEqual(transportedRequest.httpMethod, "PATCH")
            XCTAssertEqual(
                transportedRequest.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )
            XCTAssertNotNil(
                URLProtocol.property(
                    forKey: WindshieldURLProtocol.handledRequestKey,
                    in: transportedRequest
                )
            )
            XCTAssertEqual(context.transport.task.resumeCallCount, 1)

            let log = try XCTUnwrap(context.logger.formattedEntries.first)
            XCTAssertTrue(log.contains("URL: https://example.com/items"))
            XCTAssertTrue(log.contains("Method: PATCH"))
            XCTAssertTrue(log.contains("Content-Type: application/json"))
        }

        func testResponseAndPayloadAreForwardedIncrementallyAndLoggedOnCompletion() throws {
            let context = makeContext(request: request(url: "https://example.com/items"))
            context.protocolInstance.startLoading()

            let response = try httpResponse(
                url: "https://example.com/items",
                statusCode: 201,
                headers: ["Content-Type": "application/json"]
            )
            let firstChunk = Data("{\"created\":".utf8)
            let secondChunk = Data("true}".utf8)

            context.transport.send(response)
            context.transport.send(firstChunk)

            XCTAssertEqual(context.client.eventNames, ["response", "data"])
            XCTAssertEqual(context.client.loadedData, firstChunk)
            XCTAssertEqual(context.logger.formattedEntries.count, 1)

            context.transport.send(secondChunk)
            context.transport.complete()

            XCTAssertEqual(context.client.eventNames, ["response", "data", "data", "finish"])
            XCTAssertEqual(context.client.loadedData, firstChunk + secondChunk)

            let responseLog = try XCTUnwrap(context.logger.formattedEntries.last)
            XCTAssertTrue(responseLog.contains("Status: 201"))
            XCTAssertTrue(responseLog.contains("Content-Type: application/json"))
            XCTAssertTrue(responseLog.contains("{\"created\":true}"))
        }

        func testTransportFailureIsForwardedAndLoggedExactlyOnce() throws {
            let context = makeContext(request: request(url: "https://example.com/items"))
            context.protocolInstance.startLoading()

            let error = URLError(.timedOut)
            context.transport.complete(with: error)
            context.transport.complete(with: error)

            XCTAssertEqual(context.client.eventNames, ["failure"])
            XCTAssertEqual((context.client.error as? URLError)?.code, .timedOut)
            XCTAssertEqual(context.logger.formattedEntries.count, 2)
            XCTAssertTrue(
                try XCTUnwrap(context.logger.formattedEntries.last)
                    .contains(error.localizedDescription)
            )
        }

        func testStopLoadingCancelsTransportAndIgnoresLateCallbacks() throws {
            let context = makeContext(request: request(url: "https://example.com/items"))
            context.protocolInstance.startLoading()
            context.protocolInstance.stopLoading()

            try context.transport.send(httpResponse(url: "https://example.com/items"))
            context.transport.send(Data("late".utf8))
            context.transport.complete(with: URLError(.cancelled))

            XCTAssertEqual(context.transport.task.cancelCallCount, 1)
            XCTAssertTrue(context.client.eventNames.isEmpty)
            XCTAssertEqual(context.logger.formattedEntries.count, 1)
        }

        func testStopLoadingWaitsForAnInFlightClientCallbackAndBlocksLaterDelivery() {
            let context = makeContext(request: request(url: "https://example.com/items"))
            context.protocolInstance.startLoading()

            let callbackStarted = expectation(description: "The client callback starts")
            let releaseCallback = DispatchSemaphore(value: 0)
            let deliveryFinished = DispatchSemaphore(value: 0)
            context.client.dataHandler = { _ in
                callbackStarted.fulfill()
                releaseCallback.wait()
            }

            DispatchQueue.global().async {
                context.transport.send(Data("first".utf8))
                deliveryFinished.signal()
            }
            wait(for: [callbackStarted], timeout: 1)

            let stopStarted = DispatchSemaphore(value: 0)
            let stopFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                stopStarted.signal()
                context.protocolInstance.stopLoading()
                stopFinished.signal()
            }

            XCTAssertEqual(stopStarted.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(stopFinished.wait(timeout: .now() + 0.05), .timedOut)

            releaseCallback.signal()
            XCTAssertEqual(deliveryFinished.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(stopFinished.wait(timeout: .now() + 1), .success)

            context.transport.send(Data("late".utf8))
            XCTAssertEqual(context.client.loadedData, Data("first".utf8))
            XCTAssertEqual(context.client.eventNames, ["data"])
        }

        func testRedirectIsForwardedWithoutTheHandledMarker() throws {
            let context = makeContext(request: request(url: "https://example.com/old"))
            context.protocolInstance.startLoading()

            let redirectResponse = try httpResponse(
                url: "https://example.com/old",
                statusCode: 302,
                headers: ["Location": "https://example.com/new"]
            )

            let mutableRedirect = try NSMutableURLRequest(
                url: XCTUnwrap(URL(string: "https://example.com/new"))
            )
            URLProtocol.setProperty(
                true,
                forKey: WindshieldURLProtocol.handledRequestKey,
                in: mutableRedirect
            )

            context.transport.redirect(
                to: mutableRedirect as URLRequest,
                response: redirectResponse
            )

            let redirectedRequest = try XCTUnwrap(context.client.redirectedRequest)
            XCTAssertEqual(redirectedRequest.url?.absoluteString, "https://example.com/new")
            XCTAssertNil(
                URLProtocol.property(
                    forKey: WindshieldURLProtocol.handledRequestKey,
                    in: redirectedRequest
                )
            )
            XCTAssertEqual(context.client.eventNames, ["redirect"])
            XCTAssertTrue(try XCTUnwrap(context.logger.formattedEntries.last).contains("Status: 302"))
        }

        func testCaptureLimitDoesNotLimitThePayloadForwardedToTheClient() throws {
            let context = makeContext(request: request(url: "https://example.com/large"))
            context.protocolInstance.startLoading()
            try context.transport.send(httpResponse(url: "https://example.com/large"))

            let payload = Data(
                repeating: 65,
                count: WindshieldURLProtocol.maximumCapturedResponseBodySize + 128
            )
            context.transport.send(payload)
            context.transport.complete()

            XCTAssertEqual(context.client.loadedData, payload)

            let responseLog = try XCTUnwrap(context.logger.formattedEntries.last)
            XCTAssertTrue(
                responseLog.contains(
                    "Captured \(WindshieldURLProtocol.maximumCapturedResponseBodySize) "
                        + "of \(payload.count) bytes"
                )
            )
            XCTAssertTrue(responseLog.contains("[truncated]"))
        }

        func testAuthenticationChallengeDecisionIsForwardedToTheTransport() {
            let context = makeContext(request: request(url: "https://example.com/private"))
            context.protocolInstance.startLoading()

            let credential = URLCredential(
                user: "developer",
                password: "secret",
                persistence: .none
            )
            context.client.authenticationChallengeHandler = { challenge in
                challenge.sender?.use(credential, for: challenge)
            }

            var receivedDisposition: URLSession.AuthChallengeDisposition?
            var receivedCredential: URLCredential?
            context.transport.send(authenticationChallenge()) { disposition, credential in
                receivedDisposition = disposition
                receivedCredential = credential
            }

            XCTAssertEqual(context.client.eventNames, ["challenge"])
            XCTAssertEqual(receivedDisposition, .useCredential)
            XCTAssertEqual(receivedCredential?.user, "developer")
            XCTAssertEqual(receivedCredential?.password, "secret")
        }

        func testStopLoadingCancelsAPendingAuthenticationChallenge() {
            let context = makeContext(request: request(url: "https://example.com/private"))
            context.protocolInstance.startLoading()

            var receivedDisposition: URLSession.AuthChallengeDisposition?
            context.transport.send(authenticationChallenge()) { disposition, _ in
                receivedDisposition = disposition
            }

            context.protocolInstance.stopLoading()

            XCTAssertEqual(receivedDisposition, .cancelAuthenticationChallenge)
            XCTAssertEqual(context.transport.task.cancelCallCount, 1)
        }

        func testConfiguredSessionInterceptsARequestUsingTheProductionTransport() throws {
            let responseBody = Data("{\"source\":\"windshield\"}".utf8)
            let server = try LoopbackHTTPServer(responseBody: responseBody)
            let port = try server.start()
            defer { server.stop() }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WindshieldURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            let completion = expectation(description: "The intercepted request completes")
            var outgoingRequest = request(
                url: "http://127.0.0.1:\(port.rawValue)/milestone-one"
            )
            outgoingRequest.setValue("core", forHTTPHeaderField: "X-Windshield-Test")

            session.dataTask(with: outgoingRequest) { data, response, error in
                XCTAssertNil(error)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertEqual(data, responseBody)
                completion.fulfill()
            }.resume()

            wait(for: [completion], timeout: 5)
            XCTAssertTrue(server.receivedRequest.contains("/milestone-one"))
            XCTAssertTrue(server.receivedRequest.contains("core"))
        }

        private func makeContext(request: URLRequest) -> TestContext {
            let client = URLProtocolClientSpy()
            let transport = WindshieldTransportSpy()
            let logger = WindshieldLoggerSpy()
            let protocolInstance = WindshieldURLProtocol(
                request: request,
                cachedResponse: nil,
                client: client
            )
            protocolInstance.transport = transport
            protocolInstance.logger = logger

            return TestContext(
                protocolInstance: protocolInstance,
                client: client,
                transport: transport,
                logger: logger
            )
        }

        private func request(url: String) -> URLRequest {
            URLRequest(url: URL(string: url)!)
        }

        private func httpResponse(
            url: String,
            statusCode: Int = 200,
            headers: [String: String] = [:]
        ) throws -> HTTPURLResponse {
            try XCTUnwrap(
                HTTPURLResponse(
                    url: XCTUnwrap(URL(string: url)),
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )
            )
        }

        private func authenticationChallenge() -> URLAuthenticationChallenge {
            let protectionSpace = URLProtectionSpace(
                host: "example.com",
                port: 443,
                protocol: "https",
                realm: "Windshield Tests",
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            )

            return URLAuthenticationChallenge(
                protectionSpace: protectionSpace,
                proposedCredential: nil,
                previousFailureCount: 0,
                failureResponse: nil,
                error: nil,
                sender: AuthenticationChallengeSenderStub()
            )
        }
    }

    private struct TestContext: @unchecked Sendable {
        let protocolInstance: WindshieldURLProtocol
        let client: URLProtocolClientSpy
        let transport: WindshieldTransportSpy
        let logger: WindshieldLoggerSpy
    }

    private final class WindshieldTransportSpy: WindshieldTransporting {
        let task = WindshieldTransportTaskSpy()
        private(set) var request: URLRequest?
        private weak var observer: WindshieldTransportObserver?

        func makeTask(
            for request: URLRequest,
            observer: WindshieldTransportObserver
        ) -> WindshieldTransportTask {
            self.request = request
            self.observer = observer
            return task
        }

        func send(_ response: URLResponse) {
            observer?.transportDidReceive(response)
        }

        func send(_ data: Data) {
            observer?.transportDidReceive(data)
        }

        func complete(with error: Error? = nil) {
            observer?.transportDidComplete(with: error)
        }

        func redirect(to request: URLRequest, response: HTTPURLResponse) {
            observer?.transportDidRedirect(to: request, response: response)
        }

        func send(
            _ challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            observer?.transportDidReceive(challenge, completionHandler: completionHandler)
        }
    }

    private final class WindshieldTransportTaskSpy: WindshieldTransportTask {
        private(set) var resumeCallCount = 0
        private(set) var cancelCallCount = 0

        func resume() {
            resumeCallCount += 1
        }

        func cancel() {
            cancelCallCount += 1
        }
    }

    private final class WindshieldLoggerSpy: WindshieldLogging {
        private(set) var entries: [WindshieldLogEntry] = []

        var formattedEntries: [String] {
            entries.map(WindshieldLogFormatter.format)
        }

        func log(_ entry: WindshieldLogEntry) {
            entries.append(entry)
        }
    }

    private final class URLProtocolClientSpy: NSObject, URLProtocolClient, @unchecked Sendable {
        private(set) var eventNames: [String] = []
        private(set) var loadedData = Data()
        private(set) var error: Error?
        private(set) var redirectedRequest: URLRequest?
        var authenticationChallengeHandler: ((URLAuthenticationChallenge) -> Void)?
        var dataHandler: ((Data) -> Void)?

        func urlProtocol(
            _: URLProtocol,
            wasRedirectedTo request: URLRequest,
            redirectResponse _: URLResponse
        ) {
            eventNames.append("redirect")
            redirectedRequest = request
        }

        func urlProtocol(
            _: URLProtocol,
            cachedResponseIsValid _: CachedURLResponse
        ) {}

        func urlProtocol(
            _: URLProtocol,
            didReceive _: URLResponse,
            cacheStoragePolicy _: URLCache.StoragePolicy
        ) {
            eventNames.append("response")
        }

        func urlProtocol(_: URLProtocol, didLoad data: Data) {
            eventNames.append("data")
            loadedData.append(data)
            dataHandler?(data)
        }

        func urlProtocolDidFinishLoading(_: URLProtocol) {
            eventNames.append("finish")
        }

        func urlProtocol(_: URLProtocol, didFailWithError error: Error) {
            eventNames.append("failure")
            self.error = error
        }

        func urlProtocol(
            _: URLProtocol,
            didReceive challenge: URLAuthenticationChallenge
        ) {
            eventNames.append("challenge")
            authenticationChallengeHandler?(challenge)
        }

        func urlProtocol(
            _: URLProtocol,
            didCancel _: URLAuthenticationChallenge
        ) {}
    }

    private final class AuthenticationChallengeSenderStub: NSObject,
        URLAuthenticationChallengeSender
    {
        func use(_: URLCredential, for _: URLAuthenticationChallenge) {}

        func continueWithoutCredential(for _: URLAuthenticationChallenge) {}

        func cancel(_: URLAuthenticationChallenge) {}
    }

    private final class LoopbackHTTPServer: @unchecked Sendable {
        private enum ServerError: Error {
            case didNotStart
            case missingPort
        }

        private let responseBody: Data
        private let listener: NWListener
        private let queue = DispatchQueue(label: "dev.windshield.tests.loopback-server")
        private let requestLock = NSLock()
        private var requestData = Data()

        var receivedRequest: String {
            requestLock.lock()
            let data = requestData
            requestLock.unlock()
            return String(decoding: data, as: UTF8.self)
        }

        init(responseBody: Data) throws {
            self.responseBody = responseBody
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() throws -> NWEndpoint.Port {
            let startSignal = DispatchSemaphore(value: 0)
            let startResult = LockedServerStartResult()

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port {
                        startResult.set(.success(port))
                    } else {
                        startResult.set(.failure(ServerError.missingPort))
                    }
                    startSignal.signal()

                case let .failed(error):
                    startResult.set(.failure(error))
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

            return try startResult.get()?.get() ?? { throw ServerError.didNotStart }()
        }

        func stop() {
            listener.cancel()
        }

        private func handle(_ connection: NWConnection) {
            connection.start(queue: queue)
            receiveRequest(on: connection)
        }

        private func receiveRequest(on connection: NWConnection) {
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 65536
            ) { [weak self] data, _, isComplete, error in
                guard let self else {
                    connection.cancel()
                    return
                }

                if let data {
                    requestLock.lock()
                    requestData.append(data)
                    let hasCompleteHeaders = requestData.range(of: Data("\r\n\r\n".utf8)) != nil
                    requestLock.unlock()

                    if hasCompleteHeaders {
                        sendResponse(on: connection)
                        return
                    }
                }

                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receiveRequest(on: connection)
                }
            }
        }

        private func sendResponse(on connection: NWConnection) {
            let headers = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(responseBody.count)\r
            Connection: close\r
            \r

            """
            let response = Data(headers.utf8) + responseBody

            connection.send(
                content: response,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in
                    connection.cancel()
                }
            )
        }
    }

    private final class LockedServerStartResult: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<NWEndpoint.Port, Error>?

        func set(_ result: Result<NWEndpoint.Port, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        func get() -> Result<NWEndpoint.Port, Error>? {
            lock.lock()
            let result = result
            lock.unlock()
            return result
        }
    }
#endif

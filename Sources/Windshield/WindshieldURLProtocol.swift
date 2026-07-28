import Foundation

#if DEBUG
    /// Intercepts HTTP and HTTPS requests made by URL sessions whose configuration
    /// includes this class in `protocolClasses`.
    ///
    /// Windshield is intended for development builds only. Custom protocols are not
    /// supported by background sessions. The protocol also cannot read every option
    /// from the originating URL session configuration, so apps with custom proxy,
    /// cookie, or connection-level trust behavior should validate their integration.
    /// Foundation may move a URLProtocol instance across queues. All request lifecycle
    /// state is isolated by `lifecycle`. The injectable dependencies are set only by
    /// tests, before loading begins.
    final class WindshieldURLProtocol: URLProtocol, @unchecked Sendable {
        static let handledRequestKey = "dev.windshield.request-handled"
        static let maximumCapturedRequestBodySize = 1_048_576
        static let maximumCapturedResponseBodySize = 1_048_576

        private let transactionID = UUID()
        private let lifecycle = WindshieldLifecycleExecutor()

        private enum LifecycleState {
            case initialized
            case loading
            case terminated
        }

        private var state = LifecycleState.initialized
        private var capturedResponseBody = Data()
        private var receivedResponseBodyByteCount = 0
        private var transportTask: WindshieldTransportTask?
        private var authenticationChallengeSender: WindshieldAuthenticationChallengeSender?

        var transport: WindshieldTransporting = WindshieldURLSessionTransport.shared
        var recorder: WindshieldRecording = WindshieldTransactionRecorder.shared

        override class func canInit(with request: URLRequest) -> Bool {
            guard URLProtocol.property(forKey: handledRequestKey, in: request) == nil else {
                return false
            }

            guard let scheme = request.url?.scheme?.lowercased() else {
                return false
            }

            return scheme == "http" || scheme == "https"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            lifecycle.sync {
                guard state == .initialized else {
                    return
                }
                state = .loading

                recorder.record(
                    .started(
                        id: transactionID,
                        request: WindshieldRequestSnapshot(
                            request: request,
                            maximumBodyByteCount: Self.maximumCapturedRequestBodySize
                        ),
                        at: Date()
                    )
                )
                guard state == .loading else {
                    return
                }

                guard let handledRequest = Self.markedAsHandled(request) else {
                    completeBeforeTransportStarts(with: URLError(.badURL))
                    return
                }

                let task = transport.makeTask(for: handledRequest, observer: self)
                guard state == .loading else {
                    task.cancel()
                    return
                }

                transportTask = task
                task.resume()
            }
        }

        override func stopLoading() {
            let cancellation = lifecycle.sync { () -> Cancellation in
                guard state != .terminated else {
                    return Cancellation(
                        task: nil,
                        challengeSender: nil,
                        event: nil
                    )
                }

                let shouldRecordCancellation = state == .loading
                state = .terminated

                let cancellation = Cancellation(
                    task: transportTask,
                    challengeSender: authenticationChallengeSender,
                    event: shouldRecordCancellation
                        ? .cancelled(
                            id: transactionID,
                            body: capturedBodySnapshot(),
                            at: Date()
                        )
                        : nil
                )
                transportTask = nil
                authenticationChallengeSender = nil
                capturedResponseBody.removeAll(keepingCapacity: false)

                return cancellation
            }

            if let event = cancellation.event {
                recorder.record(event)
            }
            cancellation.challengeSender?.cancel()
            cancellation.task?.cancel()
        }

        deinit {
            let task = lifecycle.sync { transportTask }
            task?.cancel()
        }

        private struct Cancellation {
            let task: WindshieldTransportTask?
            let challengeSender: WindshieldAuthenticationChallengeSender?
            let event: WindshieldTransactionEvent?
        }

        private static func markedAsHandled(_ request: URLRequest) -> URLRequest? {
            guard let mutableRequest = (request as NSURLRequest).mutableCopy()
                as? NSMutableURLRequest
            else {
                return nil
            }

            URLProtocol.setProperty(true, forKey: handledRequestKey, in: mutableRequest)
            return mutableRequest as URLRequest
        }

        private static func removingHandledMarker(from request: URLRequest) -> URLRequest {
            guard let mutableRequest = (request as NSURLRequest).mutableCopy()
                as? NSMutableURLRequest
            else {
                return request
            }

            URLProtocol.removeProperty(forKey: handledRequestKey, in: mutableRequest)
            return mutableRequest as URLRequest
        }

        private func completeBeforeTransportStarts(with error: Error) {
            guard let termination = transitionToTerminated() else {
                return
            }

            termination.challengeSender?.cancel()

            recorder.record(
                .failed(
                    id: transactionID,
                    body: capturedBodySnapshot(),
                    failure: WindshieldFailure(error: error),
                    at: Date()
                )
            )
            client?.urlProtocol(self, didFailWithError: error)
        }

        private struct Termination {
            let challengeSender: WindshieldAuthenticationChallengeSender?
        }

        private func transitionToTerminated() -> Termination? {
            guard state == .loading else {
                return nil
            }

            state = .terminated
            let challengeSender = authenticationChallengeSender
            transportTask = nil
            authenticationChallengeSender = nil
            return Termination(challengeSender: challengeSender)
        }

        private func capturedBodySnapshot() -> WindshieldBodyCapture {
            .capture(
                capturedResponseBody,
                totalByteCount: receivedResponseBodyByteCount,
                maximumByteCount: Self.maximumCapturedResponseBodySize
            )
        }
    }

    extension WindshieldURLProtocol: WindshieldTransportObserver {
        func transportDidReceive(_ response: URLResponse) {
            lifecycle.sync {
                guard state == .loading else {
                    return
                }

                if let response = response as? HTTPURLResponse {
                    recorder.record(
                        .receivedResponse(
                            id: transactionID,
                            response: WindshieldResponseSnapshot(response: response)
                        )
                    )
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            }
        }

        func transportDidReceive(_ data: Data) {
            lifecycle.sync {
                guard state == .loading else {
                    return
                }

                receivedResponseBodyByteCount += data.count

                let remainingCapacity = max(
                    0,
                    Self.maximumCapturedResponseBodySize - capturedResponseBody.count
                )
                if remainingCapacity > 0 {
                    capturedResponseBody.append(contentsOf: data.prefix(remainingCapacity))
                }

                client?.urlProtocol(self, didLoad: data)
            }
        }

        func transportDidComplete(with error: Error?) {
            lifecycle.sync {
                guard let termination = transitionToTerminated() else {
                    return
                }

                termination.challengeSender?.cancel()

                if let error {
                    recorder.record(
                        .failed(
                            id: transactionID,
                            body: capturedBodySnapshot(),
                            failure: WindshieldFailure(error: error),
                            at: Date()
                        )
                    )
                    client?.urlProtocol(self, didFailWithError: error)
                } else {
                    recorder.record(
                        .completed(
                            id: transactionID,
                            body: capturedBodySnapshot(),
                            at: Date()
                        )
                    )
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
        }

        func transportDidRedirect(to request: URLRequest, response: HTTPURLResponse) {
            lifecycle.sync {
                guard let termination = transitionToTerminated() else {
                    return
                }

                termination.challengeSender?.cancel()

                recorder.record(
                    .redirected(
                        id: transactionID,
                        response: WindshieldResponseSnapshot(response: response),
                        body: capturedBodySnapshot(),
                        destination: request.url,
                        at: Date()
                    )
                )

                let redirectRequest = Self.removingHandledMarker(from: request)
                client?.urlProtocol(
                    self,
                    wasRedirectedTo: redirectRequest,
                    redirectResponse: response
                )
            }
        }

        func transportDidReceive(
            _ challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            lifecycle.sync {
                guard state == .loading else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }

                let sender = WindshieldAuthenticationChallengeSender(
                    completionHandler: completionHandler
                )
                authenticationChallengeSender = sender

                guard let client else {
                    sender.performDefaultHandling()
                    return
                }

                let forwardedChallenge = URLAuthenticationChallenge(
                    authenticationChallenge: challenge,
                    sender: sender
                )
                client.urlProtocol(self, didReceive: forwardedChallenge)
            }
        }
    }

    /// The serial queue owns all operations. The queue-specific key keeps callbacks
    /// reentrant without allowing concurrent access to protocol state.
    private final class WindshieldLifecycleExecutor: @unchecked Sendable {
        private static let queueKey = DispatchSpecificKey<UUID>()

        private let identifier: UUID
        private let queue: DispatchQueue

        init() {
            let identifier = UUID()
            let queue = DispatchQueue(
                label: "dev.windshield.request-lifecycle.\(identifier.uuidString)",
                qos: .utility
            )

            self.identifier = identifier
            self.queue = queue
            queue.setSpecific(key: Self.queueKey, value: identifier)
        }

        func sync<T>(_ operation: () throws -> T) rethrows -> T {
            if DispatchQueue.getSpecific(key: Self.queueKey) == identifier {
                return try operation()
            }

            return try queue.sync(execute: operation)
        }
    }

    /// The lock protects the one-shot completion handler across client and transport
    /// callback queues.
    private final class WindshieldAuthenticationChallengeSender: NSObject,
        URLAuthenticationChallengeSender,
        @unchecked Sendable
    {
        typealias CompletionHandler = (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void

        private let lock = NSLock()
        private var completionHandler: CompletionHandler?

        init(completionHandler: @escaping CompletionHandler) {
            self.completionHandler = completionHandler
        }

        func use(_ credential: URLCredential, for _: URLAuthenticationChallenge) {
            resolve(with: .useCredential, credential: credential)
        }

        func continueWithoutCredential(for _: URLAuthenticationChallenge) {
            resolve(with: .useCredential, credential: nil)
        }

        func cancel(_: URLAuthenticationChallenge) {
            cancel()
        }

        func performDefaultHandling(for _: URLAuthenticationChallenge) {
            performDefaultHandling()
        }

        func rejectProtectionSpaceAndContinue(with _: URLAuthenticationChallenge) {
            resolve(with: .rejectProtectionSpace, credential: nil)
        }

        func cancel() {
            resolve(with: .cancelAuthenticationChallenge, credential: nil)
        }

        func performDefaultHandling() {
            resolve(with: .performDefaultHandling, credential: nil)
        }

        private func resolve(
            with disposition: URLSession.AuthChallengeDisposition,
            credential: URLCredential?
        ) {
            lock.lock()
            let completionHandler = completionHandler
            self.completionHandler = nil
            lock.unlock()

            completionHandler?(disposition, credential)
        }
    }
#endif

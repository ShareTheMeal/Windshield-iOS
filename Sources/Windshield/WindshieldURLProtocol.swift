import Foundation

#if DEBUG
    /// Intercepts HTTP and HTTPS requests made by URL sessions whose configuration
    /// includes this class in `protocolClasses`.
    ///
    /// Windshield is intended for development builds only. Custom protocols are not
    /// supported by background sessions. The protocol also cannot read every option
    /// from the originating URL session configuration, so apps with custom proxy,
    /// cookie, authentication delegate, or connection-level trust behavior should
    /// validate their integration.
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
        private var capturePlan: WindshieldCapturePlan?

        var transport: WindshieldTransporting = WindshieldURLSessionTransport.shared
        var recorder: WindshieldRecording = WindshieldTransactionRecorder.shared
        var capturePolicyProvider: WindshieldCapturePolicyProviding =
            WindshieldCapturePolicyStore.shared

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
                let capturePlan = capturePolicyProvider.capturePlan(for: request)
                self.capturePlan = capturePlan

                recordIfEnabled(
                    .started(
                        id: transactionID,
                        request: WindshieldRequestSnapshot(
                            request: request,
                            maximumBodyByteCount: Self.maximumCapturedRequestBodySize,
                            bodyCapture: capturePlan.bodyCapture,
                            redactedHeaderNames: capturePlan.redactedHeaderNames
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
                        event: nil
                    )
                }

                let shouldRecordCancellation = state == .loading
                    && capturePlan?.recordsTransaction == true
                state = .terminated

                let cancellation = Cancellation(
                    task: transportTask,
                    event: shouldRecordCancellation
                        ? .cancelled(
                            id: transactionID,
                            body: capturedBodySnapshot(),
                            at: Date()
                        )
                        : nil
                )
                transportTask = nil
                capturedResponseBody.removeAll(keepingCapacity: false)

                return cancellation
            }

            if let event = cancellation.event {
                recorder.record(event)
            }
            cancellation.task?.cancel()
        }

        deinit {
            let task = lifecycle.sync { transportTask }
            task?.cancel()
        }

        private struct Cancellation {
            let task: WindshieldTransportTask?
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
            guard transitionToTerminated() else {
                return
            }

            recordIfEnabled(
                .failed(
                    id: transactionID,
                    body: capturedBodySnapshot(),
                    failure: WindshieldFailure(error: error),
                    at: Date()
                )
            )
            client?.urlProtocol(self, didFailWithError: error)
        }

        private func transitionToTerminated() -> Bool {
            guard state == .loading else {
                return false
            }

            state = .terminated
            transportTask = nil
            return true
        }

        private func capturedBodySnapshot() -> WindshieldBodyCapture {
            if capturePlan?.bodyCapture == .metadataOnly {
                return .unavailable(
                    .excludedByCapturePolicy,
                    totalByteCount: receivedResponseBodyByteCount
                )
            }

            return .capture(
                capturedResponseBody,
                totalByteCount: receivedResponseBodyByteCount,
                maximumByteCount: Self.maximumCapturedResponseBodySize
            )
        }

        private func recordIfEnabled(
            _ event: @autoclosure () -> WindshieldTransactionEvent
        ) {
            guard capturePlan?.recordsTransaction == true else {
                return
            }

            recorder.record(event())
        }
    }

    extension WindshieldURLProtocol: WindshieldTransportObserver {
        func transportDidReceive(_ response: URLResponse) {
            lifecycle.sync {
                guard state == .loading else {
                    return
                }

                if let response = response as? HTTPURLResponse {
                    recordIfEnabled(
                        .receivedResponse(
                            id: transactionID,
                            response: WindshieldResponseSnapshot(
                                response: response,
                                redactedHeaderNames: capturePlan?.redactedHeaderNames ?? []
                            )
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

                if capturePlan?.recordsTransaction == true {
                    receivedResponseBodyByteCount += data.count

                    if capturePlan?.bodyCapture == .full {
                        let remainingCapacity = max(
                            0,
                            Self.maximumCapturedResponseBodySize - capturedResponseBody.count
                        )
                        if remainingCapacity > 0 {
                            capturedResponseBody.append(contentsOf: data.prefix(remainingCapacity))
                        }
                    }
                }

                client?.urlProtocol(self, didLoad: data)
            }
        }

        func transportDidComplete(with error: Error?) {
            lifecycle.sync {
                guard transitionToTerminated() else {
                    return
                }

                if let error {
                    recordIfEnabled(
                        .failed(
                            id: transactionID,
                            body: capturedBodySnapshot(),
                            failure: WindshieldFailure(error: error),
                            at: Date()
                        )
                    )
                    client?.urlProtocol(self, didFailWithError: error)
                } else {
                    recordIfEnabled(
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
                guard transitionToTerminated() else {
                    return
                }

                recordIfEnabled(
                    .redirected(
                        id: transactionID,
                        response: WindshieldResponseSnapshot(
                            response: response,
                            redactedHeaderNames: capturePlan?.redactedHeaderNames ?? []
                        ),
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
#endif

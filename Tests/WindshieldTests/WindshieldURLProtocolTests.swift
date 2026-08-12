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

        func testStartLoadingPassesAHandledCopyToTheTransportAndRecordsRequestDetails() throws {
            var original = request(url: "https://example.com/items")
            original.httpMethod = "PATCH"
            original.setValue("application/json", forHTTPHeaderField: "Content-Type")
            original.httpBody = Data("{\"name\":\"Windshield\"}".utf8)

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

            guard case let .started(_, request, _) = try XCTUnwrap(context.recorder.events.first) else {
                return XCTFail("Expected a started transaction event")
            }
            XCTAssertEqual(request.url, original.url)
            XCTAssertEqual(request.method, "PATCH")
            XCTAssertEqual(
                request.body.contents,
                .bytes(Data("{\"name\":\"Windshield\"}".utf8))
            )
            XCTAssertTrue(
                request.headers.contains(
                    WindshieldHeader(name: "Content-Type", value: "application/json")
                )
            )
        }

        func testSensitiveAndCustomHeadersAreRedactedOnlyInRecordedSnapshots() throws {
            var original = request(url: "https://api.example.com/private")
            original.setValue("Bearer request-secret", forHTTPHeaderField: "Authorization")
            original.setValue("custom-secret", forHTTPHeaderField: "X-API-Key")
            original.setValue("visible", forHTTPHeaderField: "X-Public")
            let context = makeContext(
                request: original,
                options: Windshield.Options(
                    additionalRedactedHeaderNames: ["x-api-key"]
                )
            )

            context.protocolInstance.startLoading()
            let response = try httpResponse(
                url: "https://api.example.com/private",
                headers: [
                    "Set-Cookie": "session=response-secret",
                    "X-API-Key": "response-secret",
                    "X-Public": "visible",
                ]
            )
            context.transport.send(response)
            context.transport.complete()

            guard case let .started(_, requestSnapshot, _) = try XCTUnwrap(
                context.recorder.events.first
            ) else {
                return XCTFail("Expected a started transaction event")
            }
            guard case let .receivedResponse(_, responseSnapshot) = context.recorder.events[1] else {
                return XCTFail("Expected a response transaction event")
            }

            XCTAssertEqual(
                headerValue("Authorization", in: requestSnapshot.headers),
                WindshieldHeader.redactedValue
            )
            XCTAssertEqual(
                headerValue("X-API-Key", in: requestSnapshot.headers),
                WindshieldHeader.redactedValue
            )
            XCTAssertEqual(headerValue("X-Public", in: requestSnapshot.headers), "visible")
            XCTAssertEqual(
                headerValue("Set-Cookie", in: responseSnapshot.headers),
                WindshieldHeader.redactedValue
            )
            XCTAssertEqual(
                headerValue("X-API-Key", in: responseSnapshot.headers),
                WindshieldHeader.redactedValue
            )
            XCTAssertEqual(headerValue("X-Public", in: responseSnapshot.headers), "visible")

            XCTAssertEqual(
                context.transport.request?.value(forHTTPHeaderField: "Authorization"),
                "Bearer request-secret"
            )
            XCTAssertEqual(
                context.transport.request?.value(forHTTPHeaderField: "X-API-Key"),
                "custom-secret"
            )
            XCTAssertTrue(context.client.receivedResponse === response)
            XCTAssertEqual(
                response.value(forHTTPHeaderField: "Set-Cookie"),
                "session=response-secret"
            )
            XCTAssertEqual(context.client.eventNames, ["response", "finish"])
        }

        func testIgnoredRequestUsesTheNormalTransportWithoutRecordingAnything() throws {
            var original = request(url: "https://api.example.com/private/items")
            original.httpMethod = "POST"
            original.httpBody = Data("sensitive request".utf8)
            original.setValue("Bearer network-value", forHTTPHeaderField: "Authorization")
            let context = makeContext(
                request: original,
                options: Windshield.Options(
                    ignoredURLRules: [
                        .init(
                            host: "api.example.com",
                            pathPrefix: "/private",
                            httpMethods: ["POST"]
                        ),
                    ]
                )
            )

            context.protocolInstance.startLoading()
            let response = try httpResponse(url: "https://api.example.com/private/items")
            let payload = Data("sensitive response".utf8)
            context.transport.send(response)
            context.transport.send(payload)
            context.transport.complete()

            XCTAssertTrue(context.recorder.events.isEmpty)
            XCTAssertEqual(context.transport.makeTaskCallCount, 1)
            XCTAssertEqual(context.transport.task.resumeCallCount, 1)
            XCTAssertEqual(context.transport.request?.httpMethod, original.httpMethod)
            XCTAssertEqual(context.transport.request?.httpBody, original.httpBody)
            XCTAssertEqual(
                context.transport.request?.value(forHTTPHeaderField: "Authorization"),
                "Bearer network-value"
            )
            XCTAssertTrue(context.client.receivedResponse === response)
            XCTAssertEqual(context.client.loadedData, payload)
            XCTAssertEqual(context.client.eventNames, ["response", "data", "finish"])
        }

        func testMetadataOnlyPlanIsStableAndForwardsEveryPayloadByte() throws {
            var original = request(url: "https://api.example.com/payments/confirm")
            original.httpMethod = "POST"
            let requestPayload = Data("sensitive request".utf8)
            original.httpBody = requestPayload
            let context = makeContext(
                request: original,
                options: Windshield.Options(
                    metadataOnlyURLRules: [
                        .init(
                            host: "api.example.com",
                            pathPrefix: "/payments",
                            httpMethods: ["POST"]
                        ),
                    ]
                )
            )

            context.protocolInstance.startLoading()
            context.policyStore.configure(options: Windshield.Options())

            let response = try httpResponse(
                url: "https://api.example.com/payments/confirm",
                headers: ["Set-Cookie": "session=response-secret"]
            )
            let firstChunk = Data("sensitive ".utf8)
            let secondChunk = Data("response".utf8)
            context.transport.send(response)
            context.transport.send(firstChunk)
            context.transport.send(secondChunk)
            context.transport.complete()

            guard case let .started(_, requestSnapshot, _) = try XCTUnwrap(
                context.recorder.events.first
            ) else {
                return XCTFail("Expected a started transaction event")
            }
            guard case let .receivedResponse(_, responseSnapshot) = context.recorder.events[1] else {
                return XCTFail("Expected a response transaction event")
            }
            guard case let .completed(_, body, _) = try XCTUnwrap(
                context.recorder.events.last
            ) else {
                return XCTFail("Expected a completed transaction event")
            }

            XCTAssertEqual(
                requestSnapshot.body.contents,
                .unavailable(.excludedByCapturePolicy)
            )
            XCTAssertEqual(requestSnapshot.body.totalByteCount, requestPayload.count)
            XCTAssertEqual(
                responseSnapshot.headers.first {
                    $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame
                }?.value,
                WindshieldHeader.redactedValue
            )
            XCTAssertEqual(body.contents, .unavailable(.excludedByCapturePolicy))
            XCTAssertEqual(body.totalByteCount, firstChunk.count + secondChunk.count)
            XCTAssertEqual(context.transport.request?.httpBody, requestPayload)
            XCTAssertEqual(context.client.loadedData, firstChunk + secondChunk)
            XCTAssertEqual(context.client.eventNames, ["response", "data", "data", "finish"])
        }

        func testMetadataOnlyCancellationKeepsTheReceivedByteCount() {
            let context = makeContext(
                request: request(url: "https://api.example.com/private"),
                options: Windshield.Options(
                    metadataOnlyURLRules: [
                        .init(host: "api.example.com", pathPrefix: "/private"),
                    ]
                )
            )
            let partialBody = Data("partial response".utf8)

            context.protocolInstance.startLoading()
            context.transport.send(partialBody)
            context.protocolInstance.stopLoading()

            guard case let .cancelled(_, body, _) = context.recorder.events.last else {
                return XCTFail("Expected a cancelled transaction event")
            }
            XCTAssertEqual(body.contents, .unavailable(.excludedByCapturePolicy))
            XCTAssertEqual(body.totalByteCount, partialBody.count)
            XCTAssertEqual(context.client.loadedData, partialBody)
        }

        func testRepeatedStartLoadingCreatesOneTransportTaskAndOneTransaction() {
            let context = makeContext(request: request(url: "https://example.com/items"))

            context.protocolInstance.startLoading()
            context.protocolInstance.startLoading()

            XCTAssertEqual(context.transport.makeTaskCallCount, 1)
            XCTAssertEqual(context.transport.task.resumeCallCount, 1)
            XCTAssertEqual(context.recorder.events.count, 1)
            guard let event = context.recorder.events.first,
                  case .started = event
            else {
                return XCTFail("Expected one started transaction event")
            }
        }

        func testStopBeforeStartPreventsLoadingWithoutRecordingCancellation() {
            let context = makeContext(request: request(url: "https://example.com/items"))

            context.protocolInstance.stopLoading()
            context.protocolInstance.startLoading()

            XCTAssertEqual(context.transport.makeTaskCallCount, 0)
            XCTAssertEqual(context.transport.task.resumeCallCount, 0)
            XCTAssertEqual(context.transport.task.cancelCallCount, 0)
            XCTAssertTrue(context.recorder.events.isEmpty)
            XCTAssertTrue(context.client.eventNames.isEmpty)
        }

        func testTransportCallbacksBeforeStartAreIgnored() throws {
            let context = makeContext(request: request(url: "https://example.com/items"))

            try context.protocolInstance.transportDidReceive(
                httpResponse(url: "https://example.com/items")
            )
            context.protocolInstance.transportDidReceive(Data("early".utf8))
            context.protocolInstance.transportDidComplete(with: nil)

            XCTAssertTrue(context.recorder.events.isEmpty)
            XCTAssertTrue(context.client.eventNames.isEmpty)

            context.protocolInstance.startLoading()

            XCTAssertEqual(context.transport.makeTaskCallCount, 1)
            XCTAssertEqual(context.recorder.events.count, 1)
        }

        func testStopDuringStartRecordingPreventsTransportCreation() {
            let context = makeContext(request: request(url: "https://example.com/items"))
            context.recorder.recordHandler = { [weak protocolInstance = context.protocolInstance] event in
                guard case .started = event else {
                    return
                }
                protocolInstance?.stopLoading()
            }

            context.protocolInstance.startLoading()

            XCTAssertEqual(context.transport.makeTaskCallCount, 0)
            XCTAssertEqual(context.transport.task.resumeCallCount, 0)
            XCTAssertEqual(context.transport.task.cancelCallCount, 0)
            XCTAssertEqual(context.recorder.events.count, 2)
            guard let event = context.recorder.events.last,
                  case .cancelled = event
            else {
                return XCTFail("Expected a cancelled transaction event")
            }
        }

        func testStopDuringTransportCreationCancelsWithoutResumingTheTask() {
            let context = makeContext(request: request(url: "https://example.com/items"))
            context.transport.makeTaskHandler = { [weak protocolInstance = context.protocolInstance] in
                protocolInstance?.stopLoading()
            }

            context.protocolInstance.startLoading()

            XCTAssertEqual(context.transport.makeTaskCallCount, 1)
            XCTAssertEqual(context.transport.task.resumeCallCount, 0)
            XCTAssertEqual(context.transport.task.cancelCallCount, 1)
            XCTAssertEqual(context.recorder.events.count, 2)
            guard let event = context.recorder.events.last,
                  case .cancelled = event
            else {
                return XCTFail("Expected a cancelled transaction event")
            }
        }

        func testResponseAndPayloadAreForwardedIncrementallyAndRecordedOnCompletion() throws {
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

            context.transport.send(secondChunk)
            context.transport.complete()

            XCTAssertEqual(context.client.eventNames, ["response", "data", "data", "finish"])
            XCTAssertEqual(context.client.loadedData, firstChunk + secondChunk)

            XCTAssertEqual(context.recorder.events.count, 3)
            guard case let .receivedResponse(_, recordedResponse) = context.recorder.events[1] else {
                return XCTFail("Expected a received-response transaction event")
            }
            XCTAssertEqual(recordedResponse.statusCode, 201)
            XCTAssertTrue(
                recordedResponse.headers.contains(
                    WindshieldHeader(name: "Content-Type", value: "application/json")
                )
            )
            guard case let .completed(_, body, _) = try XCTUnwrap(context.recorder.events.last) else {
                return XCTFail("Expected a completed transaction event")
            }
            XCTAssertEqual(body.contents, .bytes(firstChunk + secondChunk))
        }

        func testTransportFailureIsForwardedAndRecordedExactlyOnce() throws {
            let context = makeContext(request: request(url: "https://example.com/items"))
            context.protocolInstance.startLoading()

            let error = URLError(.timedOut)
            context.transport.complete(with: error)
            context.transport.complete(with: error)

            XCTAssertEqual(context.client.eventNames, ["failure"])
            XCTAssertEqual((context.client.error as? URLError)?.code, .timedOut)
            XCTAssertEqual(context.recorder.events.count, 2)
            guard case let .failed(_, _, failure, _) = try XCTUnwrap(context.recorder.events.last) else {
                return XCTFail("Expected one failed transaction event")
            }
            XCTAssertEqual(failure, WindshieldFailure(error: error))
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
            XCTAssertEqual(context.recorder.events.count, 2)
            guard case .cancelled = try XCTUnwrap(context.recorder.events.last) else {
                return XCTFail("Expected a cancelled transaction event")
            }
        }

        func testRepeatedStopLoadingCancelsAndRecordsExactlyOnce() throws {
            let context = makeContext(request: request(url: "https://example.com/items"))
            context.protocolInstance.startLoading()

            context.protocolInstance.stopLoading()
            context.protocolInstance.stopLoading()

            XCTAssertEqual(context.transport.task.cancelCallCount, 1)
            XCTAssertEqual(context.recorder.events.count, 2)
            guard case .cancelled = try XCTUnwrap(context.recorder.events.last) else {
                return XCTFail("Expected one cancelled transaction event")
            }
        }

        func testCompletionAndCancellationRaceProducesOneTerminalOutcome() {
            for _ in 0 ..< 100 {
                let context = makeContext(request: request(url: "https://example.com/race"))
                context.protocolInstance.startLoading()

                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    context.transport.complete()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    context.protocolInstance.stopLoading()
                    group.leave()
                }

                XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
                XCTAssertEqual(context.recorder.events.count, 2)

                guard let terminalEvent = context.recorder.events.last else {
                    return XCTFail("Expected one terminal transaction event")
                }
                switch terminalEvent {
                case .completed:
                    XCTAssertEqual(context.client.eventNames, ["finish"])
                    XCTAssertEqual(context.transport.task.cancelCallCount, 0)

                case .cancelled:
                    XCTAssertTrue(context.client.eventNames.isEmpty)
                    XCTAssertEqual(context.transport.task.cancelCallCount, 1)

                default:
                    XCTFail("Expected completion or cancellation")
                }
            }
        }

        func testFailureAndCancellationRaceProducesOneTerminalOutcome() {
            for _ in 0 ..< 100 {
                let context = makeContext(request: request(url: "https://example.com/race"))
                context.protocolInstance.startLoading()

                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    context.transport.complete(with: URLError(.timedOut))
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    context.protocolInstance.stopLoading()
                    group.leave()
                }

                XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
                XCTAssertEqual(context.recorder.events.count, 2)

                guard let terminalEvent = context.recorder.events.last else {
                    return XCTFail("Expected one terminal transaction event")
                }
                switch terminalEvent {
                case .failed:
                    XCTAssertEqual(context.client.eventNames, ["failure"])
                    XCTAssertEqual(context.transport.task.cancelCallCount, 0)

                case .cancelled:
                    XCTAssertTrue(context.client.eventNames.isEmpty)
                    XCTAssertEqual(context.transport.task.cancelCallCount, 1)

                default:
                    XCTFail("Expected failure or cancellation")
                }
            }
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

        func testStopLoadingIsReentrantFromAClientDataCallback() {
            let context = makeContext(request: request(url: "https://example.com/items"))
            context.protocolInstance.startLoading()
            context.client.dataHandler = { [weak protocolInstance = context.protocolInstance] _ in
                protocolInstance?.stopLoading()
            }

            context.transport.send(Data("first".utf8))
            context.transport.send(Data("late".utf8))

            XCTAssertEqual(context.client.loadedData, Data("first".utf8))
            XCTAssertEqual(context.client.eventNames, ["data"])
            XCTAssertEqual(context.transport.task.cancelCallCount, 1)
            XCTAssertEqual(context.recorder.events.count, 2)
            guard let event = context.recorder.events.last,
                  case .cancelled = event
            else {
                return XCTFail("Expected a cancelled transaction event")
            }
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
            guard case let .redirected(_, response, _, destination, _) = try XCTUnwrap(context.recorder.events.last) else {
                return XCTFail("Expected a redirected transaction event")
            }
            XCTAssertEqual(response.statusCode, 302)
            XCTAssertEqual(destination?.absoluteString, "https://example.com/new")
        }

        func testRedirectIsTerminalAndIgnoresCompletionAndStop() throws {
            let context = makeContext(request: request(url: "https://example.com/old"))
            context.protocolInstance.startLoading()
            let redirectResponse = try httpResponse(
                url: "https://example.com/old",
                statusCode: 302
            )

            context.transport.redirect(
                to: request(url: "https://example.com/new"),
                response: redirectResponse
            )
            context.transport.complete()
            context.protocolInstance.stopLoading()

            XCTAssertEqual(context.client.eventNames, ["redirect"])
            XCTAssertEqual(context.transport.task.cancelCallCount, 0)
            XCTAssertEqual(context.recorder.events.count, 2)
            guard case .redirected = try XCTUnwrap(context.recorder.events.last) else {
                return XCTFail("Expected one redirected transaction event")
            }
        }

        func testRedirectAndCompletionRaceProducesOneTerminalOutcome() throws {
            let redirectResponse = try httpResponse(
                url: "https://example.com/old",
                statusCode: 302
            )
            let redirectRequest = request(url: "https://example.com/new")

            for _ in 0 ..< 100 {
                let context = makeContext(request: request(url: "https://example.com/old"))
                context.protocolInstance.startLoading()

                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    context.transport.redirect(
                        to: redirectRequest,
                        response: redirectResponse
                    )
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    context.transport.complete()
                    group.leave()
                }

                XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
                XCTAssertEqual(context.recorder.events.count, 2)
                XCTAssertEqual(context.transport.task.cancelCallCount, 0)
                guard let terminalEvent = context.recorder.events.last else {
                    return XCTFail("Expected one terminal transaction event")
                }
                switch terminalEvent {
                case .redirected:
                    XCTAssertEqual(context.client.eventNames, ["redirect"])

                case .completed:
                    XCTAssertEqual(context.client.eventNames, ["finish"])

                default:
                    XCTFail("Expected redirect or completion")
                }
            }
        }

        func testRedirectAndCancellationRaceProducesOneTerminalOutcome() throws {
            let redirectResponse = try httpResponse(
                url: "https://example.com/old",
                statusCode: 302
            )
            let redirectRequest = request(url: "https://example.com/new")

            for _ in 0 ..< 100 {
                let context = makeContext(request: request(url: "https://example.com/old"))
                context.protocolInstance.startLoading()

                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    context.transport.redirect(
                        to: redirectRequest,
                        response: redirectResponse
                    )
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    context.protocolInstance.stopLoading()
                    group.leave()
                }

                XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
                XCTAssertEqual(context.recorder.events.count, 2)
                guard let terminalEvent = context.recorder.events.last else {
                    return XCTFail("Expected one terminal transaction event")
                }
                switch terminalEvent {
                case .redirected:
                    XCTAssertEqual(context.client.eventNames, ["redirect"])
                    XCTAssertEqual(context.transport.task.cancelCallCount, 0)

                case .cancelled:
                    XCTAssertTrue(context.client.eventNames.isEmpty)
                    XCTAssertEqual(context.transport.task.cancelCallCount, 1)

                default:
                    XCTFail("Expected redirect or cancellation")
                }
            }
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

            guard case let .completed(_, body, _) = try XCTUnwrap(context.recorder.events.last) else {
                return XCTFail("Expected a completed transaction event")
            }
            XCTAssertEqual(
                body.capturedByteCount,
                WindshieldURLProtocol.maximumCapturedResponseBodySize
            )
            XCTAssertEqual(body.totalByteCount, payload.count)
            XCTAssertTrue(body.isTruncated)
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

        func testPublicTargetedAPIRecordsACompleteTransactionInTheSharedStore() async throws {
            let recorder = WindshieldTransactionRecorder.shared
            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()

            let responseBody = Data("{\"recorded\":true}".utf8)
            let server = try LoopbackHTTPServer(responseBody: responseBody)
            let port = try server.start()
            defer { server.stop() }

            let configuration = URLSessionConfiguration.ephemeral
            Windshield.start(intercepting: configuration)
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            let requestBody = Data("{\"name\":\"Windshield\"}".utf8)
            var outgoingRequest = request(
                url: "http://127.0.0.1:\(port.rawValue)/public-api"
            )
            outgoingRequest.httpMethod = "POST"
            outgoingRequest.httpBody = requestBody
            outgoingRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            outgoingRequest.setValue("public-api", forHTTPHeaderField: "X-Windshield-Test")

            let (receivedBody, receivedResponse) = try await session.data(for: outgoingRequest)
            XCTAssertEqual(receivedBody, responseBody)
            XCTAssertEqual((receivedResponse as? HTTPURLResponse)?.statusCode, 200)

            await recorder.flush()
            let transaction = await MainActor.run {
                WindshieldStore.shared.transactions.first
            }

            XCTAssertEqual(transaction?.request.url, outgoingRequest.url)
            XCTAssertEqual(transaction?.request.method, "POST")
            XCTAssertEqual(
                transaction?.request.body.contents,
                .unavailable(.bodyStream)
            )
            XCTAssertEqual(transaction?.request.body.totalByteCount, requestBody.count)
            XCTAssertTrue(
                transaction?.request.headers.contains(
                    WindshieldHeader(name: "X-Windshield-Test", value: "public-api")
                ) == true
            )
            XCTAssertEqual(transaction?.response?.statusCode, 200)
            XCTAssertEqual(transaction?.response?.body?.contents, .bytes(responseBody))
            XCTAssertTrue(
                transaction?.response?.headers.contains(
                    WindshieldHeader(name: "X-Windshield-Response", value: "captured")
                ) == true
            )
            XCTAssertEqual(transaction?.state, .completed)
            XCTAssertTrue(server.receivedRequest.contains("POST /public-api"))
            XCTAssertTrue(server.receivedRequest.contains("{\"name\":\"Windshield\"}"))

            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()
        }

        func testPublicIgnoredHostStillCompletesWithoutCreatingAStoreRow() async throws {
            let recorder = WindshieldTransactionRecorder.shared
            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()

            let responseBody = Data("network response".utf8)
            let server = try LoopbackHTTPServer(responseBody: responseBody)
            let port = try server.start()
            defer { server.stop() }

            let configuration = URLSessionConfiguration.ephemeral
            Windshield.start(
                intercepting: configuration,
                options: Windshield.Options(ignoredHosts: ["127.0.0.1"])
            )
            defer {
                WindshieldCapturePolicyStore.shared.configure(options: Windshield.Options())
            }
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            var outgoingRequest = request(
                url: "http://127.0.0.1:\(port.rawValue)/ignored"
            )
            outgoingRequest.httpMethod = "POST"
            outgoingRequest.httpBody = Data("network request".utf8)

            let (data, response) = try await session.data(for: outgoingRequest)

            XCTAssertEqual(data, responseBody)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(server.receivedRequest.contains("POST /ignored"))
            XCTAssertTrue(server.receivedRequest.contains("network request"))

            await recorder.flush()
            let transactions = await MainActor.run {
                WindshieldStore.shared.transactions
            }
            XCTAssertTrue(transactions.isEmpty)

            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()
        }

        private func makeContext(
            request: URLRequest,
            options: Windshield.Options = Windshield.Options()
        ) -> TestContext {
            let client = URLProtocolClientSpy()
            let transport = WindshieldTransportSpy()
            let recorder = WindshieldRecorderSpy()
            let policyStore = WindshieldCapturePolicyStore(options: options)
            let protocolInstance = WindshieldURLProtocol(
                request: request,
                cachedResponse: nil,
                client: client
            )
            protocolInstance.transport = transport
            protocolInstance.recorder = recorder
            protocolInstance.capturePolicyProvider = policyStore

            return TestContext(
                protocolInstance: protocolInstance,
                client: client,
                transport: transport,
                recorder: recorder,
                policyStore: policyStore
            )
        }

        private func headerValue(
            _ name: String,
            in headers: [WindshieldHeader]
        ) -> String? {
            headers.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }?.value
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
    }

    private struct TestContext: @unchecked Sendable {
        let protocolInstance: WindshieldURLProtocol
        let client: URLProtocolClientSpy
        let transport: WindshieldTransportSpy
        let recorder: WindshieldRecorderSpy
        let policyStore: WindshieldCapturePolicyStore
    }

    private final class WindshieldTransportSpy: WindshieldTransporting {
        let task = WindshieldTransportTaskSpy()
        private(set) var makeTaskCallCount = 0
        private(set) var request: URLRequest?
        private weak var observer: WindshieldTransportObserver?
        var makeTaskHandler: (() -> Void)?

        func makeTask(
            for request: URLRequest,
            observer: WindshieldTransportObserver
        ) -> WindshieldTransportTask {
            makeTaskCallCount += 1
            self.request = request
            self.observer = observer
            makeTaskHandler?()
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

    private final class WindshieldRecorderSpy: WindshieldRecording {
        private(set) var events: [WindshieldTransactionEvent] = []
        var recordHandler: ((WindshieldTransactionEvent) -> Void)?

        func record(_ event: WindshieldTransactionEvent) {
            events.append(event)
            recordHandler?(event)
        }
    }

    private final class URLProtocolClientSpy: NSObject, URLProtocolClient, @unchecked Sendable {
        private(set) var eventNames: [String] = []
        private(set) var loadedData = Data()
        private(set) var error: Error?
        private(set) var redirectedRequest: URLRequest?
        private(set) var receivedResponse: URLResponse?
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
            didReceive response: URLResponse,
            cacheStoragePolicy _: URLCache.StoragePolicy
        ) {
            eventNames.append("response")
            receivedResponse = response
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
            didReceive _: URLAuthenticationChallenge
        ) {}

        func urlProtocol(
            _: URLProtocol,
            didCancel _: URLAuthenticationChallenge
        ) {}
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
                    let hasCompleteRequest = Self.hasCompleteRequest(requestData)
                    requestLock.unlock()

                    if hasCompleteRequest {
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
            X-Windshield-Response: captured\r
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
                    Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "")
                } ?? 0
            let headerByteCount = data.distance(
                from: data.startIndex,
                to: headerRange.upperBound
            )
            return data.count >= headerByteCount + contentLength
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

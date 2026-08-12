import Foundation
import XCTest

#if DEBUG
    @testable import Windshield

    final class WindshieldStoreTests: XCTestCase {
        func testStartedTransactionsAreNewestFirstAndCompletionDoesNotReorderThem() {
            let olderID = UUID()
            let newerID = UUID()
            let start = Date(timeIntervalSince1970: 100)
            var reducer = WindshieldTransactionReducer()

            reducer.reduce(.started(id: olderID, request: request(), at: start))
            reducer.reduce(.started(id: newerID, request: request(), at: start.addingTimeInterval(1)))
            reducer.reduce(
                .completed(
                    id: olderID,
                    body: body("older response"),
                    at: start.addingTimeInterval(2)
                )
            )

            XCTAssertEqual(reducer.transactions.map(\.id), [newerID, olderID])
            XCTAssertEqual(reducer.transactions.last?.state, .completed)
            XCTAssertEqual(reducer.transactions.last?.duration, 2)
        }

        func testResponseMetadataAndBodyAreMergedIntoTheActiveTransaction() {
            let id = UUID()
            var reducer = WindshieldTransactionReducer()
            reducer.reduce(.started(id: id, request: request(), at: Date()))

            var response = response(statusCode: 201)
            XCTAssertNil(response.body)
            reducer.reduce(.receivedResponse(id: id, response: response))
            reducer.reduce(.completed(id: id, body: body("created"), at: Date()))

            response.body = body("created")
            XCTAssertEqual(reducer.transactions.first?.response, response)
            XCTAssertEqual(reducer.transactions.first?.state, .completed)
        }

        func testFailurePreservesPartialResponseBodyAndErrorDetails() {
            let id = UUID()
            let error = URLError(.timedOut)
            var reducer = WindshieldTransactionReducer()
            reducer.reduce(.started(id: id, request: request(), at: Date()))
            reducer.reduce(.receivedResponse(id: id, response: response(statusCode: 503)))
            reducer.reduce(
                .failed(
                    id: id,
                    body: body("partial"),
                    failure: WindshieldFailure(error: error),
                    at: Date()
                )
            )

            let transaction = reducer.transactions.first
            XCTAssertEqual(transaction?.response?.body, body("partial"))
            XCTAssertEqual(transaction?.state, .failed(WindshieldFailure(error: error)))
            XCTAssertTrue(transaction?.isError == true)
        }

        func testCancellationAndRedirectAreTerminalAndIgnoreLateEvents() {
            let cancelledID = UUID()
            let redirectedID = UUID()
            let destination = URL(string: "https://example.com/new")
            var reducer = WindshieldTransactionReducer()

            reducer.reduce(.started(id: cancelledID, request: request(), at: Date()))
            reducer.reduce(.cancelled(id: cancelledID, body: body("partial"), at: Date()))
            XCTAssertFalse(
                reducer.reduce(
                    .failed(
                        id: cancelledID,
                        body: body("late"),
                        failure: WindshieldFailure(error: URLError(.cancelled)),
                        at: Date()
                    )
                )
            )

            reducer.reduce(.started(id: redirectedID, request: request(), at: Date()))
            reducer.reduce(
                .redirected(
                    id: redirectedID,
                    response: response(statusCode: 302),
                    body: body("redirect"),
                    destination: destination,
                    at: Date()
                )
            )

            XCTAssertEqual(reducer.transactions[1].state, .cancelled)
            XCTAssertEqual(reducer.transactions[0].state, .redirected(to: destination))
        }

        func testMetricsAttachBeforeOrAfterTerminationAndDuplicatesAreIgnored() {
            let beforeCompletionID = UUID()
            let afterCompletionID = UUID()
            let metrics = networkMetrics(duration: 0.75)
            var reducer = WindshieldTransactionReducer()

            reducer.reduce(
                .started(id: beforeCompletionID, request: request(), at: Date())
            )
            XCTAssertTrue(
                reducer.reduce(
                    .receivedNetworkMetrics(
                        id: beforeCompletionID,
                        metrics: metrics
                    )
                )
            )
            reducer.reduce(
                .completed(
                    id: beforeCompletionID,
                    body: body("complete"),
                    at: Date()
                )
            )

            reducer.reduce(
                .started(id: afterCompletionID, request: request(), at: Date())
            )
            reducer.reduce(
                .completed(
                    id: afterCompletionID,
                    body: body("complete"),
                    at: Date()
                )
            )
            XCTAssertTrue(
                reducer.reduce(
                    .receivedNetworkMetrics(
                        id: afterCompletionID,
                        metrics: metrics
                    )
                )
            )
            XCTAssertFalse(
                reducer.reduce(
                    .receivedNetworkMetrics(
                        id: afterCompletionID,
                        metrics: networkMetrics(duration: 5)
                    )
                )
            )
            XCTAssertFalse(
                reducer.reduce(
                    .receivedNetworkMetrics(id: UUID(), metrics: metrics)
                )
            )

            XCTAssertTrue(
                reducer.transactions.allSatisfy {
                    $0.state == .completed && $0.networkMetrics == metrics
                }
            )
        }

        func testTransactionRetentionRemovesTheOldestTerminalRowBeforeAnActiveRow() {
            let activeID = UUID()
            let completedID = UUID()
            let newestID = UUID()
            var reducer = WindshieldTransactionReducer(
                policy: WindshieldRetentionPolicy(maximumTransactionCount: 2)
            )

            reducer.reduce(.started(id: activeID, request: request(), at: Date()))
            reducer.reduce(.started(id: completedID, request: request(), at: Date()))
            reducer.reduce(.completed(id: completedID, body: body("done"), at: Date()))
            reducer.reduce(.started(id: newestID, request: request(), at: Date()))

            XCTAssertEqual(reducer.transactions.map(\.id), [newestID, activeID])
        }

        func testBodyBudgetDiscardsOldestTerminalPayloadButKeepsMetadata() {
            let olderID = UUID()
            let newerID = UUID()
            let policy = WindshieldRetentionPolicy(
                maximumTransactionCount: 10,
                maximumTotalBodyByteCount: 5
            )
            var reducer = WindshieldTransactionReducer(policy: policy)

            reducer.reduce(.started(id: olderID, request: request(body: "1234"), at: Date()))
            reducer.reduce(.receivedResponse(id: olderID, response: response()))
            reducer.reduce(.completed(id: olderID, body: body("5678"), at: Date()))
            reducer.reduce(.started(id: newerID, request: request(body: "abc"), at: Date()))

            let older = reducer.transactions.last
            XCTAssertEqual(older?.id, olderID)
            XCTAssertEqual(
                older?.response?.body?.contents,
                .unavailable(.discardedByRetentionPolicy)
            )
            XCTAssertEqual(
                older?.request.body.contents,
                .unavailable(.discardedByRetentionPolicy)
            )
            XCTAssertEqual(reducer.transactions.first?.request.body.capturedByteCount, 3)
        }

        func testInvalidRetentionLimitsClampToSafeMinimums() {
            let olderID = UUID()
            let newerID = UUID()
            let policy = WindshieldRetentionPolicy(
                maximumTransactionCount: 0,
                maximumTotalBodyByteCount: -1
            )
            var reducer = WindshieldTransactionReducer(policy: policy)

            reducer.reduce(.started(id: olderID, request: request(body: "older"), at: Date()))
            reducer.reduce(.started(id: newerID, request: request(body: "newer"), at: Date()))

            XCTAssertEqual(policy.maximumTransactionCount, 1)
            XCTAssertEqual(policy.maximumTotalBodyByteCount, 0)
            XCTAssertEqual(reducer.transactions.map(\.id), [newerID])
            XCTAssertEqual(
                reducer.transactions.first?.request.body.contents,
                .unavailable(.discardedByRetentionPolicy)
            )
        }

        func testExactBodyBudgetBoundaryRetainsEveryPayload() {
            let id = UUID()
            let policy = WindshieldRetentionPolicy(
                maximumTransactionCount: 10,
                maximumTotalBodyByteCount: 8
            )
            var reducer = WindshieldTransactionReducer(policy: policy)

            reducer.reduce(.started(id: id, request: request(body: "1234"), at: Date()))
            reducer.reduce(.receivedResponse(id: id, response: response()))
            reducer.reduce(.completed(id: id, body: body("5678"), at: Date()))

            XCTAssertEqual(
                reducer.transactions.first?.request.body.contents,
                .bytes(Data("1234".utf8))
            )
            XCTAssertEqual(
                reducer.transactions.first?.response?.body?.contents,
                .bytes(Data("5678".utf8))
            )
        }

        func testClearDropsAnActiveTransactionAndIgnoresItsRemainingLifecycle() {
            let id = UUID()
            var reducer = WindshieldTransactionReducer()

            reducer.reduce(.started(id: id, request: request(), at: Date()))
            XCTAssertTrue(reducer.clear())

            XCTAssertFalse(reducer.reduce(.receivedResponse(id: id, response: response())))
            XCTAssertFalse(reducer.reduce(.completed(id: id, body: body("late"), at: Date())))
            XCTAssertFalse(
                reducer.reduce(
                    .failed(
                        id: id,
                        body: body("late"),
                        failure: WindshieldFailure(error: URLError(.cancelled)),
                        at: Date()
                    )
                )
            )
            XCTAssertTrue(reducer.transactions.isEmpty)
        }

        func testAllActiveRetentionOverflowRemovesTheOldestActiveTransaction() {
            let oldestID = UUID()
            let middleID = UUID()
            let newestID = UUID()
            var reducer = WindshieldTransactionReducer(
                policy: WindshieldRetentionPolicy(maximumTransactionCount: 2)
            )

            reducer.reduce(.started(id: oldestID, request: request(), at: Date()))
            reducer.reduce(.started(id: middleID, request: request(), at: Date()))
            reducer.reduce(.started(id: newestID, request: request(), at: Date()))

            XCTAssertEqual(reducer.transactions.map(\.id), [newestID, middleID])
            XCTAssertFalse(
                reducer.reduce(.completed(id: oldestID, body: body("late"), at: Date()))
            )
            XCTAssertTrue(reducer.transactions.allSatisfy { $0.state == .inFlight })
        }

        func testClearAndDuplicateStartAreIdempotent() {
            let id = UUID()
            var reducer = WindshieldTransactionReducer()
            let event = WindshieldTransactionEvent.started(
                id: id,
                request: request(),
                at: Date()
            )

            XCTAssertTrue(reducer.reduce(event))
            XCTAssertFalse(reducer.reduce(event))
            XCTAssertTrue(reducer.clear())
            XCTAssertFalse(reducer.clear())
            XCTAssertFalse(
                reducer.reduce(.completed(id: id, body: body("late"), at: Date()))
            )
            XCTAssertTrue(reducer.transactions.isEmpty)
        }

        func testRequestSnapshotCapsBodiesAndDoesNotConsumeStreams() throws {
            var bodyRequest = try URLRequest(url: XCTUnwrap(URL(string: "https://example.com")))
            bodyRequest.httpBody = Data("123456".utf8)

            let captured = WindshieldRequestSnapshot(
                request: bodyRequest,
                maximumBodyByteCount: 4
            )
            XCTAssertEqual(captured.body.capturedByteCount, 4)
            XCTAssertEqual(captured.body.totalByteCount, 6)
            XCTAssertTrue(captured.body.isTruncated)

            var streamRequest = try URLRequest(url: XCTUnwrap(URL(string: "https://example.com")))
            streamRequest.httpBodyStream = InputStream(data: Data("stream".utf8))
            streamRequest.setValue("6", forHTTPHeaderField: "Content-Length")

            let streamed = WindshieldRequestSnapshot(
                request: streamRequest,
                maximumBodyByteCount: 4
            )
            XCTAssertEqual(streamed.body.contents, .unavailable(.bodyStream))
            XCTAssertEqual(streamed.body.totalByteCount, 6)
        }

        func testSnapshotsRedactConfiguredHeadersWithoutMutatingNetworkValues() throws {
            var request = try URLRequest(
                url: XCTUnwrap(URL(string: "https://example.com/private"))
            )
            request.setValue("Bearer request-secret", forHTTPHeaderField: "Authorization")
            request.setValue("visible", forHTTPHeaderField: "X-Public")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Set-Cookie": "session=response-secret",
                        "X-Public": "visible",
                    ]
                )
            )
            let redactedNames: Set = ["authorization", "set-cookie"]

            let requestSnapshot = WindshieldRequestSnapshot(
                request: request,
                maximumBodyByteCount: 1024,
                redactedHeaderNames: redactedNames
            )
            let responseSnapshot = WindshieldResponseSnapshot(
                response: response,
                redactedHeaderNames: redactedNames
            )

            XCTAssertEqual(
                requestSnapshot.headers.first {
                    $0.name.caseInsensitiveCompare("Authorization") == .orderedSame
                }?.value,
                WindshieldHeader.redactedValue
            )
            XCTAssertEqual(
                responseSnapshot.headers.first {
                    $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame
                }?.value,
                WindshieldHeader.redactedValue
            )
            XCTAssertTrue(
                requestSnapshot.headers.contains(
                    WindshieldHeader(name: "X-Public", value: "visible")
                )
            )
            XCTAssertTrue(
                responseSnapshot.headers.contains {
                    $0.name.caseInsensitiveCompare("X-Public") == .orderedSame
                        && $0.value == "visible"
                }
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer request-secret"
            )
            XCTAssertEqual(
                response.value(forHTTPHeaderField: "Set-Cookie"),
                "session=response-secret"
            )
        }

        func testMetadataOnlyRequestSnapshotKeepsKnownLengthWithoutCopyingBody() throws {
            var request = try URLRequest(
                url: XCTUnwrap(URL(string: "https://example.com/private"))
            )
            let payload = Data("sensitive payload".utf8)
            request.httpBody = payload

            let snapshot = WindshieldRequestSnapshot(
                request: request,
                maximumBodyByteCount: 1024,
                bodyCapture: .metadataOnly
            )

            XCTAssertEqual(snapshot.body.contents, .unavailable(.excludedByCapturePolicy))
            XCTAssertEqual(snapshot.body.totalByteCount, payload.count)
            XCTAssertEqual(request.httpBody, payload)

            var streamedRequest = try URLRequest(
                url: XCTUnwrap(URL(string: "https://example.com/upload"))
            )
            let stream = InputStream(data: payload)
            streamedRequest.httpBodyStream = stream
            streamedRequest.setValue(
                String(payload.count),
                forHTTPHeaderField: "Content-Length"
            )

            let streamedSnapshot = WindshieldRequestSnapshot(
                request: streamedRequest,
                maximumBodyByteCount: 1024,
                bodyCapture: .metadataOnly
            )

            XCTAssertEqual(
                streamedSnapshot.body.contents,
                .unavailable(.excludedByCapturePolicy)
            )
            XCTAssertEqual(streamedSnapshot.body.totalByteCount, payload.count)
            XCTAssertEqual(stream.streamStatus, .notOpen)
        }

        func testRecorderPublishesReducedTransactionsOnTheMainActor() async {
            let recorder = WindshieldTransactionRecorder.shared
            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()

            let id = UUID()
            recorder.record(.started(id: id, request: request(), at: Date()))
            recorder.record(.receivedResponse(id: id, response: response()))
            recorder.record(.completed(id: id, body: body("published"), at: Date()))
            await recorder.flush()

            let transaction = await MainActor.run {
                XCTAssertTrue(Thread.isMainThread)
                return WindshieldStore.shared.transactions.first
            }
            XCTAssertEqual(transaction?.id, id)
            XCTAssertEqual(transaction?.state, .completed)
            XCTAssertEqual(transaction?.response?.body, body("published"))

            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()
        }

        func testRecorderPublishesAutomaticallyWithoutFlush() async {
            let recorder = WindshieldTransactionRecorder.shared
            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()

            let id = UUID()
            recorder.record(.started(id: id, request: request(), at: Date()))
            recorder.record(.receivedResponse(id: id, response: response()))
            recorder.record(.completed(id: id, body: body("published"), at: Date()))

            var didPublishCompletedTransaction = false
            for _ in 0 ..< 200 {
                didPublishCompletedTransaction = await MainActor.run {
                    XCTAssertTrue(Thread.isMainThread)
                    guard let transaction = WindshieldStore.shared.transactions.first else {
                        return false
                    }

                    return transaction.id == id && transaction.state == .completed
                }
                if didPublishCompletedTransaction {
                    break
                }

                try? await Task<Never, Never>.sleep(nanoseconds: 10_000_000)
            }

            XCTAssertTrue(didPublishCompletedTransaction)

            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()
        }

        func testRecorderFlushPublishesTheLatestQueuedRevision() async {
            let recorder = WindshieldTransactionRecorder.shared
            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()

            let ids = (0 ..< 20).map { _ in UUID() }
            for id in ids {
                recorder.record(.started(id: id, request: request(), at: Date()))
            }
            await recorder.flush()

            let publishedIDs = await MainActor.run {
                WindshieldStore.shared.transactions.map(\.id)
            }
            XCTAssertEqual(Set(publishedIDs), Set(ids))

            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            await recorder.flush()
        }

        func testRecorderAppliesLiveRetentionReconfiguration() async {
            let recorder = WindshieldTransactionRecorder.shared
            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            recorder.configure(maximumTransactionCount: 4)
            await recorder.flush()

            let ids = (0 ..< 4).map { _ in UUID() }
            for (index, id) in ids.enumerated() {
                let startedAt = Date(timeIntervalSince1970: TimeInterval(index))
                recorder.record(.started(id: id, request: request(), at: startedAt))
                recorder.record(
                    .completed(
                        id: id,
                        body: .capture(
                            Data("response \(index)".utf8),
                            maximumByteCount: 1024
                        ),
                        at: startedAt.addingTimeInterval(1)
                    )
                )
            }
            await recorder.flush()

            recorder.configure(maximumTransactionCount: 2)
            await recorder.flush()

            let retainedIDs = await MainActor.run {
                WindshieldStore.shared.transactions.map(\.id)
            }
            XCTAssertEqual(retainedIDs, [ids[3], ids[2]])

            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            recorder.configure(
                maximumTransactionCount: WindshieldRetentionPolicy.defaultMaximumTransactionCount
            )
            await recorder.flush()
        }

        func testRecorderHandlesConcurrentProducersWithoutLosingTransactions() async {
            let recorder = WindshieldTransactionRecorder.shared
            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            recorder.configure(maximumTransactionCount: 64)
            await recorder.flush()

            let ids = (0 ..< 64).map { _ in UUID() }
            let metrics = ids.indices.map { index in
                let start = Date(timeIntervalSince1970: TimeInterval(index))
                return WindshieldNetworkMetrics(
                    raw: .init(
                        taskStartDate: start,
                        taskEndDate: start.addingTimeInterval(0.25),
                        attempts: []
                    )
                )
            }
            DispatchQueue.concurrentPerform(iterations: ids.count) { index in
                let id = ids[index]
                let startedAt = Date(timeIntervalSince1970: TimeInterval(index))
                var urlRequest = URLRequest(
                    url: URL(string: "https://example.com/items/\(index)")!
                )
                urlRequest.httpMethod = "POST"
                urlRequest.httpBody = Data("request \(index)".utf8)
                let request = WindshieldRequestSnapshot(
                    request: urlRequest,
                    maximumBodyByteCount: 1024
                )
                let response = WindshieldResponseSnapshot(
                    response: HTTPURLResponse(
                        url: urlRequest.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )

                recorder.record(.started(id: id, request: request, at: startedAt))
                recorder.record(.receivedResponse(id: id, response: response))
                recorder.record(
                    .completed(
                        id: id,
                        body: .capture(
                            Data("response \(index)".utf8),
                            maximumByteCount: 1024
                        ),
                        at: startedAt.addingTimeInterval(1)
                    )
                )
                recorder.record(
                    .receivedNetworkMetrics(
                        id: id,
                        metrics: metrics[index]
                    )
                )
            }
            await recorder.flush()

            let transactions = await MainActor.run {
                WindshieldStore.shared.transactions
            }
            XCTAssertEqual(transactions.count, ids.count)
            XCTAssertEqual(Set(transactions.map(\.id)), Set(ids))
            XCTAssertTrue(transactions.allSatisfy { $0.state == .completed })
            XCTAssertTrue(transactions.allSatisfy { $0.response?.statusCode == 200 })
            XCTAssertTrue(transactions.allSatisfy { $0.networkMetrics != nil })
            XCTAssertTrue(
                transactions.allSatisfy { ($0.response?.body?.capturedByteCount ?? 0) > 0 }
            )

            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            recorder.configure(
                maximumTransactionCount: WindshieldRetentionPolicy.defaultMaximumTransactionCount
            )
            await recorder.flush()
        }

        func testConcurrentFlushesPublishTheLatestRevisionAndAllReturn() async {
            let recorder = WindshieldTransactionRecorder.shared
            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            recorder.configure(maximumTransactionCount: 16)
            await recorder.flush()

            let ids = (0 ..< 16).map { _ in UUID() }
            for id in ids {
                recorder.record(.started(id: id, request: request(), at: Date()))
            }

            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 16 {
                    group.addTask {
                        await recorder.flush()
                    }
                }
                await group.waitForAll()
            }

            let retainedIDs = await MainActor.run {
                Set(WindshieldStore.shared.transactions.map(\.id))
            }
            XCTAssertEqual(retainedIDs, Set(ids))

            await MainActor.run {
                WindshieldStore.shared.clear()
            }
            recorder.configure(
                maximumTransactionCount: WindshieldRetentionPolicy.defaultMaximumTransactionCount
            )
            await recorder.flush()
        }

        private func request(body text: String = "") -> WindshieldRequestSnapshot {
            var request = URLRequest(url: URL(string: "https://example.com/items")!)
            request.httpMethod = "POST"
            request.httpBody = Data(text.utf8)
            return WindshieldRequestSnapshot(request: request, maximumBodyByteCount: 1024)
        }

        private func response(statusCode: Int = 200) -> WindshieldResponseSnapshot {
            WindshieldResponseSnapshot(
                response: HTTPURLResponse(
                    url: URL(string: "https://example.com/items")!,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }

        private func body(_ text: String) -> WindshieldBodyCapture {
            .capture(Data(text.utf8), maximumByteCount: 1024)
        }

        private func networkMetrics(duration: TimeInterval) -> WindshieldNetworkMetrics {
            let start = Date(timeIntervalSince1970: 100)
            return WindshieldNetworkMetrics(
                raw: .init(
                    taskStartDate: start,
                    taskEndDate: start.addingTimeInterval(duration),
                    attempts: []
                )
            )
        }
    }
#endif

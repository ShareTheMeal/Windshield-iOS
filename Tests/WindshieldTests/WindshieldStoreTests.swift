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
    }
#endif

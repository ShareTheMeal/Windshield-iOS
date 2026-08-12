import Foundation
import XCTest

#if DEBUG
    @testable import Windshield

    final class WindshieldInspectorFormattingTests: XCTestCase {
        func testFiltersMatchTransportAndHTTPFailuresAndActiveRequests() {
            let active = transaction(state: .inFlight)
            let successful = transaction(statusCode: 204, state: .completed)
            let httpError = transaction(statusCode: 404, state: .completed)
            let transportError = transaction(
                state: .failed(WindshieldFailure(error: URLError(.timedOut)))
            )

            XCTAssertTrue(matches(active, filter: .active))
            XCTAssertFalse(matches(successful, filter: .active))
            XCTAssertTrue(matches(httpError, filter: .errors))
            XCTAssertTrue(matches(transportError, filter: .errors))
            XCTAssertFalse(matches(successful, filter: .errors))
        }

        func testSearchMatchesMethodURLStatusAndFailureTextWithoutConsideringCase() {
            let request = transaction(method: "PATCH", statusCode: 422, state: .completed)
            let failure = transaction(
                state: .failed(
                    WindshieldFailure(
                        error: NSError(
                            domain: "Network",
                            code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "Device is offline"]
                        )
                    )
                )
            )

            XCTAssertTrue(matches(request, searchText: "patch"))
            XCTAssertTrue(matches(request, searchText: "EXAMPLE.COM/ITEMS"))
            XCTAssertTrue(matches(request, searchText: "422"))
            XCTAssertTrue(matches(failure, searchText: "offline"))
            XCTAssertFalse(matches(request, searchText: "payments"))
        }

        func testSearchAndFilterMustBothMatchTheTransaction() {
            let active = transaction(method: "POST", state: .inFlight)
            let httpError = transaction(method: "POST", statusCode: 503, state: .completed)
            let successful = transaction(method: "POST", statusCode: 201, state: .completed)

            XCTAssertTrue(matches(httpError, filter: .errors, searchText: "post"))
            XCTAssertFalse(matches(successful, filter: .errors, searchText: "post"))
            XCTAssertFalse(matches(httpError, filter: .active, searchText: "post"))
            XCTAssertTrue(matches(active, filter: .active, searchText: "  ITEMS  "))
            XCTAssertFalse(matches(active, filter: .active, searchText: "delete"))
        }

        func testSlowFilterPrefersTaskMetricsAndFallsBackToTransactionDuration() {
            let slowFromMetrics = transaction(
                state: .completed,
                duration: 0.2,
                metricsDuration: 1.2
            )
            let fastFromMetrics = transaction(
                state: .completed,
                duration: 2,
                metricsDuration: 0.7
            )
            let slowWithoutMetrics = transaction(
                state: .completed,
                duration: 1.1
            )
            let active = transaction(
                state: .inFlight,
                metricsDuration: 3
            )

            XCTAssertTrue(matches(slowFromMetrics, filter: .slow))
            XCTAssertFalse(matches(fastFromMetrics, filter: .slow))
            XCTAssertTrue(matches(slowWithoutMetrics, filter: .slow))
            XCTAssertFalse(matches(active, filter: .slow))
        }

        func testHostLatencySummaryUsesTerminalRequestsAndStableTopThreeOrdering() {
            let transactions = [
                transaction(host: "alpha.example", state: .completed, metricsDuration: 2),
                transaction(host: "alpha.example", state: .completed, metricsDuration: 4),
                transaction(host: "zeta.example", state: .completed, metricsDuration: 3),
                transaction(host: "beta.example", state: .failed(
                    WindshieldFailure(error: URLError(.timedOut))
                ), metricsDuration: 2.5),
                transaction(host: "gamma.example", state: .completed, metricsDuration: 1),
                transaction(host: "ignored.example", state: .inFlight, metricsDuration: 99),
            ]

            let summaries = WindshieldPerformanceSummary.slowestHosts(
                in: transactions
            )

            XCTAssertEqual(
                summaries.map(\.host),
                ["alpha.example", "zeta.example", "beta.example"]
            )
            XCTAssertEqual(summaries[0].sampleCount, 2)
            XCTAssertEqual(summaries[0].averageDuration, 3, accuracy: 0.000_001)
            XCTAssertEqual(summaries[0].maximumDuration, 4, accuracy: 0.000_001)
        }

        func testHostLatencySummaryUsesHostnameForExactTimingTies() {
            let summaries = WindshieldPerformanceSummary.slowestHosts(
                in: [
                    transaction(host: "zeta.example", state: .completed, metricsDuration: 2),
                    transaction(host: "alpha.example", state: .completed, metricsDuration: 2),
                ]
            )

            XCTAssertEqual(summaries.map(\.host), ["alpha.example", "zeta.example"])
        }

        func testRequestSnapshotDefaultsMethodAndSortsHeadersWithoutChangingValues() throws {
            var request = try URLRequest(url: XCTUnwrap(URL(string: "https://api.example.com/items")))
            request.httpMethod = nil
            request.setValue("last", forHTTPHeaderField: "z-custom")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("first", forHTTPHeaderField: "accept")

            let snapshot = WindshieldRequestSnapshot(
                request: request,
                maximumBodyByteCount: 1024
            )

            XCTAssertEqual(snapshot.method, "GET")
            XCTAssertEqual(
                snapshot.headers.map { $0.name.lowercased() },
                ["accept", "content-type", "z-custom"]
            )
            XCTAssertEqual(
                snapshot.headers.map(\.value),
                ["first", "application/json", "last"]
            )
        }

        func testRequestSnapshotAcceptsOnlyNonnegativeIntegerContentLengths() {
            XCTAssertEqual(streamedRequestSnapshot(contentLength: "0").body.totalByteCount, 0)
            XCTAssertEqual(streamedRequestSnapshot(contentLength: "2048").body.totalByteCount, 2048)
            XCTAssertNil(streamedRequestSnapshot(contentLength: "-1").body.totalByteCount)
            XCTAssertNil(streamedRequestSnapshot(contentLength: "not-a-number").body.totalByteCount)
        }

        func testHeaderFormatterPreservesTheSortedSnapshotOrder() {
            let headers = [
                WindshieldHeader(name: "Accept", value: "application/json"),
                WindshieldHeader(name: "X-Request-ID", value: "abc"),
            ]

            XCTAssertEqual(
                WindshieldHeaderFormatter.format(headers),
                "Accept: application/json\nX-Request-ID: abc"
            )
        }

        func testDisplayFormatterUsesAReadableZeroByteLabel() {
            XCTAssertEqual(WindshieldDisplayFormatter.byteCount(0), "0 bytes")
            XCTAssertEqual(WindshieldDisplayFormatter.byteCount(-1), "0 bytes")
        }

        func testDisplayFormatterProducesStableDurationLabels() {
            XCTAssertEqual(WindshieldDisplayFormatter.duration(nil), "Active")
            XCTAssertEqual(WindshieldDisplayFormatter.duration(-1), "0 ms")
            XCTAssertEqual(WindshieldDisplayFormatter.duration(0.256), "256 ms")
            XCTAssertEqual(WindshieldDisplayFormatter.duration(1), "1.00 s")
            XCTAssertEqual(WindshieldDisplayFormatter.duration(1.234), "1.23 s")
        }

        func testTransactionStatusTextCoversEveryLifecycleState() {
            let failure = WindshieldFailure(error: URLError(.timedOut))

            XCTAssertEqual(transaction(state: .inFlight).statusText, "Active")
            XCTAssertEqual(transaction(statusCode: 204, state: .completed).statusText, "204")
            XCTAssertEqual(transaction(state: .completed).statusText, "Complete")
            XCTAssertEqual(transaction(state: .failed(failure)).statusText, "Error")
            XCTAssertEqual(transaction(state: .cancelled).statusText, "Cancelled")
            XCTAssertEqual(
                transaction(statusCode: 302, state: .redirected(to: nil)).statusText,
                "302"
            )
            XCTAssertEqual(transaction(state: .redirected(to: nil)).statusText, "Redirect")
        }

        func testFailureTruncatesLongDescriptionsAtTheDisplayBoundary() {
            let description = String(repeating: "x", count: 2500)
            let failure = WindshieldFailure(
                error: NSError(
                    domain: "InspectorTests",
                    code: 99,
                    userInfo: [NSLocalizedDescriptionKey: description]
                )
            )

            XCTAssertEqual(failure.domain, "InspectorTests")
            XCTAssertEqual(failure.code, 99)
            XCTAssertEqual(failure.message.count, 2048)
            XCTAssertEqual(failure.message, String(description.prefix(2048)))
        }

        private func matches(
            _ transaction: WindshieldTransaction,
            filter: WindshieldTrafficFilter = .all,
            searchText: String = ""
        ) -> Bool {
            WindshieldTransactionQuery.matches(
                transaction,
                filter: filter,
                searchText: searchText
            )
        }

        private func transaction(
            method: String = "GET",
            host: String = "api.example.com",
            statusCode: Int? = nil,
            state: WindshieldTransactionState,
            duration: TimeInterval = 0,
            metricsDuration: TimeInterval? = nil
        ) -> WindshieldTransaction {
            var request = URLRequest(url: URL(string: "https://\(host)/items")!)
            request.httpMethod = method

            let response = statusCode.map {
                WindshieldResponseSnapshot(
                    response: HTTPURLResponse(
                        url: request.url!,
                        statusCode: $0,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )!
                )
            }

            let startedAt = Date(timeIntervalSince1970: 1_000)
            return WindshieldTransaction(
                id: UUID(),
                request: WindshieldRequestSnapshot(
                    request: request,
                    maximumBodyByteCount: 1024
                ),
                response: response,
                state: state,
                startedAt: startedAt,
                endedAt: state == .inFlight
                    ? nil
                    : startedAt.addingTimeInterval(duration),
                networkMetrics: metricsDuration.map(networkMetrics(duration:))
            )
        }

        private func networkMetrics(
            duration: TimeInterval
        ) -> WindshieldNetworkMetrics {
            let start = Date(timeIntervalSince1970: 2_000)
            return WindshieldNetworkMetrics(
                raw: .init(
                    taskStartDate: start,
                    taskEndDate: start.addingTimeInterval(duration)
                )
            )
        }

        private func streamedRequestSnapshot(contentLength: String) -> WindshieldRequestSnapshot {
            var request = URLRequest(url: URL(string: "https://api.example.com/upload")!)
            request.httpBodyStream = InputStream(data: Data([0x01]))
            request.setValue(contentLength, forHTTPHeaderField: "Content-Length")

            return WindshieldRequestSnapshot(
                request: request,
                maximumBodyByteCount: 1024
            )
        }
    }
#endif

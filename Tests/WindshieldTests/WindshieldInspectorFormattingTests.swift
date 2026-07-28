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

        func testBodyFormatterPrettyPrintsJSONWithStableKeyOrder() {
            let body = capture("{\"z\":2,\"a\":1}")

            let result = WindshieldBodyFormatter.format(body)

            XCTAssertTrue(result.contains("\"a\" : 1"))
            XCTAssertTrue(result.contains("\"z\" : 2"))
            XCTAssertLessThan(
                try XCTUnwrap(result.range(of: "\"a\"")).lowerBound,
                try XCTUnwrap(result.range(of: "\"z\"")).lowerBound
            )
        }

        func testBodyFormatterExplainsBinaryEmptyStreamedAndDiscardedBodies() {
            XCTAssertEqual(
                WindshieldBodyFormatter.format(capture("")),
                "No body."
            )
            XCTAssertTrue(
                WindshieldBodyFormatter.format(
                    WindshieldBodyCapture(
                        contents: .bytes(Data([0xFF, 0xD8, 0xFF])),
                        totalByteCount: 3
                    )
                ).contains("Binary body")
            )
            XCTAssertTrue(
                WindshieldBodyFormatter.format(
                    .unavailable(.bodyStream, totalByteCount: 2048)
                ).contains("Streamed request body")
            )
            XCTAssertTrue(
                WindshieldBodyFormatter.format(
                    .unavailable(.discardedByRetentionPolicy, totalByteCount: 4096)
                ).contains("memory limit")
            )
        }

        func testBodyFormatterReportsCaptureAndDisplayLimits() {
            let body = WindshieldBodyCapture(
                contents: .bytes(Data("abcdefgh".utf8)),
                totalByteCount: 16
            )

            let result = WindshieldBodyFormatter.format(body, displayByteLimit: 4)

            XCTAssertTrue(result.hasPrefix("abcd"))
            XCTAssertTrue(result.contains("Captured 8 bytes of 16 bytes"))
            XCTAssertTrue(result.contains("Showing the first 4 bytes"))
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
            statusCode: Int? = nil,
            state: WindshieldTransactionState
        ) -> WindshieldTransaction {
            var request = URLRequest(url: URL(string: "https://api.example.com/items")!)
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

            return WindshieldTransaction(
                id: UUID(),
                request: WindshieldRequestSnapshot(
                    request: request,
                    maximumBodyByteCount: 1024
                ),
                response: response,
                state: state,
                startedAt: Date(),
                endedAt: state == .inFlight ? nil : Date()
            )
        }

        private func capture(_ text: String) -> WindshieldBodyCapture {
            .capture(Data(text.utf8), maximumByteCount: 1024)
        }
    }
#endif

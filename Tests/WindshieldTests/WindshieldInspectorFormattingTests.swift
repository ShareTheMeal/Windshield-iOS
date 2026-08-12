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

        func testBodyFormatterPrettyPrintsJSONArraysWithStableNestedKeyOrder() {
            let body = capture("[{\"z\":2,\"a\":1},3]")

            let result = WindshieldBodyFormatter.format(body)

            XCTAssertTrue(result.hasPrefix("[\n"))
            XCTAssertLessThan(
                try XCTUnwrap(result.range(of: "\"a\"")).lowerBound,
                try XCTUnwrap(result.range(of: "\"z\"")).lowerBound
            )
            XCTAssertTrue(result.contains("  3"))
        }

        func testBodyFormatterPreservesValidJSONScalarsAsReadableText() {
            XCTAssertEqual(WindshieldBodyFormatter.format(capture("42")), "42")
            XCTAssertEqual(WindshieldBodyFormatter.format(capture("true")), "true")
            XCTAssertEqual(
                WindshieldBodyFormatter.format(capture("\"windshield\"")),
                "\"windshield\""
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

        func testBodyFormatterReportsInvalidUTF8AsBinary() {
            let body = WindshieldBodyCapture(
                contents: .bytes(Data([0x66, 0x6F, 0x80])),
                totalByteCount: 3
            )

            XCTAssertEqual(
                WindshieldBodyFormatter.format(body),
                "Binary body, 3 bytes captured."
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

        func testBodyFormatterCompletesACharacterSplitByTheDisplayLimit() {
            let body = capture("abc🙂tail")

            let result = WindshieldBodyFormatter.format(body, displayByteLimit: 5)

            XCTAssertTrue(result.hasPrefix("abc🙂"))
            XCTAssertFalse(result.contains("Binary body"))
            XCTAssertTrue(result.contains("Showing the first 7 bytes"))
        }

        func testBodyFormatterClampsNonpositiveDisplayLimitsToOneByte() {
            let body = capture("abc")
            let oneByteResult = WindshieldBodyFormatter.format(body, displayByteLimit: 1)

            XCTAssertEqual(
                WindshieldBodyFormatter.format(body, displayByteLimit: 0),
                oneByteResult
            )
            XCTAssertEqual(
                WindshieldBodyFormatter.format(body, displayByteLimit: -100),
                oneByteResult
            )
            XCTAssertTrue(oneByteResult.hasPrefix("a"))
            XCTAssertTrue(oneByteResult.contains("Showing the first 1 byte"))
        }

        func testBodyFormatterExplainsMetadataOnlyCapture() {
            let body = WindshieldBodyCapture.unavailable(
                .excludedByCapturePolicy,
                totalByteCount: 4096
            )

            XCTAssertEqual(
                WindshieldBodyFormatter.format(body),
                "Body was not captured by the metadata-only policy. Size: 4 KB."
            )
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

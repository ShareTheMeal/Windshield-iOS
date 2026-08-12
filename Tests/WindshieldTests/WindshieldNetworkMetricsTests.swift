import Foundation
import XCTest

#if DEBUG
    @testable import Windshield

    final class WindshieldNetworkMetricsTests: XCTestCase {
        func testSnapshotsCompletePhasesWithOffsetsRelativeToTaskStart() {
            let metrics = WindshieldNetworkMetrics(
                raw: .init(
                    taskStartDate: date(0),
                    taskEndDate: date(2),
                    redirectCount: 1,
                    attempts: [
                        .init(
                            url: URL(string: "https://api.example.com/items"),
                            domainLookupStartDate: date(0.1),
                            domainLookupEndDate: date(0.2),
                            connectStartDate: date(0.2),
                            connectEndDate: date(0.4),
                            secureConnectionStartDate: date(0.25),
                            secureConnectionEndDate: date(0.35),
                            requestStartDate: date(0.4),
                            requestEndDate: date(0.5),
                            responseStartDate: date(0.8),
                            responseEndDate: date(1.2),
                            requestHeaderBytesSent: 120,
                            requestBodyBytesSent: 40,
                            requestBodyBytesBeforeEncoding: 64,
                            responseHeaderBytesReceived: 80,
                            responseBodyBytesReceived: 1_024,
                            responseBodyBytesAfterDecoding: 2_048,
                            fetchType: .networkLoad,
                            networkProtocolName: "h2",
                            isProxyConnection: true,
                            isReusedConnection: true
                        ),
                    ]
                )
            )

            XCTAssertEqual(metrics.taskInterval, .init(startOffset: 0, duration: 2))
            XCTAssertEqual(metrics.redirectCount, 1)
            XCTAssertEqual(metrics.attempts.count, 1)
            assertInterval(metrics.attempts[0].phases.dns, start: 0.1, duration: 0.1)
            assertInterval(metrics.attempts[0].phases.connect, start: 0.2, duration: 0.2)
            assertInterval(metrics.attempts[0].phases.tls, start: 0.25, duration: 0.1)
            assertInterval(metrics.attempts[0].phases.request, start: 0.4, duration: 0.1)
            assertInterval(metrics.attempts[0].phases.waiting, start: 0.5, duration: 0.3)
            assertInterval(metrics.attempts[0].phases.response, start: 0.8, duration: 0.4)
            XCTAssertEqual(metrics.attempts[0].byteCounts.totalBytesSent, 160)
            XCTAssertEqual(metrics.attempts[0].byteCounts.totalBytesReceived, 1_104)
            XCTAssertEqual(metrics.attempts[0].byteCounts.requestBodyBytesBeforeEncoding, 64)
            XCTAssertEqual(metrics.attempts[0].byteCounts.responseBodyBytesAfterDecoding, 2_048)
            XCTAssertEqual(metrics.attempts[0].fetchType, .networkLoad)
            XCTAssertEqual(metrics.attempts[0].networkProtocolName, "h2")
            XCTAssertTrue(metrics.attempts[0].isProxyConnection)
            XCTAssertTrue(metrics.attempts[0].isReusedConnection)
        }

        func testMissingAndInvertedDatesDoNotCreatePhases() {
            let metrics = WindshieldNetworkMetrics(
                raw: .init(
                    taskStartDate: date(0),
                    taskEndDate: date(1),
                    attempts: [
                        .init(
                            domainLookupStartDate: date(0.2),
                            domainLookupEndDate: nil,
                            connectStartDate: date(0.7),
                            connectEndDate: date(0.6),
                            secureConnectionStartDate: date(-0.1),
                            secureConnectionEndDate: date(0.1),
                            requestStartDate: date(0.2),
                            requestEndDate: date(0.3),
                            responseStartDate: date(0.25),
                            responseEndDate: date(0.4)
                        ),
                    ]
                )
            )

            let phases = try! XCTUnwrap(metrics.attempts.first?.phases)
            XCTAssertNil(phases.dns)
            XCTAssertNil(phases.connect)
            XCTAssertNil(phases.tls)
            assertInterval(phases.request, start: 0.2, duration: 0.1)
            XCTAssertEqual(phases.waiting, nil)
            assertInterval(phases.response, start: 0.25, duration: 0.15)
        }

        func testIncompleteTaskIntervalUsesObservedPhaseFallbackForSlowClassification() {
            let metrics = WindshieldNetworkMetrics(
                raw: .init(
                    taskStartDate: date(10),
                    taskEndDate: nil,
                    attempts: [
                        .init(
                            requestStartDate: date(10.2),
                            requestEndDate: date(10.5),
                            responseStartDate: date(10.5),
                            responseEndDate: date(11.1)
                        ),
                    ]
                )
            )

            XCTAssertNil(metrics.taskDuration)
            XCTAssertEqual(metrics.observedDuration ?? 0, 1.1, accuracy: 0.000_001)
            XCTAssertTrue(metrics.isSlow())
            XCTAssertFalse(metrics.isSlow(threshold: 1.2))
        }

        func testWaitingUsesRequestStartWhenRequestEndIsMissing() {
            let metrics = WindshieldNetworkMetrics(
                raw: .init(
                    taskStartDate: date(0),
                    taskEndDate: date(1),
                    attempts: [
                        .init(
                            requestStartDate: date(0.2),
                            responseStartDate: date(0.7)
                        ),
                    ]
                )
            )

            assertInterval(
                metrics.attempts[0].phases.waiting,
                start: 0.2,
                duration: 0.5
            )
        }

        func testObservedAttemptDurationUsesTheEnvelopeForOverlappingPhases() {
            let metrics = WindshieldNetworkMetrics(
                raw: .init(
                    taskStartDate: date(0),
                    taskEndDate: date(3),
                    attempts: [
                        .init(
                            connectStartDate: date(0.2),
                            connectEndDate: date(1.2),
                            secureConnectionStartDate: date(0.3),
                            secureConnectionEndDate: date(1.0),
                            requestStartDate: date(0.8),
                            requestEndDate: date(1.4)
                        ),
                    ]
                )
            )

            XCTAssertEqual(
                metrics.attempts[0].observedDuration ?? 0,
                1.2,
                accuracy: 0.000_001
            )
        }

        func testRetainsMultipleAttemptsAndTheirNormalizedHosts() {
            let metrics = WindshieldNetworkMetrics(
                raw: .init(
                    taskStartDate: date(0),
                    taskEndDate: date(6),
                    attempts: [
                        attempt(host: "zeta.example.com", start: 0, end: 2),
                        attempt(host: "alpha.example.com", start: 0, end: 2),
                        attempt(host: "beta.example.com", start: 0, end: 1.5),
                        attempt(host: "gamma.example.com", start: 0, end: 1),
                        attempt(host: "alpha.example.com", start: 0, end: 4),
                    ]
                )
            )

            XCTAssertEqual(metrics.attempts.count, 5)
            XCTAssertEqual(
                metrics.attempts.map(\.host),
                [
                    "zeta.example.com",
                    "alpha.example.com",
                    "beta.example.com",
                    "gamma.example.com",
                    "alpha.example.com",
                ]
            )
        }

        private func attempt(
            host: String,
            start: TimeInterval,
            end: TimeInterval
        ) -> WindshieldNetworkMetrics.Raw.Attempt {
            .init(
                url: URL(string: "https://" + host + "/"),
                requestStartDate: date(start),
                requestEndDate: date(end)
            )
        }

        private func date(_ offset: TimeInterval) -> Date {
            Date(timeIntervalSince1970: 1_000 + offset)
        }

        private func assertInterval(
            _ interval: WindshieldNetworkMetrics.Interval?,
            start: TimeInterval,
            duration: TimeInterval,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            guard let interval else {
                return XCTFail("Expected a timing interval.", file: file, line: line)
            }

            XCTAssertEqual(
                interval.startOffset,
                start,
                accuracy: 0.000_001,
                file: file,
                line: line
            )
            XCTAssertEqual(
                interval.duration,
                duration,
                accuracy: 0.000_001,
                file: file,
                line: line
            )
        }
    }
#endif

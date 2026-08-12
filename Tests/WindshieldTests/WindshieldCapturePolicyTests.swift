import Foundation
import XCTest

#if DEBUG
    @testable import Windshield

    final class WindshieldCapturePolicyTests: XCTestCase {
        func testDefaultAndAdditionalHeaderNamesAreRedactedCaseInsensitively() {
            let store = WindshieldCapturePolicyStore(
                options: Windshield.Options(
                    additionalRedactedHeaderNames: [" x-api-key "]
                )
            )

            let plan = store.capturePlan(for: request("https://example.com"))

            XCTAssertTrue(plan.redactedHeaderNames.contains("authorization"))
            XCTAssertTrue(plan.redactedHeaderNames.contains("proxy-authorization"))
            XCTAssertTrue(plan.redactedHeaderNames.contains("cookie"))
            XCTAssertTrue(plan.redactedHeaderNames.contains("set-cookie"))
            XCTAssertTrue(plan.redactedHeaderNames.contains("x-api-key"))
        }

        func testIgnoredHostsMatchExactlyAfterCaseAndTrailingDotNormalization() {
            let store = WindshieldCapturePolicyStore(
                options: Windshield.Options(
                    ignoredHosts: [" Metrics.Example.COM. "]
                )
            )

            XCTAssertFalse(
                store.capturePlan(for: request("https://metrics.example.com/events"))
                    .recordsTransaction
            )
            XCTAssertTrue(
                store.capturePlan(for: request("https://child.metrics.example.com/events"))
                    .recordsTransaction
            )
            XCTAssertTrue(
                store.capturePlan(for: request("https://notmetrics.example.com/events"))
                    .recordsTransaction
            )
        }

        func testURLRuleMatchesHostPathMethodAndExplicitSubdomains() {
            let store = WindshieldCapturePolicyStore(
                options: Windshield.Options(
                    ignoredURLRules: [
                        .init(
                            host: "api.example.com",
                            pathPrefix: "private",
                            httpMethods: [" post "],
                            includesSubdomains: true
                        ),
                    ]
                )
            )

            XCTAssertFalse(
                store.capturePlan(
                    for: request(
                        "https://api.example.com/private/items",
                        method: "POST"
                    )
                ).recordsTransaction
            )
            XCTAssertFalse(
                store.capturePlan(
                    for: request(
                        "https://edge.api.example.com/private/items",
                        method: "post"
                    )
                ).recordsTransaction
            )
            XCTAssertTrue(
                store.capturePlan(
                    for: request(
                        "https://api.example.com/private/items",
                        method: "GET"
                    )
                ).recordsTransaction
            )
            XCTAssertTrue(
                store.capturePlan(
                    for: request(
                        "https://api.example.com/public/items",
                        method: "POST"
                    )
                ).recordsTransaction
            )
            XCTAssertTrue(
                store.capturePlan(
                    for: request(
                        "https://notapi.example.com/private/items",
                        method: "POST"
                    )
                ).recordsTransaction
            )
        }

        func testMetadataOnlyRulesDoNotAffectUnmatchedRequests() {
            let store = WindshieldCapturePolicyStore(
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

            XCTAssertEqual(
                store.capturePlan(
                    for: request(
                        "https://api.example.com/payments/confirm",
                        method: "POST"
                    )
                ).bodyCapture,
                .metadataOnly
            )
            XCTAssertEqual(
                store.capturePlan(
                    for: request(
                        "https://api.example.com/payments/confirm",
                        method: "GET"
                    )
                ).bodyCapture,
                .full
            )
            XCTAssertEqual(
                store.capturePlan(
                    for: request(
                        "https://other.example.com/payments/confirm",
                        method: "POST"
                    )
                ).bodyCapture,
                .full
            )
        }

        func testIgnoreTakesPrecedenceOverMetadataOnlyForTheSameRequest() {
            let rule = Windshield.URLRule(
                host: "api.example.com",
                pathPrefix: "/private"
            )
            let store = WindshieldCapturePolicyStore(
                options: Windshield.Options(
                    ignoredURLRules: [rule],
                    metadataOnlyURLRules: [rule]
                )
            )

            let plan = store.capturePlan(
                for: request("https://api.example.com/private/items")
            )

            XCTAssertFalse(plan.recordsTransaction)
        }

        func testConcurrentReconfigurationReturnsOnlyCompletePolicySnapshots() {
            let request = request(
                "https://api.example.com/private/items",
                method: "POST"
            )
            let ignoredOptions = Windshield.Options(
                additionalRedactedHeaderNames: ["X-Policy-A"],
                ignoredHosts: ["api.example.com"]
            )
            let metadataOptions = Windshield.Options(
                additionalRedactedHeaderNames: ["X-Policy-B"],
                metadataOnlyURLRules: [
                    .init(
                        host: "api.example.com",
                        pathPrefix: "/private",
                        httpMethods: ["POST"]
                    ),
                ]
            )
            let ignoredPlan = WindshieldCapturePolicyStore(options: ignoredOptions)
                .capturePlan(for: request)
            let metadataPlan = WindshieldCapturePolicyStore(options: metadataOptions)
                .capturePlan(for: request)
            let store = WindshieldCapturePolicyStore(options: ignoredOptions)
            let invalidPlans = InvalidPlanCounter()

            DispatchQueue.concurrentPerform(iterations: 500) { index in
                store.configure(options: index.isMultiple(of: 2) ? ignoredOptions : metadataOptions)
                let plan = store.capturePlan(for: request)
                if plan != ignoredPlan, plan != metadataPlan {
                    invalidPlans.increment()
                }
            }

            XCTAssertEqual(invalidPlans.value, 0)
        }

        private func request(_ url: String, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = method
            return request
        }
    }

    private final class InvalidPlanCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue = 0

        var value: Int {
            lock.lock()
            let value = storedValue
            lock.unlock()
            return value
        }

        func increment() {
            lock.lock()
            storedValue += 1
            lock.unlock()
        }
    }
#endif

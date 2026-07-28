import Foundation
import XCTest

#if DEBUG
    @testable import Windshield

    final class WindshieldAPITests: XCTestCase {
        func testStartPrependsTheProtocolWithoutDuplicatingIt() {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [
                URLProtocolStub.self,
                WindshieldURLProtocol.self,
            ]

            Windshield.start(intercepting: configuration)

            let protocolClasses = configuration.protocolClasses ?? []
            XCTAssertEqual(protocolClasses.count, 2)
            XCTAssertTrue(protocolClasses.first == WindshieldURLProtocol.self)
            XCTAssertTrue(protocolClasses.last == URLProtocolStub.self)
        }

        func testStartLeavesBackgroundConfigurationUnchanged() {
            let configuration = URLSessionConfiguration.background(
                withIdentifier: "dev.windshield.tests.background"
            )
            let originalClasses = configuration.protocolClasses
            let registration = ProtocolRegistrationSpy()
            let runtime = runtime(registration: registration)

            runtime.start(intercepting: configuration, maximumTransactionCount: 10)

            XCTAssertEqual(
                configuration.protocolClasses?.map(ObjectIdentifier.init),
                originalClasses?.map(ObjectIdentifier.init)
            )
            XCTAssertEqual(registration.callCount, 0)
        }

        func testTargetedStartDoesNotRegisterTheProtocolGlobally() {
            let configuration = URLSessionConfiguration.ephemeral
            let registration = ProtocolRegistrationSpy()
            let runtime = runtime(registration: registration)

            runtime.start(intercepting: configuration, maximumTransactionCount: 10)

            XCTAssertTrue(configuration.protocolClasses?.first == WindshieldURLProtocol.self)
            XCTAssertEqual(registration.callCount, 0)
        }

        func testGlobalStartRegistersOnlyOnceAfterSuccess() {
            let registration = ProtocolRegistrationSpy()
            let runtime = runtime(registration: registration)

            runtime.startGlobally(maximumTransactionCount: 10)
            runtime.startGlobally(maximumTransactionCount: 20)

            XCTAssertEqual(registration.callCount, 1)
        }

        func testGlobalStartRetriesAfterRegistrationFailure() {
            let registration = ProtocolRegistrationSpy(results: [false, true])
            let runtime = runtime(registration: registration)

            runtime.startGlobally(maximumTransactionCount: 10)
            runtime.startGlobally(maximumTransactionCount: 10)

            XCTAssertEqual(registration.callCount, 2)
        }

        private func runtime(
            registration: ProtocolRegistrationSpy
        ) -> WindshieldRuntime {
            WindshieldRuntime(
                registerProtocol: { registration.register() },
                applyRetentionLimit: { _ in }
            )
        }
    }

    private final class ProtocolRegistrationSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Bool]
        private var storedCallCount = 0

        var callCount: Int {
            lock.lock()
            let count = storedCallCount
            lock.unlock()
            return count
        }

        init(results: [Bool] = [true]) {
            self.results = results
        }

        func register() -> Bool {
            lock.lock()
            let result = results[min(storedCallCount, results.count - 1)]
            storedCallCount += 1
            lock.unlock()
            return result
        }
    }

    private final class URLProtocolStub: URLProtocol {
        override class func canInit(with _: URLRequest) -> Bool {
            false
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {}

        override func stopLoading() {}
    }
#endif

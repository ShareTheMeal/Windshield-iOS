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
            let diagnostics = DiagnosticSpy()
            let runtime = runtime(
                registration: registration,
                diagnostics: diagnostics
            )

            runtime.start(intercepting: configuration, maximumTransactionCount: 10)

            XCTAssertEqual(
                configuration.protocolClasses?.map(ObjectIdentifier.init),
                originalClasses?.map(ObjectIdentifier.init)
            )
            XCTAssertEqual(registration.callCount, 0)
            XCTAssertEqual(
                diagnostics.messages,
                ["[Windshield] Background URL sessions cannot use custom URL protocols"]
            )
        }

        func testTargetedStartDoesNotRegisterTheProtocolGlobally() {
            let configuration = URLSessionConfiguration.ephemeral
            let registration = ProtocolRegistrationSpy()
            let runtime = runtime(registration: registration)

            runtime.start(intercepting: configuration, maximumTransactionCount: 10)

            XCTAssertTrue(configuration.protocolClasses?.first == WindshieldURLProtocol.self)
            XCTAssertEqual(registration.callCount, 0)
        }

        func testSuccessfulTargetedStartEmitsNoConsoleDiagnostic() {
            let registration = ProtocolRegistrationSpy()
            let diagnostics = DiagnosticSpy()
            let runtime = runtime(
                registration: registration,
                diagnostics: diagnostics
            )

            runtime.start(
                intercepting: URLSessionConfiguration.ephemeral,
                maximumTransactionCount: 10
            )

            XCTAssertTrue(diagnostics.messages.isEmpty)
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
            let diagnostics = DiagnosticSpy()
            let runtime = runtime(
                registration: registration,
                diagnostics: diagnostics
            )

            runtime.startGlobally(maximumTransactionCount: 10)
            runtime.startGlobally(maximumTransactionCount: 10)

            XCTAssertEqual(registration.callCount, 2)
            XCTAssertEqual(
                diagnostics.messages,
                ["[Windshield] Global URLProtocol registration failed"]
            )
        }

        func testConcurrentGlobalStartRegistersTheProtocolExactlyOnce() {
            let registration = ProtocolRegistrationSpy()
            let retention = RetentionLimitSpy()
            let runtime = runtime(
                registration: registration,
                retention: retention
            )

            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                runtime.startGlobally(maximumTransactionCount: 25)
            }

            XCTAssertEqual(registration.callCount, 1)
            XCTAssertEqual(retention.values.count, 64)
            XCTAssertTrue(retention.values.allSatisfy { $0 == 25 })
        }

        func testConcurrentPublicTargetedStartInstrumentsIndependentConfigurations() async {
            let instrumentation = InstrumentationResultSpy()

            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                let configuration = URLSessionConfiguration.ephemeral
                Windshield.start(
                    intercepting: configuration,
                    maximumTransactions: 25
                )
                instrumentation.record(
                    configuration.protocolClasses?.first == WindshieldURLProtocol.self
                )
            }

            XCTAssertEqual(instrumentation.results.count, 64)
            XCTAssertTrue(instrumentation.results.allSatisfy { $0 })

            let recorder = WindshieldTransactionRecorder.shared
            await recorder.flush()
            recorder.configure(
                maximumTransactionCount: WindshieldRetentionPolicy.defaultMaximumTransactionCount
            )
            await recorder.flush()
        }

        func testTargetedStartForwardsInvalidRetentionLimitToThePolicyLayer() {
            let registration = ProtocolRegistrationSpy()
            let retention = RetentionLimitSpy()
            let runtime = runtime(
                registration: registration,
                retention: retention
            )

            runtime.start(
                intercepting: URLSessionConfiguration.ephemeral,
                maximumTransactionCount: -10
            )

            XCTAssertEqual(retention.values, [-10])
        }

        private func runtime(
            registration: ProtocolRegistrationSpy,
            retention: RetentionLimitSpy? = nil,
            diagnostics: DiagnosticSpy? = nil
        ) -> WindshieldRuntime {
            WindshieldRuntime(
                registerProtocol: { registration.register() },
                applyRetentionLimit: { value in retention?.apply(value) },
                emitDiagnostic: { message in diagnostics?.emit(message) }
            )
        }
    }

    private final class DiagnosticSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var storedMessages: [String] = []

        var messages: [String] {
            lock.lock()
            let messages = storedMessages
            lock.unlock()
            return messages
        }

        func emit(_ message: String) {
            lock.lock()
            storedMessages.append(message)
            lock.unlock()
        }
    }

    private final class RetentionLimitSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValues: [Int] = []

        var values: [Int] {
            lock.lock()
            let values = storedValues
            lock.unlock()
            return values
        }

        func apply(_ value: Int) {
            lock.lock()
            storedValues.append(value)
            lock.unlock()
        }
    }

    private final class InstrumentationResultSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var storedResults: [Bool] = []

        var results: [Bool] {
            lock.lock()
            let results = storedResults
            lock.unlock()
            return results
        }

        func record(_ result: Bool) {
            lock.lock()
            storedResults.append(result)
            lock.unlock()
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

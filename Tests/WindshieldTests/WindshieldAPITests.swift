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

            Windshield.start(intercepting: configuration)

            XCTAssertEqual(
                configuration.protocolClasses?.map(ObjectIdentifier.init),
                originalClasses?.map(ObjectIdentifier.init)
            )
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

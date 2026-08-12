import XCTest

#if DEBUG && os(iOS)
    import UIKit
    @testable import Windshield

    @MainActor
    final class WindshieldPayloadInspectorTests: XCTestCase {
        func testSafeImageThumbnailReadsDimensionsAndBoundsRenderedPixels() throws {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: 80, height: 40),
                format: format
            )
            let data = renderer.pngData { context in
                UIColor.systemBlue.setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            }

            switch WindshieldSafeImageThumbnail.make(from: data) {
            case let .success(thumbnail):
                XCTAssertEqual(thumbnail.sourceWidth, 80)
                XCTAssertEqual(thumbnail.sourceHeight, 40)
                XCTAssertLessThanOrEqual(thumbnail.image.width, 1_600)
                XCTAssertLessThanOrEqual(thumbnail.image.height, 1_600)
            case let .failure(message):
                XCTFail("Expected a thumbnail, received: \(message)")
            }
        }

        func testSafeImageThumbnailRejectsInvalidBytes() {
            switch WindshieldSafeImageThumbnail.make(from: Data([0x00, 0x01])) {
            case .success:
                XCTFail("Invalid bytes must not produce an image preview.")
            case .failure:
                break
            }
        }

        func testSafeImageThumbnailRejectsUnsafeDecodedDimensions() {
            XCTAssertTrue(
                WindshieldSafeImageThumbnail.isSourceSizeSafe(
                    width: 4_000,
                    height: 4_000
                )
            )
            XCTAssertFalse(
                WindshieldSafeImageThumbnail.isSourceSizeSafe(
                    width: 16_385,
                    height: 1
                )
            )
            XCTAssertFalse(
                WindshieldSafeImageThumbnail.isSourceSizeSafe(
                    width: 8_000,
                    height: 8_000
                )
            )
        }
    }
#endif

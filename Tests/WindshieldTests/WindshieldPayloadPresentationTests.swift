import Foundation
import XCTest

#if DEBUG
    @testable import Windshield

    final class WindshieldPayloadPresentationTests: XCTestCase {
        override func tearDown() {
            for id in registeredDecoderIDs {
                Windshield.removePayloadDecoder(id: id)
            }
            registeredDecoderIDs.removeAll()
            super.tearDown()
        }

        func testNormalizesParametersAndClassifiesJSONAndXMLSuffixes() {
            XCTAssertEqual(
                WindshieldMIMEType.normalize(" Application/Problem+JSON ; charset=utf-8 "),
                "application/problem+json"
            )
            XCTAssertEqual(
                present("<entry />", contentType: "application/atom+xml; charset=UTF-8").kind,
                .xml
            )
            XCTAssertEqual(
                present("{}", contentType: "application/vnd.example+json; charset=utf-8").kind,
                .json
            )
        }

        func testInvalidJSONKeepsItsJSONClassificationAndReadableText() {
            let presentation = present("{not-json", contentType: "application/json")

            XCTAssertEqual(presentation.kind, .json)
            XCTAssertEqual(presentation.text, "{not-json")
        }

        func testJSONPresentationPrettyPrintsWithStableNestedKeyOrder() throws {
            let presentation = present(
                "[{\"z\":2,\"a\":1},3]",
                contentType: "application/json"
            )
            let text = try XCTUnwrap(presentation.text)

            XCTAssertTrue(text.hasPrefix("[\n"))
            XCTAssertLessThan(
                try XCTUnwrap(text.range(of: "\"a\"")).lowerBound,
                try XCTUnwrap(text.range(of: "\"z\"")).lowerBound
            )
            XCTAssertTrue(text.contains("  3"))
        }

        func testEmptyBodyIsPresentedExplicitly() {
            XCTAssertEqual(
                presentation(data: Data(), contentType: "text/plain").text,
                "No body."
            )
        }

        func testFormPresentationDecodesPlusEscapesEmptyValuesAndRepeatedKeys() {
            let presentation = present(
                "name=Ada+Lovelace&flag&empty=&item=one&item=two&bad=%ZZ",
                contentType: "application/x-www-form-urlencoded"
            )

            XCTAssertEqual(presentation.kind, .form)
            XCTAssertEqual(
                presentation.text,
                "name = Ada Lovelace\nflag = \nempty = \nitem = one\nitem = two\nbad = %ZZ"
            )
        }

        func testMultipartSummaryCountsPartsWithoutExposingValuesOrFilenames() {
            let body = """
            --abc\r
            Content-Disposition: form-data; name=\"token\"\r
            \r
            top-secret\r
            --abc\r
            Content-Disposition: form-data; name=\"upload\"; filename=\"private.png\"\r
            \r
            bytes\r
            --abc--\r
            """

            let presentation = present(
                body,
                contentType: "multipart/form-data; boundary=abc"
            )

            XCTAssertEqual(presentation.kind, .multipart)
            XCTAssertEqual(
                presentation.text,
                "Multipart form data: 2 parts, 1 file part. Part contents and filenames are hidden for privacy."
            )
            XCTAssertFalse(presentation.text?.contains("top-secret") == true)
            XCTAssertFalse(presentation.text?.contains("private.png") == true)
        }

        func testCustomDecodersCannotOverrideMultipartOrImageSafetyHandling() {
            registerDecoder(
                id: "unsafe-multipart",
                contentTypes: ["multipart/form-data"]
            ) { _ in
                XCTFail("Multipart bytes must not reach a custom decoder.")
                return .init(text: "unsafe")
            }
            registerDecoder(id: "unsafe-image", contentTypes: ["image/png"]) { _ in
                XCTFail("Image bytes must not reach a custom decoder.")
                return .init(text: "unsafe")
            }

            let multipart = present(
                "--abc--\r\n",
                contentType: "multipart/form-data; boundary=abc"
            )
            let image = presentation(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                contentType: "image/png"
            )

            XCTAssertEqual(multipart.kind, .multipart)
            XCTAssertEqual(image.kind, .image)
        }

        func testRedactedContentTypeFailsClosedWithoutRenderingOrDecodingBody() {
            registerDecoder(id: "redacted", contentTypes: ["application/json"]) { _ in
                XCTFail("A body with redacted MIME metadata must not reach a decoder.")
                return .init(text: "unsafe")
            }
            let secret = "--abc\r\nprivate-value\r\n--abc--\r\n"

            let presentation = present(
                secret,
                contentType: WindshieldHeader.redactedValue
            )

            XCTAssertEqual(presentation.kind, .binary)
            XCTAssertNil(presentation.mimeType)
            XCTAssertNil(presentation.customDecoderID)
            XCTAssertFalse(presentation.text?.contains("private-value") == true)
            XCTAssertTrue(presentation.text?.contains("Content-Type was redacted") == true)
        }

        func testJavaScriptAndGraphQLAreClassifiedAsText() {
            XCTAssertEqual(
                present("const answer = 42", contentType: "application/javascript").kind,
                .text
            )
            XCTAssertEqual(
                present("query { viewer { id } }", contentType: "application/graphql").kind,
                .text
            )
        }

        func testOnlyExplicitImageMIMETypesProduceImagePayloads() {
            let imageData = Data([0x89, 0x50, 0x4E, 0x47])
            let image = presentation(data: imageData, contentType: "image/png")
            let unknown = presentation(data: imageData, contentType: nil)

            XCTAssertEqual(image.kind, .image)
            XCTAssertEqual(image.image, .init(mimeType: "image/png", data: imageData))
            XCTAssertNil(image.text)
            XCTAssertEqual(unknown.kind, .binary)
            XCTAssertNil(unknown.image)
        }

        func testKnownBinaryAndUnavailableBodiesAreExplicit() {
            let binary = present("readable", contentType: "application/pdf")
            let unavailable = WindshieldPayloadPresentation.present(
                .unavailable(.excludedByCapturePolicy, totalByteCount: 7),
                contentType: "application/json"
            )

            XCTAssertEqual(binary.kind, .binary)
            XCTAssertEqual(binary.text, "Binary body, 8 bytes captured.")
            XCTAssertEqual(unavailable.kind, .unavailable)
            XCTAssertTrue(unavailable.text?.contains("metadata-only") == true)
        }

        func testLargeBinarySummaryUsesTheCapturedByteCount() {
            let data = Data(repeating: 0xFF, count: 256 * 1024)

            let known = presentation(data: data, contentType: "application/octet-stream")
            let unknown = presentation(data: data, contentType: nil)

            XCTAssertEqual(known.text, "Binary body, 262144 bytes captured.")
            XCTAssertEqual(unknown.text, "Binary body, 262144 bytes captured.")
        }

        func testUnknownMIMEFallsBackToJSONThenUTF8ThenBinary() {
            XCTAssertEqual(present("{\"b\":2,\"a\":1}", contentType: nil).kind, .json)
            XCTAssertEqual(present("plain text", contentType: nil).kind, .text)
            XCTAssertEqual(
                presentation(data: Data([0xFF]), contentType: nil).kind,
                .binary
            )
        }

        func testCaptureAndDisplayTruncationNoticesAreDistinctAndUnicodeSafe() {
            let body = WindshieldBodyCapture(
                contents: .bytes(Data("abc🙂tail".utf8)),
                totalByteCount: 30
            )
            let presentation = WindshieldPayloadPresentation.present(
                body,
                contentType: "text/plain",
                displayByteLimit: 5
            )

            XCTAssertEqual(presentation.text, "abc")
            XCTAssertEqual(
                presentation.notices,
                [
                    .captureTruncated(capturedByteCount: 11, totalByteCount: 30),
                    .displayTruncated(displayedByteCount: 3, capturedByteCount: 11),
                ]
            )
        }

        func testFormattedJSONOutputRemainsWithinTheDisplayLimit() {
            let presentation = WindshieldPayloadPresentation.present(
                WindshieldBodyCapture(
                    contents: .bytes(Data("{\"alpha\":1,\"beta\":2}".utf8)),
                    totalByteCount: 20
                ),
                contentType: "application/json",
                displayByteLimit: 30
            )

            XCTAssertLessThanOrEqual(
                presentation.text?.lengthOfBytes(using: .utf8) ?? .max,
                30
            )
            XCTAssertTrue(presentation.notices.contains { notice in
                if case .formattedOutputTruncated = notice { return true }
                return false
            })
        }

        func testDeepCompactJSONSkipsPrettyPrintingBeforeLargeExpansion() {
            let depth = 500
            let json = String(repeating: "[", count: depth)
                + String(repeating: "0,", count: 60_000)
                + "0"
                + String(repeating: "]", count: depth)
            XCTAssertLessThan(
                json.lengthOfBytes(using: .utf8),
                WindshieldPayloadPresentation.defaultDisplayByteLimit
            )

            let presentation = present(json, contentType: "application/json")

            XCTAssertEqual(presentation.kind, .json)
            XCTAssertEqual(presentation.text, json)
            XCTAssertTrue(presentation.notices.contains { notice in
                if case .jsonFormattingSkipped = notice { return true }
                return false
            })
        }

        func testBodySearchProducesDeterministicUnicodeSafeUTF16Ranges() throws {
            let text = "🙂 Café café"
            let matches = WindshieldPayloadTextSearch.matches(in: text, query: "CAFE")

            XCTAssertEqual(matches.map(\.utf16Range), [3 ..< 7, 8 ..< 12])
            XCTAssertEqual(matches.compactMap { match in
                match.stringRange(in: text).map { String(text[$0]) }
            }, ["Café", "café"])
        }

        func testBodySearchHonorsItsWorkLimit() {
            let matches = WindshieldPayloadTextSearch.matches(
                in: "aaaaaa",
                query: "a",
                limit: 3
            )

            XCTAssertEqual(matches.map(\.utf16Range), [0 ..< 1, 1 ..< 2, 2 ..< 3])
            XCTAssertTrue(
                WindshieldPayloadTextSearch.matches(
                    in: "aaaaaa",
                    query: "a",
                    limit: 0
                ).isEmpty
            )
        }

        func testCustomDecodersUseOrderedExactMIMETypesAndReplacementInPlace() {
            registerDecoder(id: "first", contentTypes: ["application/x-windshield"]) { _ in
                .init(text: "first")
            }
            registerDecoder(id: "second", contentTypes: ["application/x-windshield"]) { _ in
                .init(text: "second")
            }
            XCTAssertEqual(
                present("body", contentType: "application/x-windshield; charset=utf-8").text,
                "first"
            )

            registerDecoder(id: "first", contentTypes: ["application/x-windshield"]) { _ in
                .init(text: "replacement")
            }
            XCTAssertEqual(
                present("body", contentType: "application/x-windshield").text,
                "replacement"
            )
        }

        func testRemovingCustomDecoderRestoresBuiltinFallback() {
            registerDecoder(id: "json", contentTypes: ["application/json"]) { _ in
                .init(text: "custom")
            }
            XCTAssertEqual(present("{}", contentType: "application/json").kind, .custom)

            Windshield.removePayloadDecoder(id: "json")
            registeredDecoderIDs.removeAll { $0 == "json" }

            let fallback = present("{}", contentType: "application/json")
            XCTAssertEqual(fallback.kind, .json)
            XCTAssertTrue(fallback.text?.contains("{") == true)
        }

        func testNilCustomDecoderResultFallsBackToBuiltinPresentation() {
            registerDecoder(id: "nil-json", contentTypes: ["application/json"]) { _ in
                nil
            }

            let fallback = present("{\"value\":1}", contentType: "application/json")

            XCTAssertEqual(fallback.kind, .json)
            XCTAssertNil(fallback.customDecoderID)
            XCTAssertTrue(fallback.text?.contains("\"value\" : 1") == true)
        }

        func testCustomDecoderInputAndOutputAreBounded() {
            let input = String(repeating: "a", count: WindshieldPayloadPresentation.defaultDisplayByteLimit + 1)
            registerDecoder(id: "caps", contentTypes: ["application/x-caps"]) { received in
                XCTAssertEqual(
                    received.body.count,
                    WindshieldPayloadPresentation.defaultDisplayByteLimit
                )
                return .init(text: String(repeating: "🙂", count: 40_000))
            }

            let result = present(input, contentType: "application/x-caps")

            XCTAssertEqual(result.kind, .custom)
            XCTAssertLessThanOrEqual(
                result.text?.lengthOfBytes(using: .utf8) ?? .max,
                WindshieldPayloadPresentation.defaultDisplayByteLimit
            )
            XCTAssertTrue(result.notices.contains { notice in
                if case .decoderInputTruncated = notice { return true }
                return false
            })
            XCTAssertTrue(result.notices.contains { notice in
                if case .decoderOutputTruncated = notice { return true }
                return false
            })
        }

        func testConcurrentDecoderChangesRemainSafeAndReturnWholePresentations() {
            let invalidResultCount = LockedCounter()
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "WindshieldPayloadPresentationTests", attributes: .concurrent)
            registerDecoder(id: "concurrent-baseline", contentTypes: ["application/x-concurrent"]) { _ in
                .init(text: "baseline")
            }
            let body = WindshieldBodyCapture(
                contents: .bytes(Data("body".utf8)),
                totalByteCount: 4
            )

            for index in 0 ..< 200 {
                group.enter()
                queue.async {
                    let id = "concurrent-\(index % 3)"
                    Windshield.registerPayloadDecoder(
                        .init(id: id, contentTypes: ["application/x-concurrent"]) { _ in
                            .init(text: id)
                        }
                    )
                    let result = WindshieldPayloadPresentation.present(
                        body,
                        contentType: "application/x-concurrent"
                    )
                    if result.kind != .custom || result.text == nil {
                        invalidResultCount.increment()
                    }
                    Windshield.removePayloadDecoder(id: id)
                    group.leave()
                }
            }

            group.wait()
            XCTAssertEqual(invalidResultCount.value, 0)
        }

        private var registeredDecoderIDs: [String] = []

        private func registerDecoder(
            id: String,
            contentTypes: Set<String>,
            decode: @escaping @Sendable (Windshield.PayloadDecoder.Input) -> Windshield.PayloadDecoder.Output?
        ) {
            registeredDecoderIDs.append(id)
            Windshield.registerPayloadDecoder(
                .init(id: id, contentTypes: contentTypes, decode: decode)
            )
        }

        private func present(_ text: String, contentType: String?) -> WindshieldPayloadPresentation {
            presentation(data: Data(text.utf8), contentType: contentType)
        }

        private func presentation(data: Data, contentType: String?) -> WindshieldPayloadPresentation {
            WindshieldPayloadPresentation.present(
                WindshieldBodyCapture(contents: .bytes(data), totalByteCount: data.count),
                contentType: contentType
            )
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }

        func increment() {
            lock.lock()
            storedValue += 1
            lock.unlock()
        }
    }
#endif

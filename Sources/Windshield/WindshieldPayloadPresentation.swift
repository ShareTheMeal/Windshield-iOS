import Foundation

#if DEBUG
    /// A presentation-ready description of a captured HTTP body.
    ///
    /// This type only interprets an already-recorded snapshot. It never receives a
    /// live request, response, URL, or headers, so presentation and custom decoders
    /// cannot influence the host application's networking.
    struct WindshieldPayloadPresentation: Sendable, Equatable {
        static let defaultDisplayByteLimit = 128 * 1024

        enum Kind: String, Sendable, Equatable {
            case json
            case html
            case xml
            case text
            case form
            case multipart
            case image
            case binary
            case unavailable
            case custom
        }

        enum Notice: Sendable, Equatable {
            case captureTruncated(capturedByteCount: Int, totalByteCount: Int)
            case displayTruncated(displayedByteCount: Int, capturedByteCount: Int)
            case formattedOutputTruncated(displayedByteCount: Int, formattedByteCount: Int)
            case jsonFormattingSkipped(displayByteLimit: Int)
            case decoderInputTruncated(inputByteCount: Int, capturedByteCount: Int)
            case decoderOutputTruncated(displayedByteCount: Int, decodedByteCount: Int)
        }

        struct Image: Sendable, Equatable {
            let mimeType: String
            let data: Data
        }

        let kind: Kind
        let mimeType: String?
        let text: String?
        let image: Image?
        let notices: [Notice]
        let customDecoderID: String?

        static func present(
            _ body: WindshieldBodyCapture?,
            contentType: String?,
            displayByteLimit: Int = defaultDisplayByteLimit
        ) -> WindshieldPayloadPresentation {
            guard let body else {
                return WindshieldPayloadPresentation(
                    kind: .unavailable,
                    mimeType: WindshieldMIMEType.normalize(contentType),
                    text: "Waiting for response body.",
                    image: nil,
                    notices: [],
                    customDecoderID: nil
                )
            }

            let mime = WindshieldMIMEType(contentType)
            switch body.contents {
            case let .unavailable(reason):
                return WindshieldPayloadPresentation(
                    kind: .unavailable,
                    mimeType: mime?.normalized,
                    text: unavailableText(reason, totalByteCount: body.totalByteCount),
                    image: nil,
                    notices: [],
                    customDecoderID: nil
                )

            case let .bytes(data):
                if contentType?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == WindshieldHeader.redactedValue
                {
                    return WindshieldPayloadPresentation(
                        kind: .binary,
                        mimeType: nil,
                        text: "Body preview hidden because Content-Type was redacted. "
                            + "\(data.count) bytes captured.",
                        image: nil,
                        notices: captureNotices(
                            capturedByteCount: data.count,
                            totalByteCount: body.totalByteCount
                        ),
                        customDecoderID: nil
                    )
                }

                return presentBytes(
                    data,
                    totalByteCount: body.totalByteCount,
                    mime: mime,
                    displayByteLimit: max(1, displayByteLimit)
                )
            }
        }

        private static func presentBytes(
            _ data: Data,
            totalByteCount: Int?,
            mime: WindshieldMIMEType?,
            displayByteLimit: Int
        ) -> WindshieldPayloadPresentation {
            var notices = captureNotices(
                capturedByteCount: data.count,
                totalByteCount: totalByteCount
            )

            // Image previews and multipart privacy summaries are mandatory built-ins.
            // Custom decoders cannot bypass their safety boundaries.
            if let mime, mime.isImage {
                return WindshieldPayloadPresentation(
                    kind: .image,
                    mimeType: mime.normalized,
                    text: nil,
                    image: Image(mimeType: mime.normalized, data: data),
                    notices: notices,
                    customDecoderID: nil
                )
            }

            if let mime,
               !mime.isMultipartFormData,
               let decoder = WindshieldPayloadDecoderRegistry.shared.decoder(
                   for: mime.normalized
               )
            {
                let input = limitedData(data, byteLimit: defaultDisplayByteLimit)
                if input.data.count < data.count {
                    notices.append(
                        .decoderInputTruncated(
                            inputByteCount: input.data.count,
                            capturedByteCount: data.count
                        )
                    )
                }

                if let output = decoder.decode(
                    .init(contentType: mime.normalized, body: input.data)
                ) {
                    let boundedText = boundedText(
                        output.text,
                        byteLimit: defaultDisplayByteLimit
                    )
                    if boundedText.wasTruncated {
                        notices.append(
                            .decoderOutputTruncated(
                                displayedByteCount: boundedText.text.lengthOfBytes(
                                    using: .utf8
                                ),
                                decodedByteCount: output.text.lengthOfBytes(using: .utf8)
                            )
                        )
                    }
                    return WindshieldPayloadPresentation(
                        kind: .custom,
                        mimeType: mime.normalized,
                        text: boundedText.text,
                        image: nil,
                        notices: notices,
                        customDecoderID: decoder.id
                    )
                }
            }

            let displayed = limitedData(data, byteLimit: displayByteLimit)
            if displayed.data.count < data.count {
                notices.append(
                    .displayTruncated(
                        displayedByteCount: displayed.data.count,
                        capturedByteCount: data.count
                    )
                )
            }

            guard !data.isEmpty else {
                return WindshieldPayloadPresentation(
                    kind: .text,
                    mimeType: mime?.normalized,
                    text: "No body.",
                    image: nil,
                    notices: notices,
                    customDecoderID: nil
                )
            }

            if let mime {
                return presentKnownMIME(
                    mime,
                    data: displayed.data,
                    capturedByteCount: data.count,
                    displayByteLimit: displayByteLimit,
                    notices: notices
                )
            }

            return presentUnknownMIME(
                data: displayed.data,
                capturedByteCount: data.count,
                displayByteLimit: displayByteLimit,
                notices: notices
            )
        }

        private static func presentKnownMIME(
            _ mime: WindshieldMIMEType,
            data: Data,
            capturedByteCount: Int,
            displayByteLimit: Int,
            notices: [Notice]
        ) -> WindshieldPayloadPresentation {
            if mime.isJSON {
                var jsonNotices = notices
                let text: String
                switch formattedJSON(data, displayByteLimit: displayByteLimit) {
                case let .formatted(prettyJSON):
                    text = prettyJSON
                case .skipped:
                    text = String(data: data, encoding: .utf8)
                        ?? binaryText(capturedByteCount)
                    jsonNotices.append(
                        .jsonFormattingSkipped(displayByteLimit: displayByteLimit)
                    )
                case .invalid:
                    text = String(data: data, encoding: .utf8)
                        ?? binaryText(capturedByteCount)
                }

                return textPresentation(
                    kind: .json,
                    mime: mime.normalized,
                    text: text,
                    displayByteLimit: displayByteLimit,
                    notices: jsonNotices
                )
            }

            if mime.isFormURLEncoded {
                return textPresentation(
                    kind: .form,
                    mime: mime.normalized,
                    text: formattedForm(data),
                    displayByteLimit: displayByteLimit,
                    notices: notices
                )
            }

            if mime.isMultipartFormData {
                return textPresentation(
                    kind: .multipart,
                    mime: mime.normalized,
                    text: multipartSummary(data, boundary: mime.parameter(named: "boundary")),
                    displayByteLimit: nil,
                    notices: notices
                )
            }

            if mime.isHTML {
                return textPresentation(
                    kind: .html,
                    mime: mime.normalized,
                    text: String(data: data, encoding: .utf8) ?? binaryText(capturedByteCount),
                    displayByteLimit: displayByteLimit,
                    notices: notices
                )
            }

            if mime.isXML {
                return textPresentation(
                    kind: .xml,
                    mime: mime.normalized,
                    text: String(data: data, encoding: .utf8) ?? binaryText(capturedByteCount),
                    displayByteLimit: displayByteLimit,
                    notices: notices
                )
            }

            if mime.isText {
                return textPresentation(
                    kind: .text,
                    mime: mime.normalized,
                    text: String(data: data, encoding: .utf8) ?? binaryText(capturedByteCount),
                    displayByteLimit: displayByteLimit,
                    notices: notices
                )
            }

            return textPresentation(
                kind: .binary,
                mime: mime.normalized,
                text: binaryText(capturedByteCount),
                displayByteLimit: nil,
                notices: notices
            )
        }

        private static func presentUnknownMIME(
            data: Data,
            capturedByteCount: Int,
            displayByteLimit: Int,
            notices: [Notice]
        ) -> WindshieldPayloadPresentation {
            if case let .formatted(prettyJSON) = formattedJSON(
                data,
                displayByteLimit: displayByteLimit
            ) {
                return textPresentation(
                    kind: .json,
                    mime: nil,
                    text: prettyJSON,
                    displayByteLimit: displayByteLimit,
                    notices: notices
                )
            }

            if let text = String(data: data, encoding: .utf8) {
                return textPresentation(
                    kind: .text,
                    mime: nil,
                    text: text,
                    displayByteLimit: displayByteLimit,
                    notices: notices
                )
            }

            return textPresentation(
                kind: .binary,
                mime: nil,
                text: binaryText(capturedByteCount),
                displayByteLimit: nil,
                notices: notices
            )
        }

        private static func textPresentation(
            kind: Kind,
            mime: String?,
            text: String,
            displayByteLimit: Int?,
            notices: [Notice]
        ) -> WindshieldPayloadPresentation {
            guard let displayByteLimit else {
                return WindshieldPayloadPresentation(
                    kind: kind,
                    mimeType: mime,
                    text: text,
                    image: nil,
                    notices: notices,
                    customDecoderID: nil
                )
            }

            let bounded = boundedText(text, byteLimit: displayByteLimit)
            var boundedNotices = notices
            if bounded.wasTruncated {
                boundedNotices.append(
                    .formattedOutputTruncated(
                        displayedByteCount: bounded.text.lengthOfBytes(using: .utf8),
                        formattedByteCount: text.lengthOfBytes(using: .utf8)
                    )
                )
            }

            return WindshieldPayloadPresentation(
                kind: kind,
                mimeType: mime,
                text: bounded.text,
                image: nil,
                notices: boundedNotices,
                customDecoderID: nil
            )
        }

        private static func captureNotices(
            capturedByteCount: Int,
            totalByteCount: Int?
        ) -> [Notice] {
            guard let totalByteCount, capturedByteCount < totalByteCount else {
                return []
            }

            return [
                .captureTruncated(
                    capturedByteCount: capturedByteCount,
                    totalByteCount: totalByteCount
                ),
            ]
        }

        private static func unavailableText(
            _ reason: WindshieldBodyCapture.UnavailableReason,
            totalByteCount: Int?
        ) -> String {
            let size = totalByteCount.map { " Reported size: \($0) bytes." } ?? ""
            switch reason {
            case .bodyStream:
                return "Streamed request body is unavailable." + size
            case .discardedByRetentionPolicy:
                return "Body was discarded by the retention policy." + size
            case .excludedByCapturePolicy:
                return "Body was not captured by the metadata-only policy." + size
            }
        }

        private enum JSONFormattingResult {
            case formatted(String)
            case skipped
            case invalid
        }

        private static func formattedJSON(
            _ data: Data,
            displayByteLimit: Int
        ) -> JSONFormattingResult {
            guard jsonPrettyPrintPreflight(
                data,
                outputByteLimit: displayByteLimit
            ) else {
                return .skipped
            }

            guard
                let object = try? JSONSerialization.jsonObject(
                    with: data,
                    options: .fragmentsAllowed
                ),
                JSONSerialization.isValidJSONObject(object),
                let prettyData = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
                )
            else {
                return .invalid
            }

            guard let text = String(data: prettyData, encoding: .utf8) else {
                return .invalid
            }
            return .formatted(text)
        }

        /// Conservatively estimates Foundation's indentation before parsing or
        /// serializing. This prevents compact, deeply nested JSON from expanding
        /// into a large transient allocation before the display cap is applied.
        private static func jsonPrettyPrintPreflight(
            _ data: Data,
            outputByteLimit: Int
        ) -> Bool {
            let maximumNestingDepth = 64
            var estimatedOutputByteCount = data.count
            var depth = 0
            var isInsideString = false
            var isEscaped = false

            for byte in data {
                if isInsideString {
                    if isEscaped {
                        isEscaped = false
                    } else if byte == 0x5C {
                        isEscaped = true
                    } else if byte == 0x22 {
                        isInsideString = false
                    }
                    continue
                }

                switch byte {
                case 0x22:
                    isInsideString = true
                case 0x7B, 0x5B:
                    depth += 1
                    guard depth <= maximumNestingDepth else {
                        return false
                    }
                    estimatedOutputByteCount += 1 + (depth * 2)
                case 0x7D, 0x5D:
                    let enclosingDepth = max(0, depth - 1)
                    estimatedOutputByteCount += 1 + (enclosingDepth * 2)
                    depth = enclosingDepth
                case 0x2C:
                    estimatedOutputByteCount += 1 + (depth * 2)
                case 0x3A:
                    estimatedOutputByteCount += 1
                default:
                    break
                }

                guard estimatedOutputByteCount <= outputByteLimit else {
                    return false
                }
            }

            // Structural validity remains JSONSerialization's responsibility.
            // This pass rejects only work that could exceed the rendering budget.
            return true
        }

        private static func formattedForm(_ data: Data) -> String {
            guard let encodedForm = String(data: data, encoding: .utf8) else {
                return binaryText(data.count)
            }

            let fields = encodedForm.split(separator: "&", omittingEmptySubsequences: false)
            guard !fields.isEmpty else {
                return "No form fields."
            }

            return fields.map { field in
                let components = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = decodedFormComponent(String(components[0]))
                let value = components.count == 2 ? decodedFormComponent(String(components[1])) : ""
                return name + " = " + value
            }.joined(separator: "\n")
        }

        private static func decodedFormComponent(_ value: String) -> String {
            value
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? value
        }

        private static func multipartSummary(_ data: Data, boundary: String?) -> String {
            guard
                let boundary,
                !boundary.isEmpty,
                let body = String(data: data, encoding: .utf8)
            else {
                return "Multipart form data. Part contents are hidden for privacy."
            }

            let delimiter = "--" + boundary
            let parts = body.components(separatedBy: delimiter).dropFirst().filter { segment in
                !segment.hasPrefix("--")
            }
            let filePartCount = parts.reduce(into: 0) { count, segment in
                let headers = segment.components(separatedBy: "\r\n\r\n").first
                    ?? segment.components(separatedBy: "\n\n").first
                    ?? ""
                if headers.range(
                    of: "filename=",
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil {
                    count += 1
                }
            }
            let partLabel = parts.count == 1 ? "1 part" : "\(parts.count) parts"
            let fileLabel = filePartCount == 1 ? "1 file part" : "\(filePartCount) file parts"
            return "Multipart form data: \(partLabel), \(fileLabel). Part contents and filenames are hidden for privacy."
        }

        private static func binaryText(_ byteCount: Int) -> String {
            "Binary body, \(byteCount) bytes captured."
        }

        private static func limitedData(_ data: Data, byteLimit: Int) -> (data: Data, wasTruncated: Bool) {
            let limit = max(1, byteLimit)
            let limited = Data(data.prefix(limit))
            guard limited.count < data.count,
                  String(data: limited, encoding: .utf8) == nil
            else {
                return (limited, limited.count < data.count)
            }

            let maximumTrim = min(3, limited.count)
            for trimCount in 1 ... maximumTrim {
                let candidate = Data(limited.dropLast(trimCount))
                if String(data: candidate, encoding: .utf8) != nil {
                    return (candidate, true)
                }
            }
            // The prefix is not valid UTF-8 even after removing a possible split
            // scalar. Preserve it so callers classify it as binary instead of
            // mistaking an empty replacement for valid text.
            return (limited, true)
        }

        private static func boundedText(_ text: String, byteLimit: Int) -> (text: String, wasTruncated: Bool) {
            let limit = max(1, byteLimit)
            guard text.lengthOfBytes(using: .utf8) > limit else {
                return (text, false)
            }

            var result = ""
            var usedBytes = 0
            for character in text {
                let characterByteCount = String(character).lengthOfBytes(using: .utf8)
                guard usedBytes + characterByteCount <= limit else {
                    break
                }
                result.append(character)
                usedBytes += characterByteCount
            }
            return (result, true)
        }
    }

    struct WindshieldPayloadTextMatch: Sendable, Equatable {
        /// A UTF-16 range whose boundaries always correspond to `String` boundaries.
        let utf16Range: Range<Int>

        func stringRange(in text: String) -> Range<String.Index>? {
            guard
                utf16Range.lowerBound >= 0,
                utf16Range.upperBound <= text.utf16.count
            else {
                return nil
            }
            let lower = String.Index(utf16Offset: utf16Range.lowerBound, in: text)
            let upper = String.Index(utf16Offset: utf16Range.upperBound, in: text)
            return lower ..< upper
        }
    }

    enum WindshieldPayloadTextSearch {
        private static let locale = Locale(identifier: "en_US_POSIX")

        static func matches(
            in text: String,
            query: String,
            limit: Int = .max
        ) -> [WindshieldPayloadTextMatch] {
            guard !query.isEmpty, limit > 0 else {
                return []
            }

            var matches: [WindshieldPayloadTextMatch] = []
            var searchRange = text.startIndex ..< text.endIndex
            while matches.count < limit,
                  !Task.isCancelled,
                  let match = text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange,
                locale: locale
            ) {
                let lowerBound = text.utf16.distance(from: text.utf16.startIndex, to: match.lowerBound.samePosition(in: text.utf16)!)
                let upperBound = text.utf16.distance(from: text.utf16.startIndex, to: match.upperBound.samePosition(in: text.utf16)!)
                matches.append(
                    WindshieldPayloadTextMatch(utf16Range: lowerBound ..< upperBound)
                )
                searchRange = match.upperBound ..< text.endIndex
            }
            return matches
        }
    }

    struct WindshieldMIMEType: Sendable, Equatable {
        let normalized: String
        private let parameters: [String: String]

        init?(_ rawValue: String?) {
            guard let rawValue else {
                return nil
            }

            let components = Self.components(in: rawValue)
            guard
                let first = components.first,
                let normalized = Self.normalizeValue(first),
                normalized.contains("/")
            else {
                return nil
            }

            self.normalized = normalized
            var parsedParameters: [String: String] = [:]
            for component in components.dropFirst() {
                let pair = component.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard pair.count == 2,
                      let key = Self.normalizeValue(String(pair[0]))
                else {
                    continue
                }
                parsedParameters[key] = Self.unquoted(String(pair[1]))
            }
            parameters = parsedParameters
        }

        static func normalize(_ rawValue: String?) -> String? {
            WindshieldMIMEType(rawValue)?.normalized
        }

        var isJSON: Bool {
            normalized == "application/json" || normalized.hasSuffix("+json")
        }

        var isXML: Bool {
            normalized == "application/xml" || normalized == "text/xml" || normalized.hasSuffix("+xml")
        }

        var isHTML: Bool {
            normalized == "text/html" || normalized == "application/xhtml+xml"
        }

        var isText: Bool {
            normalized.hasPrefix("text/")
                || normalized == "application/javascript"
                || normalized == "application/graphql"
        }

        var isFormURLEncoded: Bool {
            normalized == "application/x-www-form-urlencoded"
        }

        var isMultipartFormData: Bool {
            normalized == "multipart/form-data"
        }

        var isImage: Bool {
            normalized.hasPrefix("image/")
        }

        func parameter(named name: String) -> String? {
            parameters[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        }

        private static func components(in value: String) -> [String] {
            var components: [String] = []
            var current = ""
            var isQuoted = false
            var isEscaped = false

            for character in value {
                if isEscaped {
                    current.append(character)
                    isEscaped = false
                } else if character == "\\" && isQuoted {
                    current.append(character)
                    isEscaped = true
                } else if character == "\"" {
                    current.append(character)
                    isQuoted.toggle()
                } else if character == ";" && !isQuoted {
                    components.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
            components.append(current)
            return components
        }

        private static func normalizeValue(_ value: String) -> String? {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? nil : normalized
        }

        private static func unquoted(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else {
                return trimmed
            }
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
    }

    extension Windshield {
        /// A bounded, textual decoder for one or more exact MIME types.
        ///
        /// The decoder receives only already-captured body bytes and a normalized
        /// content type. It cannot inspect or alter a live request, response, URL,
        /// headers, or transport.
        public struct PayloadDecoder: Sendable {
            public struct Input: Sendable, Equatable {
                public let contentType: String
                public let body: Data

                public init(contentType: String, body: Data) {
                    self.contentType = contentType
                    self.body = body
                }
            }

            public struct Output: Sendable, Equatable {
                public let text: String

                public init(text: String) {
                    self.text = text
                }
            }

            public let id: String
            /// Exact, parameter-free MIME types matched case-insensitively.
            public let contentTypes: Set<String>
            private let handler: @Sendable (Input) -> Output?

            public init(
                id: String,
                contentTypes: Set<String>,
                decode: @escaping @Sendable (Input) -> Output?
            ) {
                self.id = id
                self.contentTypes = Set(contentTypes.compactMap(WindshieldMIMEType.normalize))
                handler = decode
            }

            fileprivate func decode(_ input: Input) -> Output? {
                handler(input)
            }
        }

        /// Registers a textual snapshot decoder. Decoder order is registration order;
        /// registering an existing identifier replaces it in place.
        public static func registerPayloadDecoder(_ decoder: PayloadDecoder) {
            WindshieldPayloadDecoderRegistry.shared.register(decoder)
        }

        /// Removes a previously registered textual snapshot decoder.
        public static func removePayloadDecoder(id: String) {
            WindshieldPayloadDecoderRegistry.shared.remove(id: id)
        }
    }

    private final class WindshieldPayloadDecoderRegistry: @unchecked Sendable {
        static let shared = WindshieldPayloadDecoderRegistry()

        private let lock = NSLock()
        private var decoders: [Windshield.PayloadDecoder] = []

        func register(_ decoder: Windshield.PayloadDecoder) {
            guard !decoder.id.isEmpty, !decoder.contentTypes.isEmpty else {
                return
            }

            lock.lock()
            defer { lock.unlock() }
            if let existingIndex = decoders.firstIndex(where: { $0.id == decoder.id }) {
                decoders[existingIndex] = decoder
            } else {
                decoders.append(decoder)
            }
        }

        func remove(id: String) {
            lock.lock()
            decoders.removeAll { $0.id == id }
            lock.unlock()
        }

        func decoder(for contentType: String) -> Windshield.PayloadDecoder? {
            lock.lock()
            let decoder = decoders.first { $0.contentTypes.contains(contentType) }
            lock.unlock()
            return decoder
        }
    }
#endif

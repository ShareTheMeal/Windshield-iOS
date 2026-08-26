#if DEBUG && os(iOS)
    import Foundation
    import ImageIO
    import SwiftUI
    import UIKit

    @MainActor
    struct WindshieldBodySection: View {
        let title: String
        let capture: WindshieldBodyCapture?
        let contentType: String?

        @State private var presentation: WindshieldPayloadPresentation?
        @State private var searchText = ""
        @State private var searchMatches: [WindshieldPayloadTextMatch] = []
        @State private var isSearching = false
        @State private var isSearchResultLimited = false
        @State private var presentationRevision = 0

        private static let maximumHighlightedMatchCount = 500

        private struct SearchToken: Hashable {
            let presentationRevision: Int
            let query: String
        }

        private struct RenderingToken: Hashable {
            let contentType: String?
            let totalByteCount: Int?
            let capturedByteCount: Int
            let state: String
        }

        /// Captured bytes are immutable after a body reaches the store. The only
        /// later transition is retention replacing them with an unavailable reason,
        /// so counts plus that state form a stable token without hashing up to 1 MiB
        /// on the main actor during every SwiftUI update.
        private var renderingToken: RenderingToken {
            guard let capture else {
                return RenderingToken(
                    contentType: contentType,
                    totalByteCount: nil,
                    capturedByteCount: 0,
                    state: "waiting"
                )
            }

            switch capture.contents {
            case let .bytes(data):
                return RenderingToken(
                    contentType: contentType,
                    totalByteCount: capture.totalByteCount,
                    capturedByteCount: data.count,
                    state: "bytes"
                )
            case let .unavailable(reason):
                return RenderingToken(
                    contentType: contentType,
                    totalByteCount: capture.totalByteCount,
                    capturedByteCount: 0,
                    state: reason.rawValue
                )
            }
        }

        private var renderedText: String? {
            presentation?.text
        }

        private var normalizedSearchText: String {
            searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var searchToken: SearchToken {
            SearchToken(
                presentationRevision: presentationRevision,
                query: normalizedSearchText
            )
        }

        private var supportsSearch: Bool {
            guard let presentation else {
                return false
            }

            switch presentation.kind {
            case .json, .html, .xml, .text, .form, .custom:
                return true
            case .multipart, .image, .binary, .unavailable:
                return false
            }
        }

        var body: some View {
            Section {
                if let presentation {
                    payloadContent(presentation)
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Preparing body preview.")
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                WindshieldCopyableSectionHeader(
                    title: title,
                    copyLabel: "Copy \(title.lowercased())",
                    value: renderedText ?? "",
                    isEnabled: renderedText != nil
                )
            }
            .task(id: renderingToken) {
                presentation = nil
                searchText = ""
                searchMatches = []
                isSearching = false
                isSearchResultLimited = false
                let capture = capture
                let contentType = contentType
                let rendered = await WindshieldBackgroundWork.run {
                    WindshieldPayloadPresentation.present(
                        capture,
                        contentType: contentType
                    )
                }
                guard !Task.isCancelled else {
                    return
                }
                presentation = rendered
                presentationRevision &+= 1
            }
            .task(id: searchToken) {
                searchMatches = []
                isSearchResultLimited = false

                guard supportsSearch,
                      let renderedText,
                      !normalizedSearchText.isEmpty
                else {
                    isSearching = false
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 150_000_000)
                } catch {
                    isSearching = false
                    return
                }
                guard !Task.isCancelled else {
                    isSearching = false
                    return
                }

                isSearching = true
                let query = normalizedSearchText
                let maximumResultCount = Self.maximumHighlightedMatchCount + 1
                let matches = await WindshieldBackgroundWork.run {
                    WindshieldPayloadTextSearch.matches(
                        in: renderedText,
                        query: query,
                        limit: maximumResultCount
                    )
                }
                guard !Task.isCancelled else {
                    return
                }

                isSearchResultLimited = matches.count > Self.maximumHighlightedMatchCount
                searchMatches = Array(
                    matches.prefix(Self.maximumHighlightedMatchCount)
                )
                isSearching = false
            }
        }

        @ViewBuilder
        private func payloadContent(
            _ presentation: WindshieldPayloadPresentation
        ) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                payloadMetadata(presentation)

                ForEach(
                    Array(presentation.notices.enumerated()),
                    id: \.offset
                ) { _, notice in
                    Label(noticeText(notice), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }

                if supportsSearch {
                    TextField("Find in body", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .accessibilityLabel("Search \(title.lowercased())")

                    if !normalizedSearchText.isEmpty {
                        Text(searchResultText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("Windshield body search result count")
                    }
                }

                if let image = presentation.image {
                    WindshieldImagePreview(image: image)
                } else if let text = presentation.text {
                    ScrollView(.horizontal, showsIndicators: true) {
                        highlightedText(text, matches: searchMatches)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .accessibilityIdentifier("Windshield payload text")
                    }
                    .background(
                        Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                    )
                }
            }
        }

        private func payloadMetadata(
            _ presentation: WindshieldPayloadPresentation
        ) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kindLabel(presentation))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundColor(.blue)
                    .background(Color.blue.opacity(0.12), in: Capsule())

                if let mimeType = presentation.mimeType {
                    Text(mimeType)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
        }

        private func kindLabel(
            _ presentation: WindshieldPayloadPresentation
        ) -> String {
            switch presentation.kind {
            case .json:
                "JSON"
            case .html:
                "HTML source"
            case .xml:
                "XML source"
            case .text:
                "Text"
            case .form:
                "URL-encoded form"
            case .multipart:
                "Multipart summary"
            case .image:
                "Image"
            case .binary:
                "Binary"
            case .unavailable:
                "Unavailable"
            case .custom:
                presentation.customDecoderID.map { "Custom · \($0)" } ?? "Custom"
            }
        }

        private func noticeText(
            _ notice: WindshieldPayloadPresentation.Notice
        ) -> String {
            switch notice {
            case let .captureTruncated(capturedByteCount, totalByteCount):
                "Captured \(WindshieldDisplayFormatter.byteCount(capturedByteCount)) of "
                    + "\(WindshieldDisplayFormatter.byteCount(totalByteCount))."
            case let .displayTruncated(displayedByteCount, capturedByteCount):
                "Showing the first \(WindshieldDisplayFormatter.byteCount(displayedByteCount)) "
                    + "of \(WindshieldDisplayFormatter.byteCount(capturedByteCount)) captured."
            case let .formattedOutputTruncated(displayedByteCount, formattedByteCount):
                "Showing the first \(WindshieldDisplayFormatter.byteCount(displayedByteCount)) "
                    + "of \(WindshieldDisplayFormatter.byteCount(formattedByteCount)) formatted."
            case let .jsonFormattingSkipped(displayByteLimit):
                "JSON formatting was skipped because the expanded result could exceed "
                    + "the \(WindshieldDisplayFormatter.byteCount(displayByteLimit)) display limit."
            case let .decoderInputTruncated(inputByteCount, capturedByteCount):
                "The custom decoder received the first "
                    + "\(WindshieldDisplayFormatter.byteCount(inputByteCount)) of "
                    + "\(WindshieldDisplayFormatter.byteCount(capturedByteCount)) captured."
            case let .decoderOutputTruncated(displayedByteCount, decodedByteCount):
                "Showing the first \(WindshieldDisplayFormatter.byteCount(displayedByteCount)) "
                    + "of \(WindshieldDisplayFormatter.byteCount(decodedByteCount)) decoded."
            }
        }

        private var searchResultText: String {
            if isSearching {
                return "Searching…"
            }
            if isSearchResultLimited {
                return "500+ matches · first 500 highlighted"
            }
            return searchMatches.count == 1
                ? "1 match"
                : "\(searchMatches.count) matches"
        }

        private func highlightedText(
            _ text: String,
            matches: [WindshieldPayloadTextMatch]
        ) -> Text {
            guard !matches.isEmpty else {
                return Text(text)
            }

            var result = Text("")
            var cursor = text.startIndex
            for match in matches {
                guard let range = match.stringRange(in: text), range.lowerBound >= cursor else {
                    continue
                }

                result = result + Text(String(text[cursor ..< range.lowerBound]))
                result = result
                    + Text(String(text[range]))
                    .foregroundColor(.accentColor)
                    .bold()
                cursor = range.upperBound
            }
            return result + Text(String(text[cursor...]))
        }
    }

    @MainActor
    private struct WindshieldImagePreview: View {
        let image: WindshieldPayloadPresentation.Image

        private enum PreviewState {
            case loading
            case loaded(UIImage, width: Int, height: Int)
            case unavailable(String)
        }

        @State private var state = PreviewState.loading

        private struct RenderingToken: Hashable {
            let mimeType: String
            let capturedByteCount: Int
        }

        private var renderingToken: RenderingToken {
            RenderingToken(
                mimeType: image.mimeType,
                capturedByteCount: image.data.count
            )
        }

        var body: some View {
            Group {
                switch state {
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Preparing a safe image preview.")
                            .foregroundColor(.secondary)
                    }

                case let .loaded(thumbnail, width, height):
                    VStack(alignment: .leading, spacing: 8) {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 320)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(
                                        Color(.separator).opacity(0.35),
                                        lineWidth: 0.5
                                    )
                            )
                            .accessibilityLabel(
                                "Captured image, \(width) by \(height) pixels"
                            )

                        Text(
                            "\(width) × \(height) px · "
                                + WindshieldDisplayFormatter.byteCount(image.data.count)
                                + " captured"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    }

                case let .unavailable(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .task(id: renderingToken) {
                state = .loading
                let data = image.data
                let result = await WindshieldBackgroundWork.run {
                    WindshieldSafeImageThumbnail.make(from: data)
                }
                guard !Task.isCancelled else {
                    return
                }

                switch result {
                case let .success(thumbnail):
                    state = .loaded(
                        UIImage(cgImage: thumbnail.image),
                        width: thumbnail.sourceWidth,
                        height: thumbnail.sourceHeight
                    )
                case let .failure(message):
                    state = .unavailable(message)
                }
            }
        }
    }

    enum WindshieldSafeImageThumbnail {
        private static let maximumSourcePixelCount: Int64 = 32_000_000
        private static let maximumSourceDimension = 16_384
        private static let maximumThumbnailDimension = 1_600

        struct Thumbnail: @unchecked Sendable {
            let image: CGImage
            let sourceWidth: Int
            let sourceHeight: Int
        }

        enum Result: Sendable {
            case success(Thumbnail)
            case failure(String)
        }

        static func make(from data: Data) -> Result {
            guard !Task.isCancelled,
                  !data.isEmpty,
                  let source = CGImageSourceCreateWithData(data as CFData, [
                      kCGImageSourceShouldCache: false,
                  ] as CFDictionary)
            else {
                return .failure("The captured bytes are not a supported image.")
            }

            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
            ) as? [CFString: Any],
                let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                width > 0,
                height > 0
            else {
                return .failure("Image dimensions are unavailable.")
            }

            guard isSourceSizeSafe(width: width, height: height) else {
                return .failure(
                    "Preview skipped because the decoded image would be too large."
                )
            }

            guard !Task.isCancelled else {
                return .failure("Image preview was cancelled.")
            }

            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) else {
                return .failure("Windshield could not create a safe image preview.")
            }

            return .success(
                Thumbnail(
                    image: thumbnail,
                    sourceWidth: width,
                    sourceHeight: height
                )
            )
        }

        static func isSourceSizeSafe(width: Int, height: Int) -> Bool {
            guard width > 0,
                  height > 0,
                  width <= maximumSourceDimension,
                  height <= maximumSourceDimension
            else {
                return false
            }

            return Int64(width) * Int64(height) <= maximumSourcePixelCount
        }
    }

    private enum WindshieldBackgroundWork {
        static func run<Value: Sendable>(
            _ operation: @escaping @Sendable () -> Value
        ) async -> Value {
            let worker = Task.detached(priority: .utility, operation: operation)
            return await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
    }
#endif

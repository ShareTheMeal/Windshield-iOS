#if DEBUG && os(iOS)
    import Foundation
    import SwiftUI
    import UIKit

    @MainActor
    struct WindshieldTransactionDetailView: View {
        let transactionID: UUID
        @ObservedObject var store: WindshieldStore

        private var transaction: WindshieldTransaction? {
            store.transactions.first { $0.id == transactionID }
        }

        var body: some View {
            Group {
                if let transaction {
                    transactionList(transaction)
                } else {
                    WindshieldEmptyState(
                        title: "Request removed",
                        message: "This request is no longer in Windshield's in-memory history.",
                        systemImage: "trash"
                    )
                }
            }
            .navigationTitle("Request")
            .navigationBarTitleDisplayMode(.inline)
        }

        private func transactionList(_ transaction: WindshieldTransaction) -> some View {
            List {
                Section {
                    WindshieldRequestSummary(transaction: transaction)
                }

                Section("Overview") {
                    WindshieldMetadataRow(
                        title: "Started",
                        value: WindshieldDisplayFormatter.time(transaction.startedAt)
                    )
                    WindshieldMetadataRow(
                        title: "Duration",
                        value: WindshieldDisplayFormatter.duration(transaction.duration)
                    )
                    WindshieldMetadataRow(
                        title: "Request body",
                        value: bodySize(transaction.request.body)
                    )
                    WindshieldMetadataRow(
                        title: "Response body",
                        value: responseBodySize(transaction)
                    )
                    if let contentType = contentType(transaction.response?.headers ?? []) {
                        WindshieldMetadataRow(title: "Content-Type", value: contentType)
                    }
                    if case let .redirected(destination) = transaction.state {
                        WindshieldMetadataRow(
                            title: "Redirect destination",
                            value: destination?.absoluteString ?? "Unknown"
                        )
                    }
                }

                WindshieldHeadersSection(
                    title: "Request headers",
                    headers: transaction.request.headers
                )
                WindshieldBodySection(
                    title: "Request body",
                    capture: transaction.request.body
                )

                if let response = transaction.response {
                    WindshieldHeadersSection(
                        title: "Response headers",
                        headers: response.headers
                    )
                    WindshieldBodySection(
                        title: "Response body",
                        capture: response.body
                    )
                } else {
                    Section("Response") {
                        Text(transaction.state == .inFlight ? "Waiting for response." : "No response received.")
                            .foregroundColor(.secondary)
                    }
                }

                if let failure = transaction.failure {
                    Section("Failure") {
                        WindshieldMetadataRow(title: "Message", value: failure.message)
                        WindshieldMetadataRow(title: "Domain", value: failure.domain)
                        WindshieldMetadataRow(title: "Code", value: String(failure.code))
                    }
                }
            }
            .listStyle(.insetGrouped)
        }

        private func bodySize(_ body: WindshieldBodyCapture) -> String {
            guard let totalByteCount = body.totalByteCount else {
                return "Unknown"
            }

            let size = WindshieldDisplayFormatter.byteCount(totalByteCount)
            return body.isTruncated ? "\(size), truncated" : size
        }

        private func responseBodySize(_ transaction: WindshieldTransaction) -> String {
            guard let byteCount = transaction.responseBodyByteCount else {
                return transaction.state == .inFlight ? "Waiting" : "Unknown"
            }

            let size = WindshieldDisplayFormatter.byteCount(byteCount)
            guard transaction.response?.body?.isTruncated == true else {
                return size
            }
            return "\(size), truncated"
        }

        private func contentType(_ headers: [WindshieldHeader]) -> String? {
            headers.first {
                $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
            }?.value
        }
    }

    private struct WindshieldRequestSummary: View {
        let transaction: WindshieldTransaction

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    WindshieldMethodBadge(method: transaction.request.method)
                    WindshieldStatusBadge(transaction: transaction)
                    Spacer()
                }

                Text(transaction.request.url?.absoluteString ?? "Unknown URL")
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let url = transaction.request.url?.absoluteString {
                    Button {
                        UIPasteboard.general.string = url
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }
                    .font(.caption)
                    .accessibilityLabel("Copy request URL")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private struct WindshieldHeadersSection: View {
        let title: String
        let headers: [WindshieldHeader]

        private var formattedHeaders: String {
            WindshieldHeaderFormatter.format(headers)
        }

        var body: some View {
            Section {
                if headers.isEmpty {
                    Text("No headers.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        WindshieldMetadataRow(title: header.name, value: header.value)
                    }
                }
            } header: {
                WindshieldCopyableSectionHeader(
                    title: title,
                    copyLabel: "Copy \(title.lowercased())",
                    value: formattedHeaders
                )
            }
        }
    }

    private struct WindshieldBodySection: View {
        let title: String
        let capture: WindshieldBodyCapture?
        @State private var renderedBody = "Formatting body."
        @State private var isFormatting = true

        private var renderingToken: String {
            guard let capture else {
                return "waiting"
            }

            switch capture.contents {
            case let .bytes(data):
                return "bytes-\(data.count)-\(capture.totalByteCount ?? -1)"
            case let .unavailable(reason):
                return "unavailable-\(reason.rawValue)-\(capture.totalByteCount ?? -1)"
            }
        }

        var body: some View {
            Section {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(renderedBody)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                WindshieldCopyableSectionHeader(
                    title: title,
                    copyLabel: "Copy \(title.lowercased())",
                    value: renderedBody,
                    isEnabled: !isFormatting
                )
            }
            .task(id: renderingToken) {
                isFormatting = true
                let capture = capture
                renderedBody = await Task.detached(priority: .utility) {
                    WindshieldBodyFormatter.format(capture)
                }.value
                isFormatting = false
            }
        }
    }

    private struct WindshieldCopyableSectionHeader: View {
        let title: String
        let copyLabel: String
        let value: String
        var isEnabled = true

        var body: some View {
            HStack {
                Text(title)
                Spacer()
                Button {
                    UIPasteboard.general.string = value
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!isEnabled)
                .accessibilityLabel(copyLabel)
            }
        }
    }
#endif

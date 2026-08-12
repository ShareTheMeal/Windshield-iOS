#if DEBUG && os(iOS)
    import Foundation
    import SwiftUI

    struct WindshieldTrafficSummaryView: View {
        let transactions: [WindshieldTransaction]

        private var errorCount: Int {
            transactions.filter(\.isError).count
        }

        private var activeCount: Int {
            transactions.filter { $0.state == .inFlight }.count
        }

        var body: some View {
            HStack(spacing: 0) {
                metric(title: "Total", value: transactions.count, color: .primary)
                Divider()
                metric(title: "Errors", value: errorCount, color: .red)
                Divider()
                metric(title: "Active", value: activeCount, color: .orange)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(transactions.count) total requests, \(errorCount) errors, "
                    + "\(activeCount) active"
            )
        }

        private func metric(title: String, value: Int, color: Color) -> some View {
            VStack(spacing: 2) {
                Text(String(value))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    struct WindshieldFilterBar: View {
        @Binding var selection: WindshieldTrafficFilter

        var body: some View {
            HStack(spacing: 8) {
                ForEach(WindshieldTrafficFilter.allCases) { filter in
                    Button {
                        selection = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .foregroundColor(
                                selection == filter
                                    ? Color(.systemBackground)
                                    : .primary
                            )
                            .background(
                                Capsule()
                                    .fill(
                                        selection == filter
                                            ? Color.primary
                                            : Color(.tertiarySystemFill)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == filter ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    struct WindshieldHostLatencyView: View {
        let summaries: [WindshieldHostLatencySummary]

        var body: some View {
            if !summaries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Slowest observed hosts")
                        .font(.headline)

                    ForEach(summaries) { summary in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(summary.host)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(
                                "avg \(WindshieldDisplayFormatter.duration(summary.averageDuration))"
                            )
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        }

                        Text(
                            "\(summary.sampleCount) observed · max "
                                + WindshieldDisplayFormatter.duration(
                                    summary.maximumDuration
                                )
                        )
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
            }
        }
    }

    struct WindshieldTransactionRow: View {
        let transaction: WindshieldTransaction

        private var host: String {
            transaction.request.url?.host ?? "Unknown host"
        }

        private var path: String {
            let path = transaction.request.url?.path ?? ""
            return path.isEmpty ? "/" : path
        }

        private var footer: String {
            var values = [
                WindshieldDisplayFormatter.time(transaction.startedAt),
                WindshieldDisplayFormatter.duration(transaction.observedDuration),
            ]
            if let byteCount = transaction.responseBodyByteCount {
                values.append(WindshieldDisplayFormatter.byteCount(byteCount))
            }
            return values.joined(separator: " · ")
        }

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                WindshieldMethodBadge(method: transaction.request.method)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(host)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        WindshieldStatusBadge(transaction: transaction)
                    }

                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(footer)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 44)
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(transaction.request.method) \(host)\(path), "
                    + "\(transaction.statusText), \(footer)"
            )
        }
    }

    struct WindshieldMethodBadge: View {
        let method: String

        var body: some View {
            Text(method.uppercased())
                .font(.caption2.weight(.bold).monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(.primary)
                .frame(width: 52, height: 24)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(.separator), lineWidth: 1)
                )
                .accessibilityLabel("Method \(method)")
        }
    }

    struct WindshieldStatusBadge: View {
        let transaction: WindshieldTransaction

        var body: some View {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(transaction.statusText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(statusColor.opacity(0.65), lineWidth: 1)
            )
        }

        private var statusColor: Color {
            switch transaction.state {
            case .inFlight:
                .orange
            case .failed:
                .red
            case .cancelled:
                .secondary
            case .redirected:
                .orange
            case .completed:
                switch transaction.response?.statusCode ?? 0 {
                case 200 ..< 300:
                    .green
                case 300 ..< 400:
                    .orange
                case 400...:
                    .red
                default:
                    .secondary
                }
            }
        }
    }

    struct WindshieldEmptyState: View {
        let title: String
        let message: String
        let systemImage: String

        var body: some View {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .padding(.horizontal, 28)
        }
    }

    struct WindshieldMetadataRow: View {
        let title: String
        let value: String

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }

    struct WindshieldNetworkWaterfallView: View {
        let attempt: WindshieldNetworkMetrics.Attempt
        let taskDuration: TimeInterval?

        private struct Phase: Identifiable {
            enum Kind: String {
                case dns = "DNS"
                case connect = "Connect"
                case tls = "TLS"
                case request = "Request"
                case waiting = "Waiting"
                case response = "Response"

                var color: Color {
                    switch self {
                    case .dns:
                        .purple
                    case .connect:
                        .blue
                    case .tls:
                        .indigo
                    case .request:
                        .orange
                    case .waiting:
                        .pink
                    case .response:
                        .green
                    }
                }
            }

            let kind: Kind
            let interval: WindshieldNetworkMetrics.Interval

            var id: Kind {
                kind
            }
        }

        private var phases: [Phase] {
            [
                attempt.phases.dns.map { Phase(kind: .dns, interval: $0) },
                attempt.phases.connect.map { Phase(kind: .connect, interval: $0) },
                attempt.phases.tls.map { Phase(kind: .tls, interval: $0) },
                attempt.phases.request.map { Phase(kind: .request, interval: $0) },
                attempt.phases.waiting.map { Phase(kind: .waiting, interval: $0) },
                attempt.phases.response.map { Phase(kind: .response, interval: $0) },
            ].compactMap { $0 }
        }

        private var timelineDuration: TimeInterval {
            max(
                0.001,
                taskDuration ?? phases.map(\.interval.endOffset).max() ?? 0.001
            )
        }

        var body: some View {
            if phases.isEmpty {
                Text("Timing phases were not available for this attempt.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(phases) { phase in
                        HStack(spacing: 8) {
                            Text(phase.kind.rawValue)
                                .font(.caption2)
                                .frame(width: 56, alignment: .leading)

                            GeometryReader { proxy in
                                let start = min(
                                    1,
                                    max(0, phase.interval.startOffset / timelineDuration)
                                )
                                let length = min(
                                    1 - start,
                                    max(0, phase.interval.duration / timelineDuration)
                                )

                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color(.tertiarySystemFill))
                                    Capsule()
                                        .fill(phase.kind.color)
                                        .frame(width: max(2, proxy.size.width * length))
                                        .offset(x: proxy.size.width * start)
                                }
                            }
                            .frame(height: 8)

                            Text(
                                WindshieldDisplayFormatter.duration(
                                    phase.interval.duration
                                )
                            )
                            .font(.caption2.monospacedDigit())
                            .frame(width: 54, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(phase.kind.rawValue), starts at "
                                + "\(WindshieldDisplayFormatter.duration(phase.interval.startOffset)), "
                                + "duration \(WindshieldDisplayFormatter.duration(phase.interval.duration))"
                        )
                    }
                }
            }
        }
    }
#endif

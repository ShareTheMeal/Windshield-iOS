#if DEBUG && os(iOS)
    import Foundation
    import SwiftUI

    struct WindshieldFilterBar: View {
        @Binding var selection: WindshieldTrafficFilter

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WindshieldTrafficFilter.allCases) { filter in
                        Button {
                            selection = filter
                        } label: {
                            Text(filter.rawValue)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .foregroundColor(
                                    selection == filter
                                        ? .white
                                        : .primary
                                )
                                .background(
                                    Capsule()
                                        .fill(
                                            selection == filter
                                                ? Color(.systemBlue)
                                                : Color(.tertiarySystemFill)
                                        )
                                )
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            selection == filter ? .isSelected : []
                        )
                    }
                }
            }
        }
    }

    struct WindshieldHostLatencyView: View {
        let summaries: [WindshieldHostLatencySummary]

        var body: some View {
            if !summaries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Slowest hosts")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)

                    ForEach(summaries) { summary in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(summary.host)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(
                                    "avg "
                                        + WindshieldDisplayFormatter.duration(
                                            summary.averageDuration
                                        )
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
                }
                .padding(12)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityElement(children: .contain)
            }
        }
    }

    enum WindshieldTimelinePosition: Equatable {
        case only
        case first
        case middle
        case last

        init(index: Int, count: Int) {
            if count <= 1 {
                self = .only
            } else if index == 0 {
                self = .first
            } else if index == count - 1 {
                self = .last
            } else {
                self = .middle
            }
        }

        var drawsLineAbove: Bool {
            self == .middle || self == .last
        }

        var drawsLineBelow: Bool {
            self == .first || self == .middle
        }
    }

    struct WindshieldTransactionRow: View {
        let transaction: WindshieldTransaction
        let position: WindshieldTimelinePosition

        private var host: String {
            transaction.request.url?.host ?? "Unknown host"
        }

        private var path: String {
            let path = transaction.request.url?.path ?? ""
            return path.isEmpty ? "/" : path
        }

        private var duration: String {
            guard let duration = transaction.observedDuration else {
                return "—"
            }

            return WindshieldDisplayFormatter.duration(duration)
        }

        private var byteCount: String {
            guard let byteCount = transaction.responseBodyByteCount else {
                return "—"
            }

            return WindshieldDisplayFormatter.byteCount(byteCount)
        }

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                WindshieldTimelineIndicator(
                    color: transaction.inspectorStatusColor,
                    position: position
                )
                .frame(width: 8)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        WindshieldMethodBadge(
                            method: transaction.request.method
                        )
                        Text(transaction.statusText)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundColor(transaction.inspectorStatusColor)
                        Text(path)
                            .font(.subheadline.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(host)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(duration)
                        Text(byteCount)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
            }
            .frame(minHeight: 70)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(transaction.request.method) \(host)\(path), "
                    + "\(transaction.statusText), \(duration), \(byteCount)"
            )
        }
    }

    private struct WindshieldTimelineIndicator: View {
        let color: Color
        let position: WindshieldTimelinePosition

        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    if position.drawsLineAbove {
                        Rectangle()
                            .fill(Color(.separator))
                            .frame(width: 1, height: 14)
                    }

                    if position.drawsLineBelow {
                        Rectangle()
                            .fill(Color(.separator))
                            .frame(
                                width: 1,
                                height: max(0, proxy.size.height - 14)
                            )
                            .offset(y: 14)
                    }

                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .offset(y: 11)
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityHidden(true)
        }
    }

    struct WindshieldMethodBadge: View {
        let method: String

        private var color: Color {
            switch method.uppercased() {
            case "GET":
                .blue
            case "POST":
                .green
            case "PUT", "PATCH":
                .orange
            case "DELETE":
                .red
            default:
                .purple
            }
        }

        var body: some View {
            Text(method.uppercased())
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .foregroundColor(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .accessibilityLabel("Method \(method)")
        }
    }

    struct WindshieldStatusBadge: View {
        let transaction: WindshieldTransaction

        var body: some View {
            HStack(spacing: 5) {
                Circle()
                    .fill(transaction.inspectorStatusColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(transaction.statusText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(transaction.inspectorStatusColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                transaction.inspectorStatusColor.opacity(0.12),
                in: Capsule()
            )
        }
    }

    extension WindshieldTransaction {
        var inspectorStatusColor: Color {
            switch state {
            case .inFlight:
                .blue
            case .failed:
                .red
            case .cancelled:
                .secondary
            case .redirected:
                .orange
            case .completed:
                switch response?.statusCode ?? 0 {
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

    struct WindshieldInspectorSectionHeader: View {
        let title: String
        var color: Color = .secondary

        var body: some View {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.35)
                .foregroundColor(color)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
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
                    .font(.caption.weight(.medium))
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

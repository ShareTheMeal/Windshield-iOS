import Foundation

#if DEBUG
    enum WindshieldTrafficFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case errors = "Errors"
        case active = "Active"
        case slow = "Slow"

        var id: Self {
            self
        }
    }

    enum WindshieldTransactionQuery {
        static func matches(
            _ transaction: WindshieldTransaction,
            filter: WindshieldTrafficFilter,
            searchText: String
        ) -> Bool {
            guard matchesFilter(transaction, filter: filter) else {
                return false
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                return true
            }

            return searchableValues(for: transaction).contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }

        private static func matchesFilter(
            _ transaction: WindshieldTransaction,
            filter: WindshieldTrafficFilter
        ) -> Bool {
            switch filter {
            case .all:
                true
            case .errors:
                transaction.isError
            case .active:
                transaction.state == .inFlight
            case .slow:
                transaction.isSlow
            }
        }

        private static func searchableValues(
            for transaction: WindshieldTransaction
        ) -> [String] {
            var values = [
                transaction.request.method,
                transaction.request.url?.absoluteString ?? "",
                transaction.request.url?.host ?? "",
                transaction.request.url?.path ?? "",
            ]

            if let statusCode = transaction.response?.statusCode {
                values.append(String(statusCode))
            }

            if case let .failed(failure) = transaction.state {
                values.append(failure.domain)
                values.append(String(failure.code))
                values.append(failure.message)
            }

            return values
        }
    }

    enum WindshieldHeaderFormatter {
        static func format(_ headers: [WindshieldHeader]) -> String {
            guard !headers.isEmpty else {
                return "No headers."
            }

            return headers
                .map { "\($0.name): \($0.value)" }
                .joined(separator: "\n")
        }
    }

    enum WindshieldDisplayFormatter {
        private static let posixLocale = Locale(identifier: "en_US_POSIX")

        static func byteCount(_ byteCount: Int) -> String {
            guard byteCount > 0 else {
                return "0 bytes"
            }

            return ByteCountFormatter.string(
                fromByteCount: Int64(byteCount),
                countStyle: .file
            )
        }

        static func byteCount(_ byteCount: Int64) -> String {
            guard byteCount > 0 else {
                return "0 bytes"
            }

            return ByteCountFormatter.string(
                fromByteCount: byteCount,
                countStyle: .file
            )
        }

        static func duration(_ duration: TimeInterval?) -> String {
            guard let duration else {
                return "Active"
            }

            let clampedDuration = max(0, duration)
            if clampedDuration < 1 {
                return String(
                    format: "%.0f ms",
                    locale: posixLocale,
                    clampedDuration * 1000
                )
            }

            return String(
                format: "%.2f s",
                locale: posixLocale,
                clampedDuration
            )
        }

        static func time(_ date: Date) -> String {
            date.formatted(date: .omitted, time: .standard)
        }
    }

    extension WindshieldTransaction {
        var observedDuration: TimeInterval? {
            networkMetrics?.observedDuration ?? duration
        }

        var isSlow: Bool {
            guard isTerminal, let observedDuration else {
                return false
            }

            return observedDuration >= WindshieldNetworkMetrics.slowThreshold
        }

        var responseBodyByteCount: Int? {
            response?.body?.totalByteCount ?? response?.expectedBodyByteCount
        }

        var failure: WindshieldFailure? {
            guard case let .failed(failure) = state else {
                return nil
            }

            return failure
        }

        var statusText: String {
            switch state {
            case .inFlight:
                "Active"
            case .failed:
                "Error"
            case .cancelled:
                "Cancelled"
            case .redirected:
                response.map { String($0.statusCode) } ?? "Redirect"
            case .completed:
                response.map { String($0.statusCode) } ?? "Complete"
            }
        }
    }

    struct WindshieldHostLatencySummary: Identifiable, Equatable {
        let host: String
        let sampleCount: Int
        let averageDuration: TimeInterval
        let maximumDuration: TimeInterval

        var id: String {
            host
        }
    }

    enum WindshieldPerformanceSummary {
        static func slowestHosts(
            in transactions: [WindshieldTransaction],
            limit: Int = 3
        ) -> [WindshieldHostLatencySummary] {
            guard limit > 0 else {
                return []
            }

            var durationsByHost: [String: [TimeInterval]] = [:]
            for transaction in transactions where transaction.isTerminal {
                guard let host = transaction.request.url?.host?.lowercased(),
                      !host.isEmpty,
                      let duration = transaction.observedDuration
                else {
                    continue
                }

                durationsByHost[host, default: []].append(max(0, duration))
            }

            return durationsByHost.map { host, durations in
                WindshieldHostLatencySummary(
                    host: host,
                    sampleCount: durations.count,
                    averageDuration: durations.reduce(0, +) / TimeInterval(durations.count),
                    maximumDuration: durations.max() ?? 0
                )
            }
            .sorted {
                if $0.averageDuration != $1.averageDuration {
                    return $0.averageDuration > $1.averageDuration
                }
                if $0.maximumDuration != $1.maximumDuration {
                    return $0.maximumDuration > $1.maximumDuration
                }
                return $0.host < $1.host
            }
            .prefix(limit)
            .map { $0 }
        }
    }
#endif

import Foundation

#if DEBUG
    enum WindshieldTrafficFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case errors = "Errors"
        case active = "Active"

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

    enum WindshieldBodyFormatter {
        static let defaultDisplayByteLimit = 128 * 1024

        static func format(
            _ body: WindshieldBodyCapture?,
            displayByteLimit: Int = defaultDisplayByteLimit
        ) -> String {
            guard let body else {
                return "Waiting for response body."
            }

            switch body.contents {
            case let .unavailable(reason):
                return unavailableDescription(reason, totalByteCount: body.totalByteCount)

            case let .bytes(data):
                return formatBytes(
                    data,
                    totalByteCount: body.totalByteCount,
                    displayByteLimit: max(1, displayByteLimit)
                )
            }
        }

        private static func unavailableDescription(
            _ reason: WindshieldBodyCapture.UnavailableReason,
            totalByteCount: Int?
        ) -> String {
            let size = totalByteCount.map(WindshieldDisplayFormatter.byteCount)

            switch reason {
            case .bodyStream:
                if let size {
                    return "Streamed request body is unavailable. Reported size: \(size)."
                }
                return "Streamed request body is unavailable."

            case .discardedByRetentionPolicy:
                if let size {
                    return "Body was discarded to stay within Windshield's memory limit. Size: \(size)."
                }
                return "Body was discarded to stay within Windshield's memory limit."
            }
        }

        private static func formatBytes(
            _ data: Data,
            totalByteCount: Int?,
            displayByteLimit: Int
        ) -> String {
            guard !data.isEmpty else {
                return "No body."
            }

            let displayedData = displayData(
                from: data,
                displayByteLimit: displayByteLimit
            )
            let isDisplayLimited = displayedData.count < data.count
            let content = formattedContent(
                displayedData,
                canPrettyPrintJSON: !isDisplayLimited
            )

            var notices: [String] = []
            if let totalByteCount, data.count < totalByteCount {
                notices.append(
                    "Captured \(WindshieldDisplayFormatter.byteCount(data.count)) of "
                        + "\(WindshieldDisplayFormatter.byteCount(totalByteCount))."
                )
            }
            if isDisplayLimited {
                notices.append(
                    "Showing the first "
                        + "\(WindshieldDisplayFormatter.byteCount(displayedData.count)) "
                        + "of the captured body."
                )
            }

            guard !notices.isEmpty else {
                return content
            }

            return content + "\n\n[" + notices.joined(separator: " ") + "]"
        }

        private static func displayData(
            from data: Data,
            displayByteLimit: Int
        ) -> Data {
            let limitedData = Data(data.prefix(displayByteLimit))
            guard limitedData.count < data.count,
                  String(data: limitedData, encoding: .utf8) == nil
            else {
                return limitedData
            }

            let maximumExtension = min(3, data.count - limitedData.count)
            guard maximumExtension > 0 else {
                return limitedData
            }

            for additionalByteCount in 1 ... maximumExtension {
                let candidate = Data(
                    data.prefix(limitedData.count + additionalByteCount)
                )
                if String(data: candidate, encoding: .utf8) != nil {
                    return candidate
                }
            }

            return limitedData
        }

        private static func formattedContent(
            _ data: Data,
            canPrettyPrintJSON: Bool
        ) -> String {
            if canPrettyPrintJSON,
               let object = try? JSONSerialization.jsonObject(
                   with: data,
                   options: .fragmentsAllowed
               ),
               JSONSerialization.isValidJSONObject(object),
               let prettyData = try? JSONSerialization.data(
                   withJSONObject: object,
                   options: [.prettyPrinted, .sortedKeys]
               ),
               let prettyJSON = String(data: prettyData, encoding: .utf8)
            {
                return prettyJSON
            }

            if let text = String(data: data, encoding: .utf8) {
                return text
            }

            return "Binary body, \(WindshieldDisplayFormatter.byteCount(data.count)) captured."
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
#endif

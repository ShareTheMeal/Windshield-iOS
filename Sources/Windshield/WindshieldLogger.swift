import Foundation

#if DEBUG
    enum WindshieldLogEntry: @unchecked Sendable {
        case request(id: UUID, request: URLRequest)
        case response(
            id: UUID,
            request: URLRequest,
            response: HTTPURLResponse,
            body: Data,
            totalBodyByteCount: Int
        )
        case failure(id: UUID, request: URLRequest, error: Error)
    }

    protocol WindshieldLogging: AnyObject {
        func log(_ entry: WindshieldLogEntry)
    }

    final class WindshieldDisabledLogger: WindshieldLogging, @unchecked Sendable {
        static let shared = WindshieldDisabledLogger()

        private init() {}

        func log(_: WindshieldLogEntry) {}
    }

    enum WindshieldLogFormatter {
        static func format(_ entry: WindshieldLogEntry) -> String {
            switch entry {
            case let .request(id, request):
                requestDescription(id: id, request: request)

            case let .response(id, request, response, body, totalBodyByteCount):
                responseDescription(
                    id: id,
                    request: request,
                    response: response,
                    body: body,
                    totalBodyByteCount: totalBodyByteCount
                )

            case let .failure(id, request, error):
                failureDescription(id: id, request: request, error: error)
            }
        }

        private static func requestDescription(id: UUID, request: URLRequest) -> String {
            """
            [Windshield] Request \(id.uuidString)
            URL: \(request.url?.absoluteString ?? "<unknown>")
            Method: \(request.httpMethod ?? "GET")
            Headers:
            \(headerDescription(request.allHTTPHeaderFields ?? [:]))
            """
        }

        private static func responseDescription(
            id: UUID,
            request: URLRequest,
            response: HTTPURLResponse,
            body: Data,
            totalBodyByteCount: Int
        ) -> String {
            """
            [Windshield] Response \(id.uuidString)
            URL: \(response.url?.absoluteString ?? request.url?.absoluteString ?? "<unknown>")
            Status: \(response.statusCode)
            Headers:
            \(headerDescription(response.allHeaderFields))
            Payload:
            \(payloadDescription(body, totalBodyByteCount: totalBodyByteCount))
            """
        }

        private static func failureDescription(
            id: UUID,
            request: URLRequest,
            error: Error
        ) -> String {
            """
            [Windshield] Failure \(id.uuidString)
            URL: \(request.url?.absoluteString ?? "<unknown>")
            Error: \(error.localizedDescription)
            """
        }

        private static func headerDescription(_ headers: [AnyHashable: Any]) -> String {
            let lines = headers
                .map { key, value in (String(describing: key), String(describing: value)) }
                .sorted { left, right in
                    left.0.localizedCaseInsensitiveCompare(right.0) == .orderedAscending
                }
                .map { "  \($0.0): \($0.1)" }

            return lines.isEmpty ? "  <none>" : lines.joined(separator: "\n")
        }

        private static func headerDescription(_ headers: [String: String]) -> String {
            headerDescription(
                Dictionary(uniqueKeysWithValues: headers.map { (AnyHashable($0.key), $0.value) })
            )
        }

        private static func payloadDescription(
            _ body: Data,
            totalBodyByteCount: Int
        ) -> String {
            guard totalBodyByteCount > 0 else {
                return "  <empty>"
            }

            let sizeDescription = if body.count < totalBodyByteCount {
                "  Captured \(body.count) of \(totalBodyByteCount) bytes"
            } else {
                "  \(totalBodyByteCount) bytes"
            }

            let contents: String = if let text = String(data: body, encoding: .utf8) {
                text
            } else {
                "<binary payload>"
            }

            let truncationNotice = body.count < totalBodyByteCount ? "\n  [truncated]" : ""
            return "\(sizeDescription)\n\(contents)\(truncationNotice)"
        }
    }
#endif

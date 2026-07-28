import Foundation

#if DEBUG
    struct WindshieldHeader: Equatable {
        let name: String
        let value: String
    }

    struct WindshieldBodyCapture: Equatable {
        enum Contents: Equatable {
            case bytes(Data)
            case unavailable(UnavailableReason)
        }

        enum UnavailableReason: String, Equatable {
            case bodyStream
            case discardedByRetentionPolicy
        }

        var contents: Contents
        let totalByteCount: Int?

        var capturedByteCount: Int {
            guard case let .bytes(data) = contents else {
                return 0
            }

            return data.count
        }

        var isTruncated: Bool {
            guard let totalByteCount else {
                return false
            }

            return capturedByteCount < totalByteCount
        }

        static func capture(
            _ data: Data,
            totalByteCount: Int? = nil,
            maximumByteCount: Int
        ) -> WindshieldBodyCapture {
            let capturedData = Data(data.prefix(maximumByteCount))
            return WindshieldBodyCapture(
                contents: .bytes(capturedData),
                totalByteCount: totalByteCount ?? data.count
            )
        }

        static func unavailable(
            _ reason: UnavailableReason,
            totalByteCount: Int?
        ) -> WindshieldBodyCapture {
            WindshieldBodyCapture(
                contents: .unavailable(reason),
                totalByteCount: totalByteCount
            )
        }
    }

    struct WindshieldRequestSnapshot: Equatable {
        var body: WindshieldBodyCapture
        let url: URL?
        let method: String
        let headers: [WindshieldHeader]

        init(request: URLRequest, maximumBodyByteCount: Int) {
            url = request.url
            method = request.httpMethod ?? "GET"
            headers = Self.sortedHeaders(request.allHTTPHeaderFields ?? [:])

            if let data = request.httpBody {
                body = .capture(data, maximumByteCount: maximumBodyByteCount)
            } else if request.httpBodyStream != nil {
                body = .unavailable(
                    .bodyStream,
                    totalByteCount: Self.contentLength(from: request)
                )
            } else {
                body = .capture(Data(), maximumByteCount: maximumBodyByteCount)
            }
        }

        private static func sortedHeaders(
            _ headers: [String: String]
        ) -> [WindshieldHeader] {
            headers
                .map(WindshieldHeader.init)
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
        }

        private static func contentLength(from request: URLRequest) -> Int? {
            guard
                let value = request.value(forHTTPHeaderField: "Content-Length"),
                let length = Int(value),
                length >= 0
            else {
                return nil
            }

            return length
        }
    }

    struct WindshieldResponseSnapshot: Equatable {
        var body: WindshieldBodyCapture?
        let url: URL?
        let statusCode: Int
        let headers: [WindshieldHeader]
        let expectedBodyByteCount: Int?

        init(response: HTTPURLResponse) {
            body = nil
            url = response.url
            statusCode = response.statusCode
            headers = response.allHeaderFields
                .map {
                    WindshieldHeader(
                        name: String(describing: $0.key),
                        value: String(describing: $0.value)
                    )
                }
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }

            let expectedLength = response.expectedContentLength
            expectedBodyByteCount = expectedLength >= 0 ? Int(expectedLength) : nil
        }
    }

    struct WindshieldFailure: Equatable {
        private static let maximumDescriptionLength = 2048

        let domain: String
        let code: Int
        let message: String

        init(error: Error) {
            let error = error as NSError
            domain = error.domain
            code = error.code
            message = String(
                error.localizedDescription.prefix(Self.maximumDescriptionLength)
            )
        }
    }

    enum WindshieldTransactionState: Equatable {
        case inFlight
        case completed
        case failed(WindshieldFailure)
        case cancelled
        case redirected(to: URL?)
    }

    struct WindshieldTransaction: Identifiable, Equatable {
        let id: UUID
        var request: WindshieldRequestSnapshot
        var response: WindshieldResponseSnapshot?
        var state: WindshieldTransactionState
        let startedAt: Date
        var endedAt: Date?

        var duration: TimeInterval? {
            guard let endedAt else {
                return nil
            }

            return max(0, endedAt.timeIntervalSince(startedAt))
        }

        var isTerminal: Bool {
            state != .inFlight
        }

        var isError: Bool {
            if case .failed = state {
                return true
            }

            guard let statusCode = response?.statusCode else {
                return false
            }

            return statusCode >= 400
        }
    }

    enum WindshieldTransactionEvent {
        case started(
            id: UUID,
            request: WindshieldRequestSnapshot,
            at: Date
        )
        case receivedResponse(
            id: UUID,
            response: WindshieldResponseSnapshot
        )
        case completed(
            id: UUID,
            body: WindshieldBodyCapture,
            at: Date
        )
        case failed(
            id: UUID,
            body: WindshieldBodyCapture,
            failure: WindshieldFailure,
            at: Date
        )
        case cancelled(
            id: UUID,
            body: WindshieldBodyCapture,
            at: Date
        )
        case redirected(
            id: UUID,
            response: WindshieldResponseSnapshot,
            body: WindshieldBodyCapture,
            destination: URL?,
            at: Date
        )
    }
#endif

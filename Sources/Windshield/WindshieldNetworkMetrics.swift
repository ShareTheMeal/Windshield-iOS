import Foundation

#if DEBUG
    /// An immutable snapshot of URL loading timings collected for one task.
    ///
    /// `URLSessionTaskMetrics` and its transaction metrics are Foundation reference
    /// types. This value copies the fields Windshield retains at the delegate
    /// boundary, so the recorder never shares those mutable Foundation objects
    /// across queues.
    struct WindshieldNetworkMetrics: Sendable, Equatable {
        static let slowThreshold: TimeInterval = 1

        struct Interval: Sendable, Equatable {
            /// Seconds from the beginning of the task interval.
            let startOffset: TimeInterval
            let duration: TimeInterval

            var endOffset: TimeInterval {
                startOffset + duration
            }

            fileprivate static func normalized(
                start: Date?,
                end: Date?,
                taskStart: Date?
            ) -> Interval? {
                guard let start, let end, let taskStart else {
                    return nil
                }

                let startOffset = start.timeIntervalSince(taskStart)
                let duration = end.timeIntervalSince(start)
                guard startOffset >= 0, duration >= 0 else {
                    return nil
                }

                return Interval(startOffset: startOffset, duration: duration)
            }
        }

        struct Phases: Sendable, Equatable {
            let dns: Interval?
            let connect: Interval?
            let tls: Interval?
            let request: Interval?
            let waiting: Interval?
            let response: Interval?

            fileprivate init(raw: Raw.Attempt, taskStart: Date?) {
                dns = .normalized(
                    start: raw.domainLookupStartDate,
                    end: raw.domainLookupEndDate,
                    taskStart: taskStart
                )
                connect = .normalized(
                    start: raw.connectStartDate,
                    end: raw.connectEndDate,
                    taskStart: taskStart
                )
                tls = .normalized(
                    start: raw.secureConnectionStartDate,
                    end: raw.secureConnectionEndDate,
                    taskStart: taskStart
                )
                request = .normalized(
                    start: raw.requestStartDate,
                    end: raw.requestEndDate,
                    taskStart: taskStart
                )
                waiting = .normalized(
                    start: raw.requestEndDate ?? raw.requestStartDate,
                    end: raw.responseStartDate,
                    taskStart: taskStart
                )
                response = .normalized(
                    start: raw.responseStartDate,
                    end: raw.responseEndDate,
                    taskStart: taskStart
                )
            }

            fileprivate var all: [Interval] {
                [dns, connect, tls, request, waiting, response].compactMap { $0 }
            }
        }

        struct ByteCounts: Sendable, Equatable {
            let requestHeaderBytesSent: Int64
            let requestBodyBytesSent: Int64
            let requestBodyBytesBeforeEncoding: Int64
            let responseHeaderBytesReceived: Int64
            let responseBodyBytesReceived: Int64
            let responseBodyBytesAfterDecoding: Int64

            var totalBytesSent: Int64 {
                requestHeaderBytesSent + requestBodyBytesSent
            }

            var totalBytesReceived: Int64 {
                responseHeaderBytesReceived + responseBodyBytesReceived
            }
        }

        enum FetchType: String, Sendable, Equatable {
            case unknown
            case networkLoad
            case serverPush
            case localCache
        }

        struct Attempt: Sendable, Equatable {
            let host: String?
            let phases: Phases
            let byteCounts: ByteCounts
            let fetchType: FetchType
            let networkProtocolName: String?
            let isProxyConnection: Bool
            let isReusedConnection: Bool

            fileprivate init(raw: Raw.Attempt, taskStart: Date?) {
                host = raw.url?.host?.lowercased()
                phases = Phases(raw: raw, taskStart: taskStart)
                byteCounts = ByteCounts(
                    requestHeaderBytesSent: raw.requestHeaderBytesSent,
                    requestBodyBytesSent: raw.requestBodyBytesSent,
                    requestBodyBytesBeforeEncoding: raw.requestBodyBytesBeforeEncoding,
                    responseHeaderBytesReceived: raw.responseHeaderBytesReceived,
                    responseBodyBytesReceived: raw.responseBodyBytesReceived,
                    responseBodyBytesAfterDecoding: raw.responseBodyBytesAfterDecoding
                )
                fetchType = raw.fetchType
                networkProtocolName = raw.networkProtocolName
                isProxyConnection = raw.isProxyConnection
                isReusedConnection = raw.isReusedConnection
            }

            /// The elapsed envelope of observed phases. Overlapping phases are not
            /// double-counted.
            var observedDuration: TimeInterval? {
                let phases = phases.all
                guard
                    let earliest = phases.map(\.startOffset).min(),
                    let latest = phases.map(\.endOffset).max()
                else {
                    return nil
                }

                return latest - earliest
            }

            fileprivate var latestObservedEndOffset: TimeInterval? {
                phases.all.map(\.endOffset).max()
            }
        }

        /// Test-only-friendly input that mirrors the Foundation values copied by
        /// `init(metrics:)`. Dates are discarded after construction.
        struct Raw: Sendable, Equatable {
            struct Attempt: Sendable, Equatable {
                let url: URL?
                let domainLookupStartDate: Date?
                let domainLookupEndDate: Date?
                let connectStartDate: Date?
                let connectEndDate: Date?
                let secureConnectionStartDate: Date?
                let secureConnectionEndDate: Date?
                let requestStartDate: Date?
                let requestEndDate: Date?
                let responseStartDate: Date?
                let responseEndDate: Date?
                let requestHeaderBytesSent: Int64
                let requestBodyBytesSent: Int64
                let requestBodyBytesBeforeEncoding: Int64
                let responseHeaderBytesReceived: Int64
                let responseBodyBytesReceived: Int64
                let responseBodyBytesAfterDecoding: Int64
                let fetchType: FetchType
                let networkProtocolName: String?
                let isProxyConnection: Bool
                let isReusedConnection: Bool

                init(
                    url: URL? = nil,
                    domainLookupStartDate: Date? = nil,
                    domainLookupEndDate: Date? = nil,
                    connectStartDate: Date? = nil,
                    connectEndDate: Date? = nil,
                    secureConnectionStartDate: Date? = nil,
                    secureConnectionEndDate: Date? = nil,
                    requestStartDate: Date? = nil,
                    requestEndDate: Date? = nil,
                    responseStartDate: Date? = nil,
                    responseEndDate: Date? = nil,
                    requestHeaderBytesSent: Int64 = 0,
                    requestBodyBytesSent: Int64 = 0,
                    requestBodyBytesBeforeEncoding: Int64 = 0,
                    responseHeaderBytesReceived: Int64 = 0,
                    responseBodyBytesReceived: Int64 = 0,
                    responseBodyBytesAfterDecoding: Int64 = 0,
                    fetchType: FetchType = .unknown,
                    networkProtocolName: String? = nil,
                    isProxyConnection: Bool = false,
                    isReusedConnection: Bool = false
                ) {
                    self.url = url
                    self.domainLookupStartDate = domainLookupStartDate
                    self.domainLookupEndDate = domainLookupEndDate
                    self.connectStartDate = connectStartDate
                    self.connectEndDate = connectEndDate
                    self.secureConnectionStartDate = secureConnectionStartDate
                    self.secureConnectionEndDate = secureConnectionEndDate
                    self.requestStartDate = requestStartDate
                    self.requestEndDate = requestEndDate
                    self.responseStartDate = responseStartDate
                    self.responseEndDate = responseEndDate
                    self.requestHeaderBytesSent = requestHeaderBytesSent
                    self.requestBodyBytesSent = requestBodyBytesSent
                    self.requestBodyBytesBeforeEncoding = requestBodyBytesBeforeEncoding
                    self.responseHeaderBytesReceived = responseHeaderBytesReceived
                    self.responseBodyBytesReceived = responseBodyBytesReceived
                    self.responseBodyBytesAfterDecoding = responseBodyBytesAfterDecoding
                    self.fetchType = fetchType
                    self.networkProtocolName = networkProtocolName
                    self.isProxyConnection = isProxyConnection
                    self.isReusedConnection = isReusedConnection
                }
            }

            let taskStartDate: Date?
            let taskEndDate: Date?
            let redirectCount: Int
            let attempts: [Attempt]

            init(
                taskStartDate: Date?,
                taskEndDate: Date?,
                redirectCount: Int = 0,
                attempts: [Attempt] = []
            ) {
                self.taskStartDate = taskStartDate
                self.taskEndDate = taskEndDate
                self.redirectCount = redirectCount
                self.attempts = attempts
            }
        }

        let taskInterval: Interval?
        let redirectCount: Int
        let attempts: [Attempt]

        init(raw: Raw) {
            taskInterval = .normalized(
                start: raw.taskStartDate,
                end: raw.taskEndDate,
                taskStart: raw.taskStartDate
            )
            redirectCount = max(0, raw.redirectCount)
            attempts = raw.attempts.map { Attempt(raw: $0, taskStart: raw.taskStartDate) }
        }

        init(metrics: URLSessionTaskMetrics) {
            self.init(
                raw: Raw(
                    taskStartDate: metrics.taskInterval.start,
                    taskEndDate: metrics.taskInterval.end,
                    redirectCount: metrics.redirectCount,
                    attempts: metrics.transactionMetrics.map {
                        Raw.Attempt(
                            url: $0.request.url,
                            domainLookupStartDate: $0.domainLookupStartDate,
                            domainLookupEndDate: $0.domainLookupEndDate,
                            connectStartDate: $0.connectStartDate,
                            connectEndDate: $0.connectEndDate,
                            secureConnectionStartDate: $0.secureConnectionStartDate,
                            secureConnectionEndDate: $0.secureConnectionEndDate,
                            requestStartDate: $0.requestStartDate,
                            requestEndDate: $0.requestEndDate,
                            responseStartDate: $0.responseStartDate,
                            responseEndDate: $0.responseEndDate,
                            requestHeaderBytesSent: $0.countOfRequestHeaderBytesSent,
                            requestBodyBytesSent: $0.countOfRequestBodyBytesSent,
                            requestBodyBytesBeforeEncoding: $0.countOfRequestBodyBytesBeforeEncoding,
                            responseHeaderBytesReceived: $0.countOfResponseHeaderBytesReceived,
                            responseBodyBytesReceived: $0.countOfResponseBodyBytesReceived,
                            responseBodyBytesAfterDecoding: $0.countOfResponseBodyBytesAfterDecoding,
                            fetchType: Self.fetchType(from: $0.resourceFetchType),
                            networkProtocolName: $0.networkProtocolName,
                            isProxyConnection: $0.isProxyConnection,
                            isReusedConnection: $0.isReusedConnection
                        )
                    }
                )
            )
        }

        var taskDuration: TimeInterval? {
            taskInterval?.duration
        }

        /// The task interval when available, otherwise the final observed phase.
        var observedDuration: TimeInterval? {
            taskDuration ?? attempts.compactMap(\.latestObservedEndOffset).max()
        }

        func isSlow(threshold: TimeInterval = WindshieldNetworkMetrics.slowThreshold) -> Bool {
            guard threshold >= 0, let observedDuration else {
                return false
            }

            return observedDuration >= threshold
        }

        private static func fetchType(
            from fetchType: URLSessionTaskMetrics.ResourceFetchType
        ) -> FetchType {
            switch fetchType {
            case .unknown:
                .unknown
            case .networkLoad:
                .networkLoad
            case .serverPush:
                .serverPush
            case .localCache:
                .localCache
            @unknown default:
                .unknown
            }
        }
    }
#endif

#if DEBUG && os(iOS)
    import Foundation
    import SwiftUI

    struct WindshieldInspectorViewPreviews: PreviewProvider {
        @MainActor
        static var previews: some View {
            WindshieldInspectorView(store: previewStore)
        }

        @MainActor
        private static var previewStore: WindshieldStore {
            WindshieldStore(
                transactions: [
                    transaction(
                        method: "POST",
                        path: "/v1/donations",
                        statusCode: 201,
                        state: .completed,
                        duration: 1.4
                    ),
                    transaction(
                        method: "GET",
                        path: "/v1/campaigns",
                        statusCode: 503,
                        state: .completed,
                        duration: 0.72
                    ),
                    transaction(
                        method: "PATCH",
                        path: "/v1/profile",
                        statusCode: nil,
                        state: .inFlight,
                        duration: nil
                    ),
                ]
            )
        }

        private static func transaction(
            method: String,
            path: String,
            statusCode: Int?,
            state: WindshieldTransactionState,
            duration: TimeInterval?
        ) -> WindshieldTransaction {
            let url = URL(string: "https://api.example.com\(path)")!
            var request = URLRequest(url: url)
            request.httpMethod = method

            let response = statusCode.map {
                var snapshot = WindshieldResponseSnapshot(
                    response: HTTPURLResponse(
                        url: url,
                        statusCode: $0,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
                snapshot.body = .capture(
                    Data("{\"preview\":true}".utf8),
                    maximumByteCount: 1024
                )
                return snapshot
            }

            let startedAt = Date().addingTimeInterval(-2)
            return WindshieldTransaction(
                id: UUID(),
                request: WindshieldRequestSnapshot(
                    request: request,
                    maximumBodyByteCount: 1024
                ),
                response: response,
                state: state,
                startedAt: startedAt,
                endedAt: duration.map(startedAt.addingTimeInterval),
                networkMetrics: duration.map {
                    previewMetrics(url: url, duration: $0)
                }
            )
        }

        private static func previewMetrics(
            url: URL,
            duration: TimeInterval
        ) -> WindshieldNetworkMetrics {
            let start = Date(timeIntervalSince1970: 1_000)
            return WindshieldNetworkMetrics(
                raw: .init(
                    taskStartDate: start,
                    taskEndDate: start.addingTimeInterval(duration),
                    attempts: [
                        .init(
                            url: url,
                            domainLookupStartDate: start.addingTimeInterval(0.02),
                            domainLookupEndDate: start.addingTimeInterval(0.05),
                            connectStartDate: start.addingTimeInterval(0.05),
                            connectEndDate: start.addingTimeInterval(0.16),
                            secureConnectionStartDate: start.addingTimeInterval(0.08),
                            secureConnectionEndDate: start.addingTimeInterval(0.15),
                            requestStartDate: start.addingTimeInterval(0.17),
                            requestEndDate: start.addingTimeInterval(0.2),
                            responseStartDate: start.addingTimeInterval(
                                max(0.21, duration - 0.2)
                            ),
                            responseEndDate: start.addingTimeInterval(duration),
                            requestHeaderBytesSent: 380,
                            responseHeaderBytesReceived: 240,
                            responseBodyBytesReceived: 16,
                            responseBodyBytesAfterDecoding: 16,
                            fetchType: .networkLoad,
                            networkProtocolName: "h2"
                        ),
                    ]
                )
            )
        }
    }
#endif

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
                        state: .completed
                    ),
                    transaction(
                        method: "GET",
                        path: "/v1/campaigns",
                        statusCode: 503,
                        state: .completed
                    ),
                    transaction(
                        method: "PATCH",
                        path: "/v1/profile",
                        statusCode: nil,
                        state: .inFlight
                    ),
                ]
            )
        }

        private static func transaction(
            method: String,
            path: String,
            statusCode: Int?,
            state: WindshieldTransactionState
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
                endedAt: state == .inFlight ? nil : startedAt.addingTimeInterval(0.42)
            )
        }
    }
#endif

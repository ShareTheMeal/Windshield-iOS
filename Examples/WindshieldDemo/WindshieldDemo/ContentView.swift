import Foundation
import SwiftUI

#if DEBUG
    import Windshield
#endif

struct ContentView: View {
    let session: URLSession
    let sampleURL: URL

    @State private var isInspectorPresented = false
    @State private var isLoading = false
    @State private var result = "No request has been sent yet."

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button {
                        Task {
                            await sendSampleRequest()
                        }
                    } label: {
                        HStack {
                            Text("Send sample GET")
                            Spacer()
                            if isLoading {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isLoading)

                    Text(result)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Network")
                } footer: {
                    Text("The demo calls \(sampleURL.absoluteString) using an instrumented URLSession.")
                }

                #if DEBUG
                    Section {
                        Button("Open Windshield") {
                            isInspectorPresented = true
                        }
                    } footer: {
                        Text("Windshield is linked and presented only in Debug builds.")
                    }
                #endif
            }
            .navigationTitle("Windshield Demo")
        }
        .navigationViewStyle(.stack)
        #if DEBUG
            .sheet(isPresented: $isInspectorPresented) {
                WindshieldInspectorView()
            }
        #endif
    }

    @MainActor
    private func sendSampleRequest() async {
        isLoading = true
        result = "Request in progress..."

        defer {
            isLoading = false
        }

        do {
            let (data, response) = try await session.data(from: sampleURL)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let status = statusCode.map(String.init) ?? "unknown"
            result = "HTTP \(status), \(data.count) bytes received."
        } catch {
            result = "Request failed: \(error.localizedDescription)"
        }
    }
}

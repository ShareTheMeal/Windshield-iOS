#if DEBUG && os(iOS)
    import Foundation
    import SwiftUI

    @MainActor
    public struct WindshieldInspectorView: View {
        @Environment(\.dismiss) private var dismiss
        @ObservedObject private var store: WindshieldStore
        @State private var searchText = ""
        @State private var selectedFilter = WindshieldTrafficFilter.all
        @State private var isConfirmingClear = false

        public init() {
            _store = ObservedObject(wrappedValue: WindshieldStore.shared)
        }

        init(store: WindshieldStore) {
            _store = ObservedObject(wrappedValue: store)
        }

        private var visibleTransactions: [WindshieldTransaction] {
            store.transactions.filter {
                WindshieldTransactionQuery.matches(
                    $0,
                    filter: selectedFilter,
                    searchText: searchText
                )
            }
        }

        private var hostLatencySummaries: [WindshieldHostLatencySummary] {
            WindshieldPerformanceSummary.slowestHosts(in: store.transactions)
        }

        public var body: some View {
            NavigationView {
                List {
                    WindshieldTrafficSummaryView(transactions: store.transactions)
                        .listRowSeparator(.hidden)

                    WindshieldFilterBar(selection: $selectedFilter)
                        .listRowSeparator(.hidden)

                    WindshieldHostLatencyView(summaries: hostLatencySummaries)
                        .listRowSeparator(.hidden)

                    if visibleTransactions.isEmpty {
                        emptyState
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(visibleTransactions) { transaction in
                            NavigationLink {
                                WindshieldTransactionDetailView(
                                    transactionID: transaction.id,
                                    store: store
                                )
                            } label: {
                                WindshieldTransactionRow(transaction: transaction)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .navigationTitle("Windshield")
                .navigationBarTitleDisplayMode(.large)
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search traffic"
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear") {
                            isConfirmingClear = true
                        }
                        .disabled(store.transactions.isEmpty)
                    }
                }
                .confirmationDialog(
                    "Clear all captured traffic?",
                    isPresented: $isConfirmingClear,
                    titleVisibility: .visible
                ) {
                    Button("Clear Traffic", role: .destructive) {
                        store.clear()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes every request currently held in memory.")
                }
            }
            .navigationViewStyle(.stack)
        }

        @ViewBuilder
        private var emptyState: some View {
            if store.transactions.isEmpty {
                WindshieldEmptyState(
                    title: "No traffic yet",
                    message: "Make a network request after starting Windshield.",
                    systemImage: "network"
                )
            } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                WindshieldEmptyState(
                    title: "No matching requests",
                    message: "Try another method, host, path, status, or error.",
                    systemImage: "magnifyingglass"
                )
            } else if selectedFilter == .errors {
                WindshieldEmptyState(
                    title: "No errors",
                    message: "Failed requests and HTTP errors will appear here.",
                    systemImage: "checkmark.circle"
                )
            } else if selectedFilter == .active {
                WindshieldEmptyState(
                    title: "No active requests",
                    message: "Requests in progress will appear here.",
                    systemImage: "clock"
                )
            } else {
                WindshieldEmptyState(
                    title: "No slow requests",
                    message: "Completed requests taking at least one second will appear here.",
                    systemImage: "timer"
                )
            }
        }
    }
#endif

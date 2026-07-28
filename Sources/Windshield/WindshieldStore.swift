import Combine
import Foundation

#if DEBUG
    struct WindshieldRetentionPolicy: Equatable {
        static let defaultMaximumTransactionCount = 100
        static let defaultMaximumTotalBodyByteCount = 20 * 1024 * 1024

        let maximumTransactionCount: Int
        let maximumTotalBodyByteCount: Int

        init(
            maximumTransactionCount: Int = Self.defaultMaximumTransactionCount,
            maximumTotalBodyByteCount: Int = Self.defaultMaximumTotalBodyByteCount
        ) {
            self.maximumTransactionCount = max(1, maximumTransactionCount)
            self.maximumTotalBodyByteCount = max(0, maximumTotalBodyByteCount)
        }
    }

    struct WindshieldTransactionReducer {
        private(set) var transactions: [WindshieldTransaction] = []
        private(set) var policy: WindshieldRetentionPolicy

        init(policy: WindshieldRetentionPolicy = WindshieldRetentionPolicy()) {
            self.policy = policy
        }

        @discardableResult
        mutating func reduce(_ event: WindshieldTransactionEvent) -> Bool {
            let didChange = apply(event)
            guard didChange else {
                return false
            }

            enforceRetentionPolicy()
            return true
        }

        @discardableResult
        mutating func updatePolicy(_ policy: WindshieldRetentionPolicy) -> Bool {
            guard self.policy != policy else {
                return false
            }

            self.policy = policy
            enforceRetentionPolicy()
            return true
        }

        @discardableResult
        mutating func clear() -> Bool {
            guard !transactions.isEmpty else {
                return false
            }

            transactions.removeAll(keepingCapacity: false)
            return true
        }

        private mutating func apply(_ event: WindshieldTransactionEvent) -> Bool {
            switch event {
            case let .started(id, request, startedAt):
                guard !transactions.contains(where: { $0.id == id }) else {
                    return false
                }

                transactions.insert(
                    WindshieldTransaction(
                        id: id,
                        request: request,
                        response: nil,
                        state: .inFlight,
                        startedAt: startedAt,
                        endedAt: nil
                    ),
                    at: 0
                )
                return true

            case let .receivedResponse(id, response):
                guard let index = activeTransactionIndex(for: id) else {
                    return false
                }

                transactions[index].response = response
                return true

            case let .completed(id, body, endedAt):
                return finish(id: id, body: body, state: .completed, at: endedAt)

            case let .failed(id, body, failure, endedAt):
                return finish(id: id, body: body, state: .failed(failure), at: endedAt)

            case let .cancelled(id, body, endedAt):
                return finish(id: id, body: body, state: .cancelled, at: endedAt)

            case let .redirected(id, response, body, destination, endedAt):
                guard let index = activeTransactionIndex(for: id) else {
                    return false
                }

                var finalResponse = response
                finalResponse.body = body
                transactions[index].response = finalResponse
                transactions[index].state = .redirected(to: destination)
                transactions[index].endedAt = endedAt
                return true
            }
        }

        private func activeTransactionIndex(for id: UUID) -> Int? {
            guard let index = transactions.firstIndex(where: { $0.id == id }) else {
                return nil
            }

            guard transactions[index].state == .inFlight else {
                return nil
            }

            return index
        }

        private mutating func finish(
            id: UUID,
            body: WindshieldBodyCapture,
            state: WindshieldTransactionState,
            at endedAt: Date
        ) -> Bool {
            guard let index = activeTransactionIndex(for: id) else {
                return false
            }

            transactions[index].response?.body = body
            transactions[index].state = state
            transactions[index].endedAt = endedAt
            return true
        }

        private mutating func enforceRetentionPolicy() {
            enforceTransactionCount()
            enforceTotalBodyByteCount()
        }

        private mutating func enforceTransactionCount() {
            while transactions.count > policy.maximumTransactionCount {
                if let index = transactions.lastIndex(where: \.isTerminal) {
                    transactions.remove(at: index)
                } else {
                    transactions.removeLast()
                }
            }
        }

        private mutating func enforceTotalBodyByteCount() {
            var retainedByteCount = totalRetainedBodyByteCount

            while retainedByteCount > policy.maximumTotalBodyByteCount {
                guard let location = oldestRetainedBodyLocation() else {
                    return
                }

                let removedByteCount = discardBody(at: location)
                retainedByteCount -= removedByteCount
            }
        }

        private var totalRetainedBodyByteCount: Int {
            transactions.reduce(into: 0) { count, transaction in
                count += transaction.request.body.capturedByteCount
                count += transaction.response?.body?.capturedByteCount ?? 0
            }
        }

        private enum BodyLocation {
            case request(Int)
            case response(Int)
        }

        private func oldestRetainedBodyLocation() -> BodyLocation? {
            let terminalIndices = transactions.indices.reversed().filter {
                transactions[$0].isTerminal
            }
            let activeIndices = transactions.indices.reversed().filter {
                !transactions[$0].isTerminal
            }

            for index in terminalIndices + activeIndices {
                if let body = transactions[index].response?.body,
                   body.capturedByteCount > 0
                {
                    return .response(index)
                }

                if transactions[index].request.body.capturedByteCount > 0 {
                    return .request(index)
                }
            }

            return nil
        }

        private mutating func discardBody(at location: BodyLocation) -> Int {
            switch location {
            case let .request(index):
                let body = transactions[index].request.body
                transactions[index].request.body = .unavailable(
                    .discardedByRetentionPolicy,
                    totalByteCount: body.totalByteCount
                )
                return body.capturedByteCount

            case let .response(index):
                guard let body = transactions[index].response?.body else {
                    return 0
                }

                transactions[index].response?.body = .unavailable(
                    .discardedByRetentionPolicy,
                    totalByteCount: body.totalByteCount
                )
                return body.capturedByteCount
            }
        }
    }

    @MainActor
    final class WindshieldStore: ObservableObject {
        static let shared = WindshieldStore()

        @Published private(set) var transactions: [WindshieldTransaction] = []
        private var latestRevision = 0

        init(transactions: [WindshieldTransaction] = []) {
            self.transactions = transactions
        }

        func clear() {
            WindshieldTransactionRecorder.shared.clear()
        }

        fileprivate func publish(
            transactions: [WindshieldTransaction],
            revision: Int
        ) {
            guard revision > latestRevision else {
                return
            }

            latestRevision = revision
            self.transactions = transactions
        }
    }

    protocol WindshieldRecording: AnyObject {
        func record(_ event: WindshieldTransactionEvent)
    }

    /// Reducer state is isolated on `queue`. Publication state is protected by
    /// `publicationLock`, and observable store updates are delivered on the main actor.
    final class WindshieldTransactionRecorder: WindshieldRecording, @unchecked Sendable {
        static let shared = WindshieldTransactionRecorder()

        private struct Publication {
            let transactions: [WindshieldTransaction]
            let revision: Int
        }

        private let queue = DispatchQueue(
            label: "dev.windshield.transaction-recorder",
            qos: .utility
        )
        private let publicationLock = NSLock()
        private let publicationSource: DispatchSourceUserDataAdd
        private var reducer = WindshieldTransactionReducer()
        private var revision = 0
        private var pendingPublication: Publication?

        private init() {
            let source = DispatchSource.makeUserDataAddSource(queue: .main)
            publicationSource = source
            source.setEventHandler { [weak self] in
                dispatchPrecondition(condition: .onQueue(.main))
                Task { @MainActor in
                    self?.publishPendingSnapshotOnMainActor()
                }
            }
            source.activate()
        }

        func record(_ event: WindshieldTransactionEvent) {
            queue.async { [self] in
                guard reducer.reduce(event) else {
                    return
                }

                publishCurrentSnapshot()
            }
        }

        func configure(maximumTransactionCount: Int) {
            queue.async { [self] in
                let policy = WindshieldRetentionPolicy(
                    maximumTransactionCount: maximumTransactionCount
                )
                guard reducer.updatePolicy(policy) else {
                    return
                }

                publishCurrentSnapshot()
            }
        }

        func clear() {
            queue.async { [self] in
                guard reducer.clear() else {
                    return
                }

                publishCurrentSnapshot()
            }
        }

        func flush() async {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let publication = Publication(
                        transactions: reducer.transactions,
                        revision: revision
                    )

                    // Publish directly so flush does not depend on dispatch source timing.
                    DispatchQueue.main.async { [self] in
                        discardPendingPublication(upTo: publication.revision)
                        publish(publication)
                        continuation.resume()
                    }
                }
            }
        }

        private func publishCurrentSnapshot() {
            revision += 1
            let publication = Publication(
                transactions: reducer.transactions,
                revision: revision
            )

            publicationLock.lock()
            pendingPublication = publication
            publicationLock.unlock()

            // The source data is only a wake signal. The lock holds the latest snapshot.
            publicationSource.add(data: 1)
        }

        @MainActor
        private func publishPendingSnapshotOnMainActor() {
            publicationLock.lock()
            let publication = pendingPublication
            pendingPublication = nil
            publicationLock.unlock()

            if let publication {
                publish(publication)
            }
        }

        private func discardPendingPublication(upTo revision: Int) {
            publicationLock.lock()
            if let pendingPublication,
               pendingPublication.revision <= revision
            {
                self.pendingPublication = nil
            }
            publicationLock.unlock()
        }

        @MainActor
        private func publish(_ publication: Publication) {
            WindshieldStore.shared.publish(
                transactions: publication.transactions,
                revision: publication.revision
            )
        }
    }
#endif

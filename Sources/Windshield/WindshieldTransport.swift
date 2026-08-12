import Foundation

#if DEBUG
    protocol WindshieldTransportObserver: AnyObject {
        func transportDidReceive(_ response: URLResponse)
        func transportDidReceive(_ data: Data)
        func transportDidCollect(_ metrics: WindshieldNetworkMetrics)
        func transportDidComplete(with error: Error?)
        func transportDidRedirect(to request: URLRequest, response: HTTPURLResponse)
    }

    protocol WindshieldTransportTask: AnyObject {
        func resume()
        func cancel()
    }

    protocol WindshieldTransporting: AnyObject {
        func makeTask(
            for request: URLRequest,
            observer: WindshieldTransportObserver
        ) -> WindshieldTransportTask
    }

    /// The observer map is protected by `lock`. URLSession delegate callbacks run on
    /// the single-operation delegate queue, and the shared session is immutable after
    /// initialization. Authentication challenges use the internal session's default
    /// handling because URLProtocol does not expose the originating session delegate.
    final class WindshieldURLSessionTransport: NSObject,
        WindshieldTransporting,
        @unchecked Sendable
    {
        static let shared = WindshieldURLSessionTransport()

        private struct TaskRecord {
            let observer: WindshieldTransportObserver
            var suppressesCompletion = false
        }

        private let lock = NSLock()
        private let delegateQueue: OperationQueue
        private var taskRecords: [Int: TaskRecord] = [:]
        private var session: URLSession!

        override private init() {
            let queue = OperationQueue()
            queue.name = "dev.windshield.url-session-transport"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .utility
            delegateQueue = queue

            super.init()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = configuration.protocolClasses?.filter {
                ObjectIdentifier($0) != ObjectIdentifier(WindshieldURLProtocol.self)
            }
            session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: delegateQueue
            )
        }

        func makeTask(
            for request: URLRequest,
            observer: WindshieldTransportObserver
        ) -> WindshieldTransportTask {
            let task = session.dataTask(with: request)

            lock.lock()
            taskRecords[task.taskIdentifier] = TaskRecord(observer: observer)
            lock.unlock()

            return WindshieldURLSessionTask(task: task, transport: self)
        }

        fileprivate func cancel(_ task: URLSessionDataTask) {
            suppressCompletion(for: task)

            task.cancel()
        }

        @discardableResult
        private func suppressCompletion(
            for task: URLSessionTask
        ) -> WindshieldTransportObserver? {
            lock.lock()
            defer { lock.unlock() }

            guard var record = taskRecords[task.taskIdentifier] else {
                return nil
            }

            record.suppressesCompletion = true
            taskRecords[task.taskIdentifier] = record
            return record.observer
        }

        private func observerForDelivery(
            for task: URLSessionTask
        ) -> WindshieldTransportObserver? {
            lock.lock()
            let record = taskRecords[task.taskIdentifier]
            lock.unlock()
            return record?.suppressesCompletion == false ? record?.observer : nil
        }

        private func observerForMetrics(
            for task: URLSessionTask
        ) -> WindshieldTransportObserver? {
            lock.lock()
            let observer = taskRecords[task.taskIdentifier]?.observer
            lock.unlock()
            return observer
        }

        private func removeRecord(for task: URLSessionTask) -> TaskRecord? {
            lock.lock()
            let record = taskRecords.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            return record
        }
    }

    extension WindshieldURLSessionTransport: URLSessionDataDelegate {
        func urlSession(
            _: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let observer = observerForDelivery(for: dataTask) else {
                completionHandler(.cancel)
                return
            }

            observer.transportDidReceive(response)
            completionHandler(.allow)
        }

        func urlSession(
            _: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            observerForDelivery(for: dataTask)?.transportDidReceive(data)
        }

        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            let snapshot = WindshieldNetworkMetrics(metrics: metrics)
            observerForMetrics(for: task)?.transportDidCollect(snapshot)
        }

        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            guard let record = removeRecord(for: task),
                  !record.suppressesCompletion
            else {
                return
            }

            record.observer.transportDidComplete(with: error)
        }

        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let observer = suppressCompletion(for: task)
            observer?.transportDidRedirect(to: request, response: response)
            completionHandler(nil)
        }
    }

    private final class WindshieldURLSessionTask: WindshieldTransportTask {
        private let task: URLSessionDataTask
        private weak var transport: WindshieldURLSessionTransport?

        init(task: URLSessionDataTask, transport: WindshieldURLSessionTransport) {
            self.task = task
            self.transport = transport
        }

        func resume() {
            task.resume()
        }

        func cancel() {
            guard let transport else {
                task.cancel()
                return
            }

            transport.cancel(task)
        }
    }
#endif

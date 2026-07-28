import Foundation

#if DEBUG
    protocol WindshieldTransportObserver: AnyObject {
        func transportDidReceive(_ response: URLResponse)
        func transportDidReceive(_ data: Data)
        func transportDidComplete(with error: Error?)
        func transportDidRedirect(to request: URLRequest, response: HTTPURLResponse)
        func transportDidReceive(
            _ challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        )
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

    final class WindshieldURLSessionTransport: NSObject,
        WindshieldTransporting,
        @unchecked Sendable
    {
        static let shared = WindshieldURLSessionTransport()

        private struct WeakObserver {
            weak var value: WindshieldTransportObserver?
        }

        private let lock = NSLock()
        private let delegateQueue: OperationQueue
        private var observers: [Int: WeakObserver] = [:]
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
            observers[task.taskIdentifier] = WeakObserver(value: observer)
            lock.unlock()

            return WindshieldURLSessionTask(task: task, transport: self)
        }

        fileprivate func cancel(_ task: URLSessionDataTask) {
            lock.lock()
            observers.removeValue(forKey: task.taskIdentifier)
            lock.unlock()

            task.cancel()
        }

        private func observer(for task: URLSessionTask) -> WindshieldTransportObserver? {
            lock.lock()
            let observer = observers[task.taskIdentifier]?.value
            lock.unlock()
            return observer
        }

        private func removeObserver(for task: URLSessionTask) -> WindshieldTransportObserver? {
            lock.lock()
            let observer = observers.removeValue(forKey: task.taskIdentifier)?.value
            lock.unlock()
            return observer
        }
    }

    extension WindshieldURLSessionTransport: URLSessionDataDelegate {
        func urlSession(
            _: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let observer = observer(for: dataTask) else {
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
            observer(for: dataTask)?.transportDidReceive(data)
        }

        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            removeObserver(for: task)?.transportDidComplete(with: error)
        }

        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let observer = removeObserver(for: task)
            observer?.transportDidRedirect(to: request, response: response)
            completionHandler(nil)
        }

        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let observer = observer(for: task) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            observer.transportDidReceive(challenge, completionHandler: completionHandler)
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

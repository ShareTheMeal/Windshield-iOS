import Foundation

#if DEBUG
    /// Installs Windshield's development-only HTTP interception.
    public enum Windshield {
        /// Enables best-effort interception for URL Loading System sessions created
        /// after this call. Call this as early as possible during app startup.
        ///
        /// Sessions owned by the app should use `start(intercepting:)` for reliable
        /// interception.
        public static func start(
            maximumTransactions: Int = 100
        ) {
            WindshieldRuntime.shared.start(
                maximumTransactionCount: maximumTransactions
            )
        }

        /// Enables Windshield and installs it into a session configuration before
        /// the session copies that configuration.
        ///
        /// Custom URL protocols are not supported by background configurations.
        public static func start(
            intercepting configuration: URLSessionConfiguration,
            maximumTransactions: Int = 100
        ) {
            WindshieldRuntime.shared.instrument(configuration)
            WindshieldRuntime.shared.start(
                maximumTransactionCount: maximumTransactions
            )
        }
    }

    private final class WindshieldRuntime: @unchecked Sendable {
        static let shared = WindshieldRuntime()

        private let lock = NSLock()
        private var isRegistered = false

        private init() {}

        func start(maximumTransactionCount: Int) {
            WindshieldTransactionRecorder.shared.configure(
                maximumTransactionCount: maximumTransactionCount
            )

            lock.lock()
            guard !isRegistered else {
                lock.unlock()
                return
            }

            isRegistered = URLProtocol.registerClass(WindshieldURLProtocol.self)
            let registrationSucceeded = isRegistered
            lock.unlock()

            if !registrationSucceeded {
                print("[Windshield] Global URLProtocol registration failed")
            }
        }

        func instrument(_ configuration: URLSessionConfiguration) {
            guard configuration.identifier == nil else {
                print("[Windshield] Background URL sessions cannot use custom URL protocols")
                return
            }

            let existingClasses = configuration.protocolClasses ?? []
            configuration.protocolClasses = [WindshieldURLProtocol.self] + existingClasses.filter {
                ObjectIdentifier($0) != ObjectIdentifier(WindshieldURLProtocol.self)
            }
        }
    }
#endif

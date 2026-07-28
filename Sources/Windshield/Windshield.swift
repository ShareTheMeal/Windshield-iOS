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
            WindshieldRuntime.shared.startGlobally(
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
            WindshieldRuntime.shared.start(
                intercepting: configuration,
                maximumTransactionCount: maximumTransactions
            )
        }
    }

    /// Coordinates process-wide registration separately from targeted configuration
    /// instrumentation. Mutable registration state is protected by `registrationLock`.
    final class WindshieldRuntime: @unchecked Sendable {
        static let shared = WindshieldRuntime()

        private let registrationLock = NSLock()
        private let registerProtocol: @Sendable () -> Bool
        private let applyRetentionLimit: @Sendable (Int) -> Void
        private var isGloballyRegistered = false

        init(
            registerProtocol: @escaping @Sendable () -> Bool = {
                URLProtocol.registerClass(WindshieldURLProtocol.self)
            },
            applyRetentionLimit: @escaping @Sendable (Int) -> Void = { maximumTransactionCount in
                WindshieldTransactionRecorder.shared.configure(
                    maximumTransactionCount: maximumTransactionCount
                )
            }
        ) {
            self.registerProtocol = registerProtocol
            self.applyRetentionLimit = applyRetentionLimit
        }

        func startGlobally(maximumTransactionCount: Int) {
            configureRetention(maximumTransactionCount: maximumTransactionCount)

            registrationLock.lock()
            guard !isGloballyRegistered else {
                registrationLock.unlock()
                return
            }

            let registrationSucceeded = registerProtocol()
            isGloballyRegistered = registrationSucceeded
            registrationLock.unlock()

            if !registrationSucceeded {
                print("[Windshield] Global URLProtocol registration failed")
            }
        }

        func start(
            intercepting configuration: URLSessionConfiguration,
            maximumTransactionCount: Int
        ) {
            guard instrument(configuration) else {
                return
            }

            configureRetention(maximumTransactionCount: maximumTransactionCount)
        }

        private func configureRetention(maximumTransactionCount: Int) {
            applyRetentionLimit(maximumTransactionCount)
        }

        @discardableResult
        private func instrument(_ configuration: URLSessionConfiguration) -> Bool {
            guard configuration.identifier == nil else {
                print("[Windshield] Background URL sessions cannot use custom URL protocols")
                return false
            }

            let existingClasses = configuration.protocolClasses ?? []
            configuration.protocolClasses = [WindshieldURLProtocol.self] + existingClasses.filter {
                ObjectIdentifier($0) != ObjectIdentifier(WindshieldURLProtocol.self)
            }
            return true
        }
    }
#endif

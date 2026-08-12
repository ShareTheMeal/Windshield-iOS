import Foundation

#if DEBUG
    /// Installs Windshield's development-only HTTP interception.
    public enum Windshield {
        /// A deterministic rule for matching requests by host, path, and method.
        ///
        /// Hosts are matched case-insensitively. Paths are matched using a
        /// case-sensitive literal prefix, and an empty method set matches every
        /// HTTP method.
        public struct URLRule: Sendable, Hashable {
            /// The exact host to match, unless `includesSubdomains` is enabled.
            public let host: String
            /// An optional literal URL-path prefix. A missing prefix matches any path.
            public let pathPrefix: String?
            /// HTTP methods to match case-insensitively. An empty set matches any method.
            public let httpMethods: Set<String>
            /// Whether hosts ending in `.<host>` should also match.
            public let includesSubdomains: Bool

            public init(
                host: String,
                pathPrefix: String? = nil,
                httpMethods: Set<String> = [],
                includesSubdomains: Bool = false
            ) {
                self.host = host
                self.pathPrefix = pathPrefix
                self.httpMethods = httpMethods
                self.includesSubdomains = includesSubdomains
            }
        }

        /// Process-wide capture and privacy settings used by newly started requests.
        ///
        /// Windshield always redacts its built-in sensitive header set. Custom
        /// names add to that set and are matched case-insensitively.
        public struct Options: Sendable, Equatable {
            public static let defaultRedactedHeaderNames: Set<String> = [
                "Authorization",
                "Proxy-Authorization",
                "Cookie",
                "Set-Cookie",
            ]

            /// The maximum number of transactions retained in memory.
            public let maximumTransactions: Int
            /// App-specific header names added to Windshield's secure default set.
            public let additionalRedactedHeaderNames: Set<String>
            /// Exact hosts whose requests should not create transactions.
            public let ignoredHosts: Set<String>
            /// Requests matching any of these rules should not create transactions.
            public let ignoredURLRules: [URLRule]
            /// Requests matching any of these rules retain metadata but not body bytes.
            public let metadataOnlyURLRules: [URLRule]

            public init(
                maximumTransactions: Int = 100,
                additionalRedactedHeaderNames: Set<String> = [],
                ignoredHosts: Set<String> = [],
                ignoredURLRules: [URLRule] = [],
                metadataOnlyURLRules: [URLRule] = []
            ) {
                self.maximumTransactions = maximumTransactions
                self.additionalRedactedHeaderNames = additionalRedactedHeaderNames
                self.ignoredHosts = ignoredHosts
                self.ignoredURLRules = ignoredURLRules
                self.metadataOnlyURLRules = metadataOnlyURLRules
            }
        }

        /// Enables best-effort interception for URL Loading System sessions created
        /// after this call. Call this as early as possible during app startup.
        ///
        /// Sessions owned by the app should use `start(intercepting:)` for reliable
        /// interception.
        public static func start(
            maximumTransactions: Int = 100
        ) {
            start(
                options: Options(maximumTransactions: maximumTransactions)
            )
        }

        /// Enables best-effort global interception with privacy and capture options.
        ///
        /// Options are process-wide. A later setup call replaces them for requests
        /// that have not started yet; an in-flight request keeps its original policy.
        public static func start(options: Options) {
            WindshieldRuntime.shared.startGlobally(options: options)
        }

        /// Enables Windshield and installs it into a session configuration before
        /// the session copies that configuration.
        ///
        /// Custom URL protocols are not supported by background configurations.
        public static func start(
            intercepting configuration: URLSessionConfiguration,
            maximumTransactions: Int = 100
        ) {
            start(
                intercepting: configuration,
                options: Options(maximumTransactions: maximumTransactions)
            )
        }

        /// Installs Windshield into a session configuration and applies process-wide
        /// privacy and capture options.
        ///
        /// A later setup call replaces the options for requests that have not started
        /// yet. Custom URL protocols are not supported by background configurations.
        public static func start(
            intercepting configuration: URLSessionConfiguration,
            options: Options
        ) {
            WindshieldRuntime.shared.start(
                intercepting: configuration,
                options: options
            )
        }
    }

    /// Coordinates process-wide registration separately from targeted configuration
    /// instrumentation. Mutable state is protected by its dedicated lock.
    final class WindshieldRuntime: @unchecked Sendable {
        static let shared = WindshieldRuntime()

        private let registrationLock = NSLock()
        private let configurationLock = NSLock()
        private let registerProtocol: @Sendable () -> Bool
        private let applyOptions: @Sendable (Windshield.Options) -> Void
        private let emitDiagnostic: @Sendable (String) -> Void
        private var isGloballyRegistered = false

        init(
            registerProtocol: @escaping @Sendable () -> Bool = {
                URLProtocol.registerClass(WindshieldURLProtocol.self)
            },
            applyOptions: @escaping @Sendable (Windshield.Options) -> Void = { options in
                WindshieldCapturePolicyStore.shared.configure(options: options)
                WindshieldTransactionRecorder.shared.configure(
                    maximumTransactionCount: options.maximumTransactions
                )
            },
            emitDiagnostic: @escaping @Sendable (String) -> Void = { message in
                print(message)
            }
        ) {
            self.registerProtocol = registerProtocol
            self.applyOptions = applyOptions
            self.emitDiagnostic = emitDiagnostic
        }

        func startGlobally(maximumTransactionCount: Int) {
            startGlobally(
                options: Windshield.Options(
                    maximumTransactions: maximumTransactionCount
                )
            )
        }

        func startGlobally(options: Windshield.Options) {
            configure(options: options)

            registrationLock.lock()
            guard !isGloballyRegistered else {
                registrationLock.unlock()
                return
            }

            let registrationSucceeded = registerProtocol()
            isGloballyRegistered = registrationSucceeded
            registrationLock.unlock()

            if !registrationSucceeded {
                emitDiagnostic("[Windshield] Global URLProtocol registration failed")
            }
        }

        func start(
            intercepting configuration: URLSessionConfiguration,
            maximumTransactionCount: Int
        ) {
            start(
                intercepting: configuration,
                options: Windshield.Options(
                    maximumTransactions: maximumTransactionCount
                )
            )
        }

        func start(
            intercepting configuration: URLSessionConfiguration,
            options: Windshield.Options
        ) {
            guard instrument(configuration) else {
                return
            }

            configure(options: options)
        }

        private func configure(options: Windshield.Options) {
            configurationLock.lock()
            defer { configurationLock.unlock() }
            applyOptions(options)
        }

        @discardableResult
        private func instrument(_ configuration: URLSessionConfiguration) -> Bool {
            guard configuration.identifier == nil else {
                emitDiagnostic(
                    "[Windshield] Background URL sessions cannot use custom URL protocols"
                )
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

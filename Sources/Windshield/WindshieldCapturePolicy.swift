import Foundation

#if DEBUG
    struct WindshieldCapturePlan: Equatable {
        enum BodyCapture: Equatable {
            case full
            case metadataOnly
        }

        let recordsTransaction: Bool
        let bodyCapture: BodyCapture
        let redactedHeaderNames: Set<String>
    }

    protocol WindshieldCapturePolicyProviding: AnyObject, Sendable {
        func capturePlan(for request: URLRequest) -> WindshieldCapturePlan
    }

    /// Policy mutation is process-wide and lock protected. Each protocol instance
    /// takes one immutable plan at request start and keeps it for its full lifecycle.
    final class WindshieldCapturePolicyStore:
        WindshieldCapturePolicyProviding,
        @unchecked Sendable
    {
        static let shared = WindshieldCapturePolicyStore()

        private let lock = NSLock()
        private var policy: WindshieldCapturePolicy

        init(options: Windshield.Options = Windshield.Options()) {
            policy = WindshieldCapturePolicy(options: options)
        }

        func configure(options: Windshield.Options) {
            let policy = WindshieldCapturePolicy(options: options)

            lock.lock()
            self.policy = policy
            lock.unlock()
        }

        func capturePlan(for request: URLRequest) -> WindshieldCapturePlan {
            lock.lock()
            let policy = policy
            lock.unlock()

            return policy.capturePlan(for: request)
        }
    }

    private struct WindshieldCapturePolicy {
        let redactedHeaderNames: Set<String>
        let ignoredHosts: Set<String>
        let ignoredURLRules: [CompiledURLRule]
        let metadataOnlyURLRules: [CompiledURLRule]

        init(options: Windshield.Options) {
            redactedHeaderNames = Set(
                Windshield.Options.defaultRedactedHeaderNames
                    .union(options.additionalRedactedHeaderNames)
                    .map(WindshieldPolicyNormalization.headerName)
                    .filter { !$0.isEmpty }
            )
            ignoredHosts = Set(
                options.ignoredHosts
                    .map(WindshieldPolicyNormalization.host)
                    .filter { !$0.isEmpty }
            )
            ignoredURLRules = options.ignoredURLRules.compactMap(CompiledURLRule.init)
            metadataOnlyURLRules = options.metadataOnlyURLRules.compactMap(CompiledURLRule.init)
        }

        func capturePlan(for request: URLRequest) -> WindshieldCapturePlan {
            let isIgnored = request.url
                .flatMap(\.host)
                .map(WindshieldPolicyNormalization.host)
                .map(ignoredHosts.contains) == true
                || ignoredURLRules.contains { $0.matches(request) }

            if isIgnored {
                return WindshieldCapturePlan(
                    recordsTransaction: false,
                    bodyCapture: .full,
                    redactedHeaderNames: redactedHeaderNames
                )
            }

            let bodyCapture: WindshieldCapturePlan.BodyCapture = metadataOnlyURLRules.contains {
                $0.matches(request)
            } ? .metadataOnly : .full

            return WindshieldCapturePlan(
                recordsTransaction: true,
                bodyCapture: bodyCapture,
                redactedHeaderNames: redactedHeaderNames
            )
        }
    }

    private struct CompiledURLRule {
        let host: String
        let pathPrefix: String?
        let httpMethods: Set<String>
        let includesSubdomains: Bool

        init?(_ rule: Windshield.URLRule) {
            let host = WindshieldPolicyNormalization.host(rule.host)
            guard !host.isEmpty else {
                return nil
            }

            self.host = host
            pathPrefix = WindshieldPolicyNormalization.pathPrefix(rule.pathPrefix)
            httpMethods = Set(
                rule.httpMethods
                    .map(WindshieldPolicyNormalization.httpMethod)
                    .filter { !$0.isEmpty }
            )
            includesSubdomains = rule.includesSubdomains
        }

        func matches(_ request: URLRequest) -> Bool {
            guard let requestHost = request.url?.host.map(WindshieldPolicyNormalization.host) else {
                return false
            }

            let hostMatches = requestHost == host
                || includesSubdomains && requestHost.hasSuffix("." + host)
            guard hostMatches else {
                return false
            }

            if let pathPrefix {
                let rawRequestPath = request.url?.path ?? "/"
                let requestPath = rawRequestPath.isEmpty ? "/" : rawRequestPath
                guard requestPath.hasPrefix(pathPrefix) else {
                    return false
                }
            }

            guard !httpMethods.isEmpty else {
                return true
            }

            return httpMethods.contains(
                WindshieldPolicyNormalization.httpMethod(request.httpMethod ?? "GET")
            )
        }
    }

    enum WindshieldPolicyNormalization {
        static func headerName(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        static func host(_ value: String) -> String {
            var value = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            while value.last == "." {
                value.removeLast()
            }
            return value
        }

        static func pathPrefix(_ value: String?) -> String? {
            guard let value else {
                return nil
            }

            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }

            return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        }

        static func httpMethod(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
    }
#endif

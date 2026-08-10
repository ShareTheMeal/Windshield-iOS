# Changelog

Windshield follows [Semantic Versioning](https://semver.org/).

## 0.2.0 - 2026-08-10

This is the first tagged pre-1.0 release of Windshield.

### Added

- A development-only SwiftUI inspector for viewing captured traffic on-device.
- In-memory transaction storage with bounded request and response bodies, transaction retention, and a total body-data budget.
- Search, filtering, request and response details, copy actions, empty states, and clear confirmation.
- A deterministic demo UI smoke test and CI validation for strict concurrency, Thread Sanitizer, iOS package builds, and Debug and Release consumers.
- An MIT license.

### Changed

- Separated targeted session configuration from best-effort global registration.
- Serialized URL protocol lifecycle callbacks and recorder publication to make cancellation, completion, redirects, and UI updates thread-safe.
- Excluded Windshield implementation code from Release builds.
- Documented privacy and session-fidelity limitations, including challenge-based authentication and custom trust handling.

### Fixed

- Prevented recursive interception and duplicate protocol installation.
- Preserved and recorded multi-hop redirect lifecycles.
- Removed an unsupported authentication challenge bridge that could leave intercepted requests waiting indefinitely.
- Preserved preemptive `Authorization` headers while using Foundation's default challenge handling.

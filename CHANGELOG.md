# Changelog

Windshield follows [Semantic Versioning](https://semver.org/).

## 0.4.0 - Unreleased

### Added

- A backward-compatible `Windshield.Options` setup API for process-wide privacy and capture policies.
- Case-insensitive custom header redaction in addition to secure built-in defaults.
- Exact ignored-host rules and declarative host, path-prefix, method, and subdomain URL rules.
- Metadata-only rules that retain transaction metadata and known body sizes without storing payload bytes.

### Changed

- `Authorization`, `Proxy-Authorization`, `Cookie`, and `Set-Cookie` values are now redacted before request or response snapshots enter the in-memory store.
- Each request snapshots its capture policy at startup so later configuration changes apply only to new requests.

### Safety

- Redaction changes only Windshield's recorded snapshot; the original network headers are preserved.
- Ignored requests still use the same interception and forwarding lifecycle while emitting no recorder events.
- Metadata-only capture forwards every response byte to the host app while keeping those bytes out of Windshield's buffer.
- Policy replacement is lock-protected and covered by strict-concurrency and concurrent snapshot tests.

## 0.3.0 - 2026-08-10

### Added

- An opt-in three-finger long-press trigger that presents the inspector as a SwiftUI sheet.
- Presentation modifiers for gesture-only, binding-only, or combined manual and gesture entry points.
- iOS presentation tests for gesture configuration, simultaneous recognition, disabled state, and window-scoped installation and teardown.

### Changed

- The demo now supports both the non-blocking gesture and its existing manual inspector button through one sheet state.
- CI now runs the iOS-only presentation tests on a Simulator before the end-to-end demo smoke test.
- CI now targets Xcode 26 or later and arm64-only Simulator builds on Apple-silicon GitHub-hosted runners; the historical Xcode 15 and Intel compatibility lanes were removed.

### Safety

- The gesture attaches only to the SwiftUI modifier's containing window, never enumerates application windows, is configured not to cancel or delay host touches, and requests simultaneous recognition.
- The automatic trigger is suppressed while VoiceOver or another view-controller presentation is active in the containing window.
- Windshield does not request notification or motion permissions, replace the host app's first responder, or swizzle UIKit event handling.

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

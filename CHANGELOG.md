# Changelog

Windshield follows [Semantic Versioning](https://semver.org/).

## 0.5.2 - 2026-09-01

### Added

- A security policy with private reporting guidance for vulnerabilities involving captured traffic.
- A runnable, storyboard-free UIKit demo showing targeted interception and package-owned inspector presentation.

### Changed

- Integration guidance now clearly separates best-effort global interception, reliable configuration-based interception, and presentation-only setup.
- The project page now includes CI status and discovery metadata.

## 0.5.1 - 2026-08-31

### Added

- UIKit apps can now call `Windshield.start(on:)` to start capture and install the inspector gesture on a scene window.
- Apps that configure their own URL sessions can use `Windshield.installInspector(on:)` after setting up targeted interception.

### Changed

- Refreshed the traffic list and request detail screens with a cleaner, more consistent layout.
- The long-press gesture uses one finger in Simulator and three fingers on a physical device.

## 0.5.0 - 2026-08-12

### Added

- Readable request and response views for JSON, HTML, XML, text, JavaScript, GraphQL, forms, multipart data, images, and binary payloads.
- Search and highlighting within captured text bodies.
- A `Windshield.PayloadDecoder` extension point for app-specific text formats.
- Network timing, protocol, connection, redirect, and byte-count diagnostics from `URLSessionTaskMetrics`.
- A Slow filter, host latency summaries, and per-attempt timing waterfalls.

### Changed

- Payload formatting, search, custom decoding, and image previews now run away from the main thread.
- Large payloads and images are bounded before display to keep the inspector responsive.

## 0.4.0 - 2026-08-12

### Added

- `Windshield.Options` for capture limits, additional header redaction, ignored requests, and metadata-only capture.
- URL rules that can match host, path prefix, HTTP method, and optional subdomains.

### Changed

- `Authorization`, `Proxy-Authorization`, `Cookie`, and `Set-Cookie` values are redacted by default.
- Each request keeps the capture policy that was active when it started.

## 0.3.0 - 2026-08-12

### Added

- An optional three-finger long press for opening the inspector on a device.
- SwiftUI presentation modifiers for gesture, binding, or combined presentation.

### Changed

- The gesture no longer competes with host-app touches and is disabled while VoiceOver or another modal presentation is active.

## 0.2.0 - 2026-08-10

### Fixed

- Store updates now compile cleanly with complete Swift concurrency checking while remaining compatible with Swift 5 language mode.

### Added

- Version-based Swift Package Manager installation guidance and release notes.

## 0.1.0 - 2026-07-28

The first public release of Windshield.

### Added

- `URLProtocol`-based interception for compatible `URLSession` configurations.
- In-memory request and response capture with bounded retention.
- A native SwiftUI inspector with search, filters, request details, and copy actions.
- Global and configuration-based `Windshield.start()` entry points.
- A sample app, integration guide, automated tests, and MIT license.

### Fixed

- Prevented recursive interception and duplicate protocol installation.
- Preserved redirects, cancellation, and preemptive `Authorization` headers during forwarding.

### Security

- Windshield is available only in Debug builds, keeps captured traffic on-device, and does not print request data to the console.

# Windshield

Windshield is a development-only HTTP inspector for iOS. It captures `URLSession` traffic with `URLProtocol` and gives your debug build a native SwiftUI traffic viewer, directly on the device.

Windshield keeps captured traffic in memory. It does not persist, upload, or print request data to the console.

## Requirements

- iOS 15 or later
- Swift 5.9 or later
- Xcode 15 or later
- A Debug build

The interception core also builds on macOS 12 for package tests and tooling. The built-in inspector interface is available only on iOS.

## Add the package

After this repository is available on GitHub, add its URL in Xcode under **File → Add Package Dependencies**.

For a tagged release, a package manifest can use:

```swift
.package(
    url: "https://github.com/initishbhatt/Windshield.git",
    from: "0.2.0"
)
```

During early development, you can point at `main` instead:

```swift
.package(
    url: "https://github.com/initishbhatt/Windshield.git",
    branch: "main"
)
```

Add `Windshield` to the application target. Keep setup and presentation code inside `#if DEBUG` because the implementation is intentionally excluded from Release builds.

## Start interception

For a session your app creates, instrument its configuration before creating the session. This is the reliable integration path. This form changes only the supplied configuration and does not register Windshield process-wide.

```swift
#if DEBUG
import Windshield
#endif

func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.default

    #if DEBUG
    Windshield.start(intercepting: configuration)
    #endif

    return URLSession(configuration: configuration)
}
```

For sessions owned by a framework, call the global form as early as possible during app startup:

```swift
#if DEBUG
Windshield.start()
#endif
```

Global `URLProtocol` registration is best effort. It cannot retrofit sessions that already exist, and some networking stacks do not consult globally registered protocols.

Windshield retains up to 100 transactions by default. You can choose another limit:

```swift
#if DEBUG
Windshield.start(intercepting: configuration, maximumTransactions: 250)
#endif
```

Values below one are treated as one retained transaction.

## Present the inspector

Present the built-in view with a normal SwiftUI sheet:

```swift
#if DEBUG
@State private var isShowingWindshield = false
#endif

var body: some View {
    #if DEBUG
    ContentView()
        .toolbar {
            Button("Traffic") {
                isShowingWindshield = true
            }
        }
        .sheet(isPresented: $isShowingWindshield) {
            WindshieldInspectorView()
        }
    #else
    ContentView()
    #endif
}
```

Or use the convenience modifier:

```swift
#if DEBUG
.windshieldInspector(isPresented: $isShowingWindshield)
#endif
```

The inspector provides:

- Live active, completed, failed, cancelled, and redirected requests
- Search by method, URL, host, path, status, and error
- All, Errors, and Active filters
- Request and response headers
- Pretty-printed JSON and readable text payloads
- Copy actions for URLs, headers, and bodies
- Clear confirmation and useful empty states

## What is captured

Windshield records the URL, HTTP method, headers, timestamps, duration, response status, error details, and available request and response bodies.

Each body is capped at 1 MiB. The store keeps at most 20 MiB of captured body data in total. When the total budget is reached, Windshield discards payload bytes from older completed requests while retaining their metadata. A large body is always forwarded to the app in full.

Request streams are never consumed because reading them could change application behavior. The detail view marks those bodies as unavailable.

## Important limitations

Windshield is designed for debug diagnostics, not production monitoring.

- Background `URLSession` configurations do not support custom URL protocols.
- `WKWebView`, Network.framework, and other transports outside URL Loading System are not captured.
- Existing sessions cannot be modified after initialization.
- Global registration is best effort. Prefer `start(intercepting:)` when you own the configuration.
- The forwarding session cannot reproduce every originating session policy. Apps using custom proxies, cookie stores, or custom protocol chains should validate their integration.
- Authentication delegates, client certificates, certificate pinning, and custom server-trust decisions from the originating session are not forwarded. Windshield uses Foundation's default challenge handling. Preemptive `Authorization` headers are preserved. Do not intercept sessions that depend on custom authentication or trust callbacks.
- Streamed request bodies are reported but not read.
- Captured URLs, query strings, headers, and payloads may contain credentials or personal data. Never enable Windshield in production.

## Try the demo

Open `Examples/WindshieldDemo/WindshieldDemo.xcodeproj`, run the `WindshieldDemo` scheme, send the sample request, then open the inspector. The example consumes this repository as a local Swift package.

## Validate changes

```sh
swift test
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
xcodebuild -scheme Windshield -destination 'generic/platform=iOS Simulator' build
```

## Project status

The current release is `0.2.0`. Windshield follows [Semantic Versioning](https://semver.org/). While the package is below `1.0.0`, its public API may evolve between minor releases.

Persistence, export, redaction rules, and automatic presentation gestures are intentionally outside this release. See [CHANGELOG.md](CHANGELOG.md) for release details.

## License

Windshield is available under the MIT License. See [LICENSE](LICENSE).

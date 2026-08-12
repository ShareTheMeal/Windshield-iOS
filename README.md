# Windshield

Windshield is a development-only HTTP inspector for iOS. It captures `URLSession` traffic with `URLProtocol` and gives your debug build a native SwiftUI traffic viewer, directly on the device.

Windshield keeps captured traffic in memory. It does not persist, upload, or print request data to the console.

## Requirements

- iOS 15 or later
- Swift 5.9 or later
- Xcode 26 or later
- A Debug build

The interception core also builds on macOS 12 for package tests and tooling. The built-in inspector interface is available only on iOS.

## Add the package

Add the repository URL in Xcode under **File → Add Package Dependencies**.
Until `0.3.0` is tagged, select the `main` branch. A package manifest can use:

```swift
.package(
    url: "https://github.com/initishbhatt/Windshield.git",
    branch: "main"
)
```

After the `0.3.0` tag is published, prefer a version-based dependency:

```swift
.package(
    url: "https://github.com/initishbhatt/Windshield.git",
    from: "0.3.0"
)
```

Add `Windshield` to the application target. Keep setup and presentation code inside `#if DEBUG` because the implementation is intentionally excluded from Release builds.

## Minimal integration

The smallest Debug integration is one startup call and one root view modifier.
This global setup is convenient when you do not control how every network
session is created, but interception is best effort:

```swift
import SwiftUI

#if DEBUG
import Windshield
#endif

@main
struct ExampleApp: App {
    init() {
        #if DEBUG
        Windshield.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            ContentView()
                .windshieldInspector()
            #else
            ContentView()
            #endif
        }
    }
}
```

`start()` begins capture but never opens UI by itself. The modifier gives SwiftUI
a window-scoped presentation anchor; a deliberate three-finger, one-second hold
then opens the inspector. This split avoids process-wide window lookup,
first-responder takeover, and presenting over an existing host modal.

If some requests do not appear, use the configuration-based setup below for the
sessions your app creates. Calling the global `start()` repeatedly will not
retrofit a session that already exists.

## Start interception

Choose the setup based on who creates the network session:

- If your app creates the `URLSessionConfiguration`, use the configuration-based
  setup below. This is the reliable and recommended path.
- If a framework creates the session, call the global `Windshield.start()` as
  early as possible. Global interception remains best effort.

For a session your app creates, instrument its configuration before creating the
session. This changes only the supplied configuration and does not register
Windshield process-wide.

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

Attach the inspector modifier once near the root of each window. Touch and hold
anywhere with three fingers for one second to open the inspector as a sheet:

```swift
var body: some View {
    #if DEBUG
    ContentView()
        .windshieldInspector()
    #else
    ContentView()
    #endif
}
```

The gesture does not request notification or motion permissions. Its recognizer
is configured not to cancel or delay the app's touches and requests simultaneous
recognition with the host app's gestures. Windshield disables it while VoiceOver
or its own sheet is active, and ignores it while the containing window is already
presenting another view.

For a debug-menu button or an app that already uses three-finger gestures, keep
presentation under the app's control:

```swift
#if DEBUG
.windshieldInspector(isPresented: $isShowingWindshield)
#endif
```

An app can support both entry points with one sheet state:

```swift
#if DEBUG
.windshieldInspector(
    isPresented: $isShowingWindshield,
    trigger: .threeFingerLongPress
)
#endif
```

If your app already owns its sheet or navigation routing, it can present the
inspector view directly instead of installing a Windshield presentation modifier:

```swift
#if DEBUG
.sheet(isPresented: $isShowingWindshield) {
    WindshieldInspectorView()
}
#endif
```

Use either the direct view or a Windshield presentation modifier for a given
route so the app does not create two competing sheets.

Capture continues while the inspector is closed. Opening it reads the current
in-memory snapshot and then receives live updates; no push notification or
external service populates the interface.

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
- Attach the presentation modifier once per window. Windshield disables the gesture while VoiceOver is active. If another host or accessibility workflow uses three-finger long presses, use binding-based manual presentation instead.
- Captured URLs, query strings, headers, and payloads may contain credentials or personal data. Never enable Windshield in production.

## Try the demo

Open `Examples/WindshieldDemo/WindshieldDemo.xcodeproj`, run the `WindshieldDemo` scheme, send the sample request, then use the three-finger long press or the manual button. The example consumes this repository as a local Swift package.

## Validate changes

```sh
swift test
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
xcodebuild -scheme Windshield -destination 'generic/platform=iOS Simulator' build
```

## Project status

The next tagged release is `0.3.0`; its implementation is currently available
from `main`. Windshield follows [Semantic Versioning](https://semver.org/). While
the package is below `1.0.0`, its public API may evolve between minor releases.

Persistence, export, redaction rules, and additional automatic presentation triggers are intentionally outside this release. See [CHANGELOG.md](CHANGELOG.md) for release details.

## License

Windshield is available under the MIT License. See [LICENSE](LICENSE).

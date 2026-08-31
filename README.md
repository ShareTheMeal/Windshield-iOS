# Windshield

[![CI](https://github.com/initishbhatt/Windshield/actions/workflows/ci.yml/badge.svg)](https://github.com/initishbhatt/Windshield/actions/workflows/ci.yml)

Windshield is a development-only HTTP inspector for iOS. It captures `URLSession` traffic with `URLProtocol` and gives your debug build a native SwiftUI traffic viewer, directly on the device.

Windshield keeps captured traffic in memory. It does not persist, upload, or print request data to the console. Common credential and cookie headers are redacted before they enter that in-memory log.

## Requirements

- iOS 15 or later
- Swift 5.9 or later
- Xcode 26 or later
- A Debug build

The interception core also builds on macOS 12 for package tests and tooling. The built-in inspector interface is available only on iOS.

## Add the package

Add the repository URL in Xcode under **File → Add Package Dependencies** and
select **Up to Next Major Version** starting at `0.5.2`. A package manifest can
use:

```swift
.package(
    url: "https://github.com/initishbhatt/Windshield.git",
    from: "0.5.2"
)
```

Add `Windshield` to the application target. Keep setup and presentation code inside `#if DEBUG` because the implementation is intentionally excluded from Release builds.

## Choose an integration

Capture and presentation are separate. Choose each call based on who creates the
network session and how the app presents debug tools:

| Situation | Call | What it does |
| --- | --- | --- |
| A framework creates the session | `Windshield.start()` | Enables best-effort global interception for compatible sessions created after the call. |
| Your app creates the configuration | `Windshield.start(intercepting:)` | Reliably inserts Windshield into a compatible default or ephemeral configuration before the session copies it. |
| A UIKit app needs the inspector UI | `Windshield.installInspector(on:)` | Installs only the window-scoped gesture and presentation layer. It does not start capture. |
| A UIKit app wants global capture and UI | `Windshield.start(on:)` | Combines best-effort global capture with `installInspector(on:)`. |

Apps often need more than one row. For example, an app can call `start()` early
for framework-owned sessions, instrument every app-owned configuration before
creating its session, and install the UIKit inspector after its scene window is
ready:

```swift
#if DEBUG
Windshield.start()                              // Best effort for framework sessions
Windshield.start(intercepting: configuration)  // Reliable for this configuration
Windshield.installInspector(on: window)         // Presentation only
#endif
```

Global registration cannot retrofit an existing session. Targeted interception
does not register Windshield globally, and installing the inspector does not
change networking.

## Minimal SwiftUI integration

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
a window-scoped presentation anchor. A one-second hold with three fingers on a
device, or one finger in Simulator, then opens the inspector. This split avoids
process-wide window lookup, first-responder takeover, and presenting over an
existing host modal.

If some requests do not appear, use the configuration-based setup below for the
sessions your app creates. Calling the global `start()` repeatedly will not
retrofit a session that already exists.

## Minimal UIKit integration

UIKit apps do not need to create a gesture recognizer, hosting controller, or
presentation coordinator. Give Windshield the scene's window after assigning
its root view controller:

```swift
import UIKit

#if DEBUG
import Windshield
#endif

func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = AppViewController()
    self.window = window
    window.makeKeyAndVisible()

    #if DEBUG
    Windshield.start(on: window)
    #endif
}
```

`start(on:)` combines best-effort global capture with a passive, scene-scoped
inspector trigger. It never searches application windows and never presents over
an existing host modal. Call it once for each scene window that should expose
Windshield.

When the app owns its session configuration, keep the reliable targeted capture
setup and install only the presentation layer on the window:

```swift
#if DEBUG
Windshield.start(intercepting: configuration)
Windshield.installInspector(on: window)
#endif
```

## Instrument app-owned sessions

Instrument a configuration before creating its session. This changes only the
supplied configuration and does not register Windshield process-wide or install
the inspector UI.

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

For framework-owned sessions, call the global form as early as possible during
app startup. Global `URLProtocol` registration is best effort: some networking
stacks do not consult globally registered protocols.

Windshield retains up to 100 transactions by default. You can choose another limit:

```swift
#if DEBUG
Windshield.start(intercepting: configuration, maximumTransactions: 250)
#endif
```

Values below one are treated as one retained transaction.

## Protect sensitive traffic

The zero-argument `Windshield.start()` remains the normal setup. It now redacts
`Authorization`, `Proxy-Authorization`, `Cookie`, and `Set-Cookie` values before
they enter Windshield's store or copyable UI. Header names remain visible, with
the value shown as `<redacted>`. The original headers still reach the server.

Use `Windshield.Options` when an app needs additional privacy rules:

```swift
#if DEBUG
let options = Windshield.Options(
    maximumTransactions: 250,
    additionalRedactedHeaderNames: ["X-API-Key", "X-Session-Token"],
    ignoredHosts: ["metrics.example.com"],
    ignoredURLRules: [
        .init(host: "api.example.com", pathPrefix: "/health"),
    ],
    metadataOnlyURLRules: [
        .init(
            host: "api.example.com",
            pathPrefix: "/payments",
            httpMethods: ["POST"]
        ),
    ]
)

Windshield.start(intercepting: configuration, options: options)
#endif
```

For best-effort global registration, pass the same value to
`Windshield.start(options: options)` instead.

Policy behavior:

- Additional header names extend the secure default set and are matched
  case-insensitively.
- An ignored host matches that exact host, case-insensitively. It does not
  silently match subdomains.
- A URL rule matches an exact host plus an optional literal path prefix and an
  optional set of HTTP methods. Set `includesSubdomains: true` when that broader
  match is intentional.
- An ignored request creates no inspector row and stores none of its URL,
  headers, or payload. The request and response still flow normally.
- A metadata-only request keeps its URL, method, redacted headers, status,
  timing, and known body sizes, but stores no request or response body bytes.
- Ignore takes precedence when the same request matches both rule sets.

Capture options are process-wide because a custom `URLProtocol` instance does
not receive its originating session configuration. Global setup applies its
options immediately; targeted setup applies them after the supplied
configuration is accepted. The most recently applied options supply the policy
for newly started requests. Each request takes one immutable policy snapshot,
so changing options never changes an in-flight transaction halfway through
capture. It also does not rewrite rows that are already in memory; clear the
inspector when changing a policy during a run.

## Present the inspector

Attach the inspector modifier once near the root of each window. Touch and hold
anywhere for one second with three fingers on a device, or one finger in
Simulator, to open the inspector as a sheet:

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
- All, Errors, Active, and Slow filters
- Request and response headers
- MIME-aware JSON, HTML source, XML, text, form, multipart-summary, and image views
- Search and highlighted matches within captured textual request and response bodies
- URLSession task timing, redirects, byte counts, per-attempt waterfalls, and contextual slow-host summaries
- Copy actions for URLs, headers, and bodies
- Clear confirmation and useful empty states

## Inspect payloads

Windshield uses the captured `Content-Type` header to choose a safe body view:

- JSON is pretty-printed with stable key ordering when its estimated expanded form stays within the display budget. Deep or highly compact JSON is shown as bounded source with a notice.
- HTML and XML are displayed as source. Windshield never executes captured markup.
- Plain text, JavaScript, GraphQL, and URL-encoded forms are readable and searchable.
- Multipart forms show only part and file-part counts. Part values and filenames stay hidden.
- Declared `image/*` bodies supported by ImageIO get a bounded, downsampled preview. Images with unsafe decoded dimensions are not rendered.
- Unknown content falls back to JSON, then UTF-8 text, then an explicit binary summary.
- If `Content-Type` itself is redacted, Windshield fails closed and hides the body preview instead of guessing its format.

Text shown in the body viewer and data passed to custom decoders are capped at
128 KiB. Search highlights at most the first 500 matches so a debug screen cannot
become unresponsive. These display limits are separate from the 1 MiB capture
limit described below.

For an app-specific textual format, register a Debug-only decoder before opening
the inspector:

```swift
#if DEBUG
Windshield.registerPayloadDecoder(
    .init(
        id: "my-debug-format",
        contentTypes: ["application/x-my-format"]
    ) { input in
        guard let text = MyDebugPayloadDecoder.decode(input.body) else {
            return nil
        }
        return .init(text: text)
    }
)
#endif
```

Matching uses exact, parameter-free MIME types and is case-insensitive. A decoder
receives only a bounded copy of already-captured bytes plus the normalized MIME
type; it receives no URL, headers, response, session, or live transport. Its
text output is also bounded. Keep decoder work local and side-effect-free—do not
upload, persist, or log the input—and return promptly because Windshield cannot
force-cancel app-provided synchronous code. Remove a registration with
`Windshield.removePayloadDecoder(id:)` when it is no longer needed. Multipart and
image MIME types always use Windshield's built-in privacy and decode-safety paths
and cannot be overridden by a custom decoder.

## Read performance diagnostics

For each intercepted task, Windshield displays the task duration and every
available URL loading attempt. The compact waterfall can show DNS lookup,
connection, TLS, request upload, waiting for the first response byte, and response
transfer. It also distinguishes wire bytes from pre-encoding request bytes and
post-decoding response bytes when Foundation reports them.

The **Slow** filter includes terminal requests whose observed duration is at least
one second. The traffic screen also shows up to three hosts with the highest
average observed latency, including sample count and maximum duration.

Some phase values are legitimately absent for cached responses, reused
connections, redirects, and failed requests. These metrics describe Windshield's
internal forwarding `URLSession`, not the originating session that invoked the
custom protocol. See Apple's documentation for
[`URLSessionTaskMetrics`](https://developer.apple.com/documentation/foundation/urlsessiontaskmetrics)
and
[`URLSessionTaskTransactionMetrics`](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics).

## What is captured

Windshield records the URL, HTTP method, redacted headers, timestamps, response
status, error details, available request and response bodies, and Foundation task
metrics. Ignored and metadata-only rules can reduce what reaches the in-memory
store.

Each body is capped at 1 MiB. The store keeps at most 20 MiB of captured body data in total. When the total budget is reached, Windshield discards payload bytes from older completed requests while retaining their metadata. A large body is always forwarded to the app in full.

Request streams are never consumed because reading them could change application behavior. The detail view marks those bodies as unavailable.

## Important limitations

Windshield is designed for debug diagnostics, not production monitoring.

- Background `URLSession` configurations do not support custom URL protocols.
- `WKWebView`, Network.framework, and other transports outside URL Loading System are not captured.
- Existing sessions cannot be modified after initialization.
- Global registration is best effort. Prefer `start(intercepting:)` when you own the configuration.
- The forwarding session cannot reproduce every originating session policy. Apps using custom proxies, cookie stores, or custom protocol chains should validate their integration.
- Authentication delegates, client certificates, certificate pinning, and custom server-trust decisions from the originating session are not forwarded. Windshield uses Foundation's default challenge handling. Preemptive `Authorization` headers are preserved on the network and redacted in the inspector. Do not intercept sessions that depend on custom authentication or trust callbacks.
- Streamed request bodies are reported but not read.
- HTML and XML bodies are source-only. Image previews accept only declared image MIME types and skip unsafe decoded dimensions.
- Task metrics reflect Windshield's forwarding session. They may differ from timing observed outside the custom protocol, and Foundation may omit individual phases.
- Attach the presentation modifier once per window. Windshield disables the gesture while VoiceOver is active. If another host or accessibility workflow uses three-finger long presses, use binding-based manual presentation instead.
- URLs, query strings, nonstandard headers, and payloads may still contain credentials or personal data. Add app-specific redaction, ignore, or metadata-only rules, and never enable Windshield in production.

## Try the demo

Open `Examples/WindshieldDemo/WindshieldDemo.xcodeproj` and run either the
SwiftUI `WindshieldDemo` scheme or the storyboard-free `WindshieldUIKitDemo`
scheme. Both examples instrument an app-owned session configuration and consume
this repository as a local Swift package.

## Validate changes

```sh
swift test
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
xcodebuild -scheme Windshield -destination 'generic/platform=iOS Simulator' build
```

## Project status

The latest release is `0.5.2`. Windshield follows
[Semantic Versioning](https://semver.org/); while the package is below `1.0.0`,
its public API may evolve between minor releases.

Windshield remains a read-only inspector and never changes an app's request or
response payload. See [CHANGELOG.md](CHANGELOG.md) for release details.

## Security

Report vulnerabilities privately and never attach real captured traffic or
credentials. See [SECURITY.md](SECURITY.md) for supported versions and reporting
guidance.

## License

Windshield is available under the MIT License. See [LICENSE](LICENSE).

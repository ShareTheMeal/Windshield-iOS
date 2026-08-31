# Windshield Demos

Open `WindshieldDemo.xcodeproj`, select an iOS 15 or newer simulator, then run
one of the shared demo schemes in Debug.

## SwiftUI demo

Select the `WindshieldDemo` scheme. The app creates an ephemeral URL session,
installs Windshield into that configuration, and attaches the inspector modifier
to its root SwiftUI view.

Send the sample request, then touch and hold anywhere for one second with three
fingers on a device or one finger in Simulator. You can also tap **Open
Windshield**. Every entry point presents the same inspector sheet.

The demo provides two actions:

1. Send a sample GET request.
2. Open the on-device Windshield inspector.

The Windshield import, setup call, and inspector UI are excluded from Release
builds with `#if DEBUG`.

UIKit consumers can use `Windshield.start(on: window)` instead of recreating the
demo's SwiftUI modifier behavior with a host-owned gesture controller. Apps that
instrument their own `URLSessionConfiguration` can call
`Windshield.installInspector(on: window)` after the targeted capture setup.

## UIKit demo

Select the `WindshieldUIKitDemo` scheme. This storyboard-free app instruments an
ephemeral `URLSessionConfiguration` before creating its session, then calls
`Windshield.installInspector(on:)` after making its `UIWindow` visible.

The two calls demonstrate separate responsibilities:

```swift
Windshield.start(intercepting: configuration) // Targeted capture
Windshield.installInspector(on: window)        // UIKit presentation only
```

Send the sample request, then use the same one-finger Simulator or three-finger
device gesture to open the inspector.

## UI smoke test

The `WindshieldDemo` scheme includes an XCUITest that starts a loopback HTTP
fixture, makes a request through Windshield, opens the inspector, and verifies
the recorded JSON body, in-body search, and task performance section. The test
does not use the public internet.

# Windshield Demo

Open `WindshieldDemo.xcodeproj`, select an iOS 15 or newer simulator, then run
the shared `WindshieldDemo` scheme in Debug.

Send the sample request, then touch and hold anywhere for one second with three
fingers on a device or one finger in Simulator. You can also tap **Open
Windshield**. Every entry point presents the same inspector sheet.

The app creates an ephemeral URL session, installs Windshield into that
configuration, and provides two actions:

1. Send a sample GET request.
2. Open the on-device Windshield inspector.

The Windshield import, setup call, and inspector UI are excluded from Release
builds with `#if DEBUG`.

UIKit consumers can use `Windshield.start(on: window)` instead of recreating the
demo's SwiftUI modifier behavior with a host-owned gesture controller. Apps that
instrument their own `URLSessionConfiguration` can call
`Windshield.installInspector(on: window)` after the targeted capture setup.

## UI smoke test

The `WindshieldDemo` scheme includes an XCUITest that starts a loopback HTTP
fixture, makes a request through Windshield, opens the inspector, and verifies
the recorded JSON body, in-body search, and task performance section. The test
does not use the public internet.

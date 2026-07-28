# Windshield Demo

Open `WindshieldDemo.xcodeproj`, select an iOS 15 or newer simulator, then run
the shared `WindshieldDemo` scheme in Debug.

The app creates an ephemeral URL session, installs Windshield into that
configuration, and provides two actions:

1. Send a sample GET request.
2. Open the on-device Windshield inspector.

The Windshield import, setup call, and inspector UI are excluded from Release
builds with `#if DEBUG`.

## UI smoke test

The `WindshieldDemo` scheme includes an XCUITest that starts a loopback HTTP
fixture, makes a request through Windshield, opens the inspector, and verifies
the captured response body. The test does not use the public internet.

# Windshield Demo

Open `WindshieldDemo.xcodeproj`, select an iOS 15 or newer simulator, then run
the shared `WindshieldDemo` scheme in Debug.

The app creates an ephemeral URL session, installs Windshield into that
configuration, and provides two actions:

1. Send a sample GET request.
2. Open the on-device Windshield inspector.

The Windshield import, setup call, and inspector UI are excluded from Release
builds with `#if DEBUG`.

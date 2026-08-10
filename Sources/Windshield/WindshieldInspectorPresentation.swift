#if DEBUG && os(iOS)
    import SwiftUI

    /// A deliberate, user-initiated gesture that can present the inspector.
    public enum WindshieldInspectorTrigger: Sendable {
        /// Presents after three fingers remain pressed for one second.
        case threeFingerLongPress
    }

    public extension View {
        /// Presents Windshield's on-device traffic inspector in a sheet.
        func windshieldInspector(isPresented: Binding<Bool>) -> some View {
            modifier(
                WindshieldInspectorPresentationModifier(
                    isPresented: isPresented,
                    trigger: nil
                )
            )
        }

        /// Presents the inspector when a deliberate debug gesture fires.
        ///
        /// Attach this modifier once near the root of each window that should
        /// expose Windshield.
        func windshieldInspector(
            trigger: WindshieldInspectorTrigger = .threeFingerLongPress
        ) -> some View {
            modifier(
                WindshieldTriggeredInspectorPresentationModifier(
                    trigger: trigger
                )
            )
        }

        /// Presents the inspector from either the supplied binding or trigger.
        ///
        /// Use this overload when an app offers a manual debug-menu action in
        /// addition to the gesture.
        func windshieldInspector(
            isPresented: Binding<Bool>,
            trigger: WindshieldInspectorTrigger
        ) -> some View {
            modifier(
                WindshieldInspectorPresentationModifier(
                    isPresented: isPresented,
                    trigger: trigger
                )
            )
        }
    }

    private struct WindshieldTriggeredInspectorPresentationModifier: ViewModifier {
        let trigger: WindshieldInspectorTrigger

        @State private var isPresented = false

        func body(content: Content) -> some View {
            content.modifier(
                WindshieldInspectorPresentationModifier(
                    isPresented: $isPresented,
                    trigger: trigger
                )
            )
        }
    }

    private struct WindshieldInspectorPresentationModifier: ViewModifier {
        @Binding var isPresented: Bool

        let trigger: WindshieldInspectorTrigger?

        func body(content: Content) -> some View {
            content
                .background(triggerView)
                .sheet(isPresented: $isPresented) {
                    WindshieldInspectorView()
                }
        }

        @ViewBuilder
        private var triggerView: some View {
            switch trigger {
            case .threeFingerLongPress:
                WindshieldInspectorGestureAttachment(
                    isEnabled: !isPresented,
                    onTrigger: {
                        isPresented = true
                    }
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

            case nil:
                EmptyView()
            }
        }
    }
#endif

#if DEBUG && os(iOS)
    import SwiftUI
    import UIKit

    /// Installs one gesture recognizer on the window containing this SwiftUI
    /// attachment. It never enumerates application windows or cancels host touches.
    struct WindshieldInspectorGestureAttachment: UIViewRepresentable {
        let isEnabled: Bool
        let onTrigger: @MainActor () -> Void

        func makeUIView(context _: Context) -> WindshieldInspectorGestureAttachmentView {
            let view = WindshieldInspectorGestureAttachmentView()
            configure(view)
            return view
        }

        func updateUIView(
            _ view: WindshieldInspectorGestureAttachmentView,
            context _: Context
        ) {
            configure(view)
        }

        static func dismantleUIView(
            _ view: WindshieldInspectorGestureAttachmentView,
            coordinator _: Void
        ) {
            view.detach()
        }

        private func configure(_ view: WindshieldInspectorGestureAttachmentView) {
            view.configure(isEnabled: isEnabled, onTrigger: onTrigger)
        }
    }

    @MainActor
    final class WindshieldInspectorGestureController: NSObject, UIGestureRecognizerDelegate {
        private(set) lazy var longPressGestureRecognizer: UILongPressGestureRecognizer = {
            let gestureRecognizer = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            gestureRecognizer.minimumPressDuration = 1
            #if targetEnvironment(simulator)
                gestureRecognizer.numberOfTouchesRequired = 1
            #else
                gestureRecognizer.numberOfTouchesRequired = 3
            #endif
            gestureRecognizer.allowableMovement = 30
            gestureRecognizer.cancelsTouchesInView = false
            gestureRecognizer.delaysTouchesBegan = false
            gestureRecognizer.delaysTouchesEnded = false
            gestureRecognizer.delegate = self
            gestureRecognizer.isEnabled = false
            return gestureRecognizer
        }()

        private weak var attachedWindow: UIWindow?
        private var isTriggerEnabled = false
        private var isVoiceOverRunning: @MainActor () -> Bool = {
            UIAccessibility.isVoiceOverRunning
        }

        private var onTrigger: @MainActor () -> Void = {}

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleVoiceOverStatusDidChange),
                name: UIAccessibility.voiceOverStatusDidChangeNotification,
                object: nil
            )
        }

        func configure(
            isEnabled: Bool,
            onTrigger: @escaping @MainActor () -> Void,
            isVoiceOverRunning: @escaping @MainActor () -> Bool = {
                UIAccessibility.isVoiceOverRunning
            }
        ) {
            isTriggerEnabled = isEnabled
            self.onTrigger = onTrigger
            self.isVoiceOverRunning = isVoiceOverRunning
            refreshGestureAvailability()
        }

        func attach(to window: UIWindow?) {
            guard attachedWindow !== window else {
                return
            }

            detach()

            guard let window else {
                return
            }

            window.addGestureRecognizer(longPressGestureRecognizer)
            attachedWindow = window
        }

        func detach() {
            guard let attachedWindow else {
                return
            }

            attachedWindow.removeGestureRecognizer(longPressGestureRecognizer)
            self.attachedWindow = nil
        }

        func handleGestureState(_ state: UIGestureRecognizer.State) {
            guard
                isTriggerEnabled,
                !isVoiceOverRunning(),
                !hasExistingPresentation,
                state == .began
            else {
                return
            }

            onTrigger()
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
            isTriggerEnabled && !isVoiceOverRunning() && !hasExistingPresentation
        }

        private var hasExistingPresentation: Bool {
            guard let rootViewController = attachedWindow?.rootViewController else {
                return false
            }

            return hasPresentedViewController(in: rootViewController)
        }

        private func hasPresentedViewController(in viewController: UIViewController) -> Bool {
            if viewController.presentedViewController != nil {
                return true
            }

            return viewController.children.contains(where: hasPresentedViewController(in:))
        }

        private func refreshGestureAvailability() {
            longPressGestureRecognizer.isEnabled = isTriggerEnabled && !isVoiceOverRunning()
        }

        @objc
        private func handleLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
            handleGestureState(gestureRecognizer.state)
        }

        @objc
        private func handleVoiceOverStatusDidChange() {
            refreshGestureAvailability()
        }
    }

    @MainActor
    final class WindshieldInspectorGestureAttachmentView: UIView {
        private let gestureController = WindshieldInspectorGestureController()

        var longPressGestureRecognizer: UILongPressGestureRecognizer {
            gestureController.longPressGestureRecognizer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = false
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            gestureController.attach(to: window)
        }

        func configure(
            isEnabled: Bool,
            onTrigger: @escaping @MainActor () -> Void,
            isVoiceOverRunning: @escaping @MainActor () -> Bool = {
                UIAccessibility.isVoiceOverRunning
            }
        ) {
            gestureController.configure(
                isEnabled: isEnabled,
                onTrigger: onTrigger,
                isVoiceOverRunning: isVoiceOverRunning
            )
        }

        func detach() {
            gestureController.detach()
        }

        func handleGestureState(_ state: UIGestureRecognizer.State) {
            gestureController.handleGestureState(state)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureController.gestureRecognizer(
                gestureRecognizer,
                shouldRecognizeSimultaneouslyWith: otherGestureRecognizer
            )
        }

        override func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureController.gestureRecognizerShouldBegin(gestureRecognizer)
        }
    }
#endif

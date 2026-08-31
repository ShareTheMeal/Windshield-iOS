#if DEBUG && os(iOS)
    import Foundation
    import SwiftUI
    import UIKit

    public extension Windshield {
        /// Starts best-effort global capture and installs the inspector trigger on
        /// one UIKit window.
        ///
        /// This is equivalent to calling `start(maximumTransactions:)` followed by
        /// `installInspector(on:)`. Use `start(intercepting:)` separately for every
        /// app-owned session configuration that needs reliable interception.
        ///
        /// Call this once for each scene window that should expose Windshield.
        /// The trigger is passive and never presents over an existing host modal.
        @MainActor
        static func start(
            on window: UIWindow,
            maximumTransactions: Int = 100
        ) {
            start(maximumTransactions: maximumTransactions)
            installInspector(on: window)
        }

        /// Starts best-effort global capture with custom options and installs the
        /// inspector trigger on one UIKit window.
        ///
        /// This is equivalent to calling `start(options:)` followed by
        /// `installInspector(on:)`. Use `start(intercepting:options:)` separately for
        /// every app-owned session configuration that needs reliable interception.
        @MainActor
        static func start(
            on window: UIWindow,
            options: Options
        ) {
            start(options: options)
            installInspector(on: window)
        }

        /// Installs the inspector trigger without changing capture configuration.
        ///
        /// Use this after `start(intercepting:)` when the app owns its URL session
        /// configuration. This method does not register a URL protocol or start
        /// capture. Repeated installation on the same window is idempotent.
        @MainActor
        static func installInspector(
            on window: UIWindow,
            trigger: WindshieldInspectorTrigger = .threeFingerLongPress
        ) {
            WindshieldInspectorUIKitRegistry.shared.install(
                on: window,
                trigger: trigger
            )
        }
    }

    @MainActor
    final class WindshieldInspectorUIKitRegistry {
        static let shared = WindshieldInspectorUIKitRegistry()

        private let controllers = NSMapTable<
            UIWindow,
            WindshieldInspectorUIKitController
        >(keyOptions: .weakMemory, valueOptions: .strongMemory)

        private init() {}

        @discardableResult
        func install(
            on window: UIWindow,
            trigger: WindshieldInspectorTrigger
        ) -> WindshieldInspectorUIKitController {
            if let controller = controllers.object(forKey: window) {
                controller.install(on: window, trigger: trigger)
                return controller
            }

            let controller = WindshieldInspectorUIKitController()
            controller.install(on: window, trigger: trigger)
            controllers.setObject(controller, forKey: window)
            return controller
        }

        func controller(
            for window: UIWindow
        ) -> WindshieldInspectorUIKitController? {
            controllers.object(forKey: window)
        }

        func removeAllInstallations() {
            let installedControllers = controllers.objectEnumerator()?.allObjects ?? []
            for case let controller as WindshieldInspectorUIKitController
                in installedControllers
            {
                controller.detach()
            }
            controllers.removeAllObjects()
        }
    }

    @MainActor
    final class WindshieldInspectorUIKitController: NSObject,
        UIAdaptivePresentationControllerDelegate
    {
        private(set) weak var window: UIWindow?
        private(set) var gestureController = WindshieldInspectorGestureController()
        private(set) weak var inspectorViewController: UIViewController?
        private(set) var isPresenting = false

        func install(
            on window: UIWindow,
            trigger: WindshieldInspectorTrigger
        ) {
            self.window = window

            switch trigger {
            case .threeFingerLongPress:
                gestureController.configure(
                    isEnabled: true,
                    onTrigger: { [weak self] in
                        self?.presentInspector()
                    }
                )
            }

            gestureController.attach(to: window)
        }

        func detach() {
            gestureController.detach()
            window = nil
            inspectorViewController = nil
            isPresenting = false
        }

        func presentInspector(animated: Bool = true) {
            guard
                !isPresenting,
                inspectorViewController == nil,
                let window,
                !window.isHidden,
                window.alpha > 0,
                let rootViewController = window.rootViewController,
                !hasPresentedViewController(in: rootViewController),
                let presentingViewController = visibleViewController(
                    from: rootViewController
                ),
                presentingViewController.viewIfLoaded?.window === window,
                !presentingViewController.isBeingDismissed,
                presentingViewController.transitionCoordinator == nil
            else {
                return
            }

            isPresenting = true
            let inspectorViewController = UIHostingController(
                rootView: WindshieldInspectorView()
                    .onDisappear { [weak self] in
                        self?.inspectorDidDisappear()
                    }
            )
            inspectorViewController.modalPresentationStyle = .pageSheet
            inspectorViewController.presentationController?.delegate = self
            self.inspectorViewController = inspectorViewController

            presentingViewController.present(
                inspectorViewController,
                animated: animated
            )

            // `present` can be rejected if the host wins a presentation race.
            // Keep the synchronous guard narrow; the weak controller reference
            // remains non-nil only when UIKit accepts and retains the sheet.
            isPresenting = false
            inspectorViewController.presentationController?.delegate = self
        }

        func presentationControllerDidDismiss(_: UIPresentationController) {
            inspectorDidDisappear()
        }

        func inspectorDidDisappear() {
            inspectorViewController = nil
            isPresenting = false
        }

        private func visibleViewController(
            from viewController: UIViewController
        ) -> UIViewController? {
            if let presentedViewController = viewController.presentedViewController,
               !presentedViewController.isBeingDismissed
            {
                return visibleViewController(from: presentedViewController)
            }

            if let navigationController = viewController as? UINavigationController {
                guard let visibleViewController = navigationController.visibleViewController else {
                    return navigationController
                }
                return self.visibleViewController(from: visibleViewController)
            }

            if let tabBarController = viewController as? UITabBarController,
               let selectedViewController = tabBarController.selectedViewController
            {
                return visibleViewController(from: selectedViewController)
            }

            if let splitViewController = viewController as? UISplitViewController {
                if let visibleColumn = splitViewController.viewControllers.reversed()
                    .first(where: { $0.viewIfLoaded?.window === window })
                {
                    return visibleViewController(from: visibleColumn)
                }
                return splitViewController
            }

            if let visibleChild = viewController.children.reversed().first(where: {
                $0.viewIfLoaded?.window === window
            }) {
                return visibleViewController(from: visibleChild)
            }

            return viewController
        }

        private func hasPresentedViewController(
            in viewController: UIViewController
        ) -> Bool {
            if viewController.presentedViewController != nil {
                return true
            }

            return viewController.children.contains(
                where: hasPresentedViewController(in:)
            )
        }
    }
#endif

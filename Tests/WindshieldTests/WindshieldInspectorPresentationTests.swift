import XCTest

#if DEBUG && os(iOS)
    import UIKit
    @testable import Windshield

    @MainActor
    final class WindshieldInspectorPresentationTests: XCTestCase {
        func testLongPressGestureIsDeliberateAndDoesNotCancelHostTouches() {
            let view = WindshieldInspectorGestureAttachmentView()
            view.configure(
                isEnabled: true,
                onTrigger: {},
                isVoiceOverRunning: { false }
            )

            let gestureRecognizer = view.longPressGestureRecognizer

            XCTAssertEqual(gestureRecognizer.minimumPressDuration, 1)
            #if targetEnvironment(simulator)
                XCTAssertEqual(gestureRecognizer.numberOfTouchesRequired, 1)
            #else
                XCTAssertEqual(gestureRecognizer.numberOfTouchesRequired, 3)
            #endif
            XCTAssertEqual(gestureRecognizer.allowableMovement, 30)
            XCTAssertFalse(gestureRecognizer.cancelsTouchesInView)
            XCTAssertFalse(gestureRecognizer.delaysTouchesBegan)
            XCTAssertFalse(gestureRecognizer.delaysTouchesEnded)
            XCTAssertTrue(gestureRecognizer.isEnabled)
            XCTAssertFalse(view.isUserInteractionEnabled)
            XCTAssertFalse(view.canBecomeFirstResponder)
            XCTAssertTrue(view.gestureRecognizerShouldBegin(gestureRecognizer))
        }

        func testGestureRecognizesAlongsideHostRecognizers() {
            let view = WindshieldInspectorGestureAttachmentView()
            let hostGestureRecognizer = UITapGestureRecognizer()

            XCTAssertTrue(
                view.gestureRecognizer(
                    view.longPressGestureRecognizer,
                    shouldRecognizeSimultaneouslyWith: hostGestureRecognizer
                )
            )
        }

        func testOnlyBeganStateTriggersPresentation() {
            let view = WindshieldInspectorGestureAttachmentView()
            var triggerCount = 0
            view.configure(
                isEnabled: true,
                onTrigger: {
                    triggerCount += 1
                },
                isVoiceOverRunning: { false }
            )

            view.handleGestureState(.possible)
            view.handleGestureState(.changed)
            view.handleGestureState(.ended)
            view.handleGestureState(.cancelled)
            view.handleGestureState(.failed)

            XCTAssertEqual(triggerCount, 0)

            view.handleGestureState(.began)

            XCTAssertEqual(triggerCount, 1)
        }

        func testDisabledGestureCannotTriggerPresentation() {
            let view = WindshieldInspectorGestureAttachmentView()
            var triggerCount = 0
            view.configure(
                isEnabled: false,
                onTrigger: {
                    triggerCount += 1
                },
                isVoiceOverRunning: { false }
            )

            view.handleGestureState(.began)

            XCTAssertEqual(triggerCount, 0)
            XCTAssertFalse(
                view.gestureRecognizerShouldBegin(view.longPressGestureRecognizer)
            )
            XCTAssertFalse(view.longPressGestureRecognizer.isEnabled)
        }

        func testVoiceOverDisablesAndSuppressesTheGesture() {
            let view = WindshieldInspectorGestureAttachmentView()
            var triggerCount = 0
            view.configure(
                isEnabled: true,
                onTrigger: {
                    triggerCount += 1
                },
                isVoiceOverRunning: { true }
            )

            view.handleGestureState(.began)

            XCTAssertFalse(view.longPressGestureRecognizer.isEnabled)
            XCTAssertFalse(
                view.gestureRecognizerShouldBegin(view.longPressGestureRecognizer)
            )
            XCTAssertEqual(triggerCount, 0)
        }

        func testVoiceOverStatusChangeRefreshesGestureAvailability() {
            let view = WindshieldInspectorGestureAttachmentView()
            var isVoiceOverRunning = true
            view.configure(
                isEnabled: true,
                onTrigger: {},
                isVoiceOverRunning: { isVoiceOverRunning }
            )
            XCTAssertFalse(view.longPressGestureRecognizer.isEnabled)

            isVoiceOverRunning = false
            NotificationCenter.default.post(
                name: UIAccessibility.voiceOverStatusDidChangeNotification,
                object: nil
            )
            XCTAssertTrue(view.longPressGestureRecognizer.isEnabled)
        }

        func testExistingHostPresentationSuppressesTheGesture() {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
            let rootViewController = PresentedViewControllerStub()
            let view = WindshieldInspectorGestureAttachmentView()
            var triggerCount = 0
            window.rootViewController = rootViewController
            window.isHidden = false
            rootViewController.view.addSubview(view)
            rootViewController.stubPresentedViewController = UIViewController()
            view.configure(
                isEnabled: true,
                onTrigger: {
                    triggerCount += 1
                },
                isVoiceOverRunning: { false }
            )

            view.handleGestureState(.began)

            XCTAssertEqual(triggerCount, 0)
            XCTAssertFalse(
                view.gestureRecognizerShouldBegin(view.longPressGestureRecognizer)
            )

            rootViewController.stubPresentedViewController = nil
            view.handleGestureState(.began)

            XCTAssertEqual(triggerCount, 1)
            XCTAssertTrue(
                view.gestureRecognizerShouldBegin(view.longPressGestureRecognizer)
            )

            view.removeFromSuperview()
            window.isHidden = true
        }

        func testAttachmentInstallsOnItsOwnWindowAndRemovesItself() {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
            let rootViewController = UIViewController()
            let view = WindshieldInspectorGestureAttachmentView()
            window.rootViewController = rootViewController
            window.isHidden = false
            rootViewController.view.addSubview(view)

            XCTAssertTrue(
                window.gestureRecognizers?.contains {
                    $0 === view.longPressGestureRecognizer
                } == true
            )

            view.removeFromSuperview()

            XCTAssertFalse(
                window.gestureRecognizers?.contains {
                    $0 === view.longPressGestureRecognizer
                } == true
            )

            view.detach()
            window.isHidden = true
        }

        func testUIKitInstallationIsIdempotentForOneWindow() {
            let registry = WindshieldInspectorUIKitRegistry.shared
            registry.removeAllInstallations()
            defer { registry.removeAllInstallations() }

            let window = window(rootViewController: UIViewController())
            Windshield.installInspector(on: window)
            guard let firstController = registry.controller(for: window) else {
                return XCTFail("Expected the public API to retain its controller.")
            }

            Windshield.installInspector(on: window)
            guard let secondController = registry.controller(for: window) else {
                return XCTFail("Expected the controller to remain installed.")
            }

            XCTAssertTrue(firstController === secondController)
            XCTAssertEqual(
                window.gestureRecognizers?.filter {
                    $0 === firstController.gestureController.longPressGestureRecognizer
                }.count,
                1
            )
        }

        func testUIKitInstallationSupportsIndependentWindows() {
            let registry = WindshieldInspectorUIKitRegistry.shared
            registry.removeAllInstallations()
            defer { registry.removeAllInstallations() }

            let firstWindow = window(rootViewController: UIViewController())
            let secondWindow = window(rootViewController: UIViewController())
            let firstController = registry.install(
                on: firstWindow,
                trigger: .threeFingerLongPress
            )
            let secondController = registry.install(
                on: secondWindow,
                trigger: .threeFingerLongPress
            )

            XCTAssertFalse(firstController === secondController)
            XCTAssertTrue(
                firstWindow.gestureRecognizers?.contains {
                    $0 === firstController.gestureController.longPressGestureRecognizer
                } == true
            )
            XCTAssertTrue(
                secondWindow.gestureRecognizers?.contains {
                    $0 === secondController.gestureController.longPressGestureRecognizer
                } == true
            )
        }

        func testUIKitControllerDoesNotPresentFromHiddenWindowOrOverHostModal() {
            let rootViewController = PresentationViewControllerStub()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
            window.rootViewController = rootViewController
            let controller = WindshieldInspectorUIKitController()
            controller.install(on: window, trigger: .threeFingerLongPress)
            defer { controller.detach() }

            controller.presentInspector(animated: false)
            XCTAssertTrue(rootViewController.presentedControllers.isEmpty)

            window.isHidden = false
            rootViewController.stubPresentedViewController = UIViewController()
            controller.presentInspector(animated: false)
            XCTAssertTrue(rootViewController.presentedControllers.isEmpty)

            rootViewController.stubPresentedViewController = nil
            window.isHidden = true
        }

        func testUIKitControllerCanPresentAgainAfterInspectorDismisses() {
            let rootViewController = PresentationViewControllerStub()
            let window = window(rootViewController: rootViewController)
            let controller = WindshieldInspectorUIKitController()
            controller.install(on: window, trigger: .threeFingerLongPress)
            defer {
                controller.detach()
                window.isHidden = true
            }

            controller.presentInspector(animated: false)

            XCTAssertEqual(rootViewController.presentedControllers.count, 1)
            XCTAssertNotNil(controller.inspectorViewController)
            XCTAssertFalse(controller.isPresenting)

            rootViewController.stubPresentedViewController = nil
            controller.inspectorDidDisappear()
            controller.presentInspector(animated: false)

            XCTAssertEqual(rootViewController.presentedControllers.count, 2)
            XCTAssertNotNil(controller.inspectorViewController)
            XCTAssertFalse(controller.isPresenting)
        }

        func testUIKitControllerRecoversWhenPresentationIsRejected() {
            let rootViewController = RejectingPresentationViewControllerStub()
            let window = window(rootViewController: rootViewController)
            let controller = WindshieldInspectorUIKitController()
            controller.install(on: window, trigger: .threeFingerLongPress)
            defer {
                controller.detach()
                window.isHidden = true
            }

            controller.presentInspector(animated: false)
            controller.presentInspector(animated: false)

            XCTAssertEqual(rootViewController.presentationAttemptCount, 2)
            XCTAssertNil(controller.inspectorViewController)
            XCTAssertFalse(controller.isPresenting)
        }

        func testUIKitControllerResolvesVisibleNavigationControllerChild() {
            let contentViewController = PresentationViewControllerStub()
            let navigationController = UINavigationController(
                rootViewController: contentViewController
            )
            let window = window(rootViewController: navigationController)
            let controller = WindshieldInspectorUIKitController()
            controller.install(on: window, trigger: .threeFingerLongPress)
            defer {
                controller.detach()
                window.isHidden = true
            }

            controller.presentInspector(animated: false)

            XCTAssertEqual(contentViewController.presentedControllers.count, 1)
        }

        func testUIKitControllerResolvesSelectedTabChild() {
            let firstViewController = UIViewController()
            let selectedViewController = PresentationViewControllerStub()
            let tabBarController = UITabBarController()
            tabBarController.viewControllers = [
                firstViewController,
                selectedViewController,
            ]
            tabBarController.selectedViewController = selectedViewController
            let window = window(rootViewController: tabBarController)
            let controller = WindshieldInspectorUIKitController()
            controller.install(on: window, trigger: .threeFingerLongPress)
            defer {
                controller.detach()
                window.isHidden = true
            }

            controller.presentInspector(animated: false)

            XCTAssertEqual(selectedViewController.presentedControllers.count, 1)
        }

        func testUIKitControllerResolvesVisibleSplitViewChild() {
            let primaryViewController = PresentationViewControllerStub()
            let detailViewController = PresentationViewControllerStub()
            let splitViewController = UISplitViewController()
            splitViewController.viewControllers = [
                primaryViewController,
                detailViewController,
            ]
            let window = window(rootViewController: splitViewController)
            let controller = WindshieldInspectorUIKitController()
            controller.install(on: window, trigger: .threeFingerLongPress)
            defer {
                controller.detach()
                window.isHidden = true
            }

            controller.presentInspector(animated: false)

            XCTAssertEqual(
                primaryViewController.presentedControllers.count
                    + detailViewController.presentedControllers.count,
                1
            )
        }

        private func window(rootViewController: UIViewController) -> UIWindow {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
            window.rootViewController = rootViewController
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            return window
        }
    }

    private final class PresentedViewControllerStub: UIViewController {
        var stubPresentedViewController: UIViewController?

        override var presentedViewController: UIViewController? {
            stubPresentedViewController
        }
    }

    private final class PresentationViewControllerStub: UIViewController {
        var stubPresentedViewController: UIViewController?
        var presentedControllers: [UIViewController] = []

        override var presentedViewController: UIViewController? {
            stubPresentedViewController
        }

        override func present(
            _ viewControllerToPresent: UIViewController,
            animated _: Bool,
            completion: (() -> Void)? = nil
        ) {
            presentedControllers.append(viewControllerToPresent)
            stubPresentedViewController = viewControllerToPresent
            completion?()
        }
    }

    private final class RejectingPresentationViewControllerStub: UIViewController {
        private(set) var presentationAttemptCount = 0

        override func present(
            _: UIViewController,
            animated _: Bool,
            completion _: (() -> Void)? = nil
        ) {
            presentationAttemptCount += 1
        }
    }
#endif

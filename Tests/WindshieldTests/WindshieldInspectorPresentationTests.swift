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
            XCTAssertEqual(gestureRecognizer.numberOfTouchesRequired, 3)
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
    }

    private final class PresentedViewControllerStub: UIViewController {
        var stubPresentedViewController: UIViewController?

        override var presentedViewController: UIViewController? {
            stubPresentedViewController
        }
    }
#endif

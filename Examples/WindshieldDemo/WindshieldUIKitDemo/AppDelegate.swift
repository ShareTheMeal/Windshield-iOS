import Foundation
import UIKit

#if DEBUG
    import Windshield
#endif

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private static let defaultSampleURL = URL(
        string: "https://httpbin.org/get?source=windshield-uikit-demo"
    )!

    var window: UIWindow?

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let configuration = URLSessionConfiguration.ephemeral

        #if DEBUG
            Windshield.start(intercepting: configuration)
        #endif

        let session = URLSession(configuration: configuration)
        let sampleURL = ProcessInfo.processInfo.environment["WINDSHIELD_DEMO_SAMPLE_URL"]
            .flatMap(URL.init(string:)) ?? Self.defaultSampleURL
        let viewController = UIKitDemoViewController(
            session: session,
            sampleURL: sampleURL
        )

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(
            rootViewController: viewController
        )
        self.window = window
        window.makeKeyAndVisible()

        #if DEBUG
            Windshield.installInspector(on: window)
        #endif

        return true
    }
}

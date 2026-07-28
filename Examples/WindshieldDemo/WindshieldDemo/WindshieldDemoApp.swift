import Foundation
import SwiftUI

#if DEBUG
    import Windshield
#endif

@main
struct WindshieldDemoApp: App {
    private static let defaultSampleURL = URL(
        string: "https://httpbin.org/get?source=windshield-demo"
    )!

    private let session: URLSession
    private let sampleURL: URL

    init() {
        #if DEBUG
            sampleURL = ProcessInfo.processInfo.environment["WINDSHIELD_DEMO_SAMPLE_URL"]
                .flatMap(URL.init(string:)) ?? Self.defaultSampleURL

            let configuration = URLSessionConfiguration.ephemeral
            Windshield.start(intercepting: configuration)
            session = URLSession(configuration: configuration)
        #else
            sampleURL = Self.defaultSampleURL
            session = .shared
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(session: session, sampleURL: sampleURL)
        }
    }
}

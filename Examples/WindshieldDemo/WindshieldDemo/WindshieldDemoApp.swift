import Foundation
import SwiftUI

#if DEBUG
    import Windshield
#endif

@main
struct WindshieldDemoApp: App {
    private let session: URLSession

    init() {
        #if DEBUG
            let configuration = URLSessionConfiguration.ephemeral
            Windshield.start(intercepting: configuration)
            session = URLSession(configuration: configuration)
        #else
            session = .shared
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
        }
    }
}

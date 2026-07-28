#if DEBUG && os(iOS)
    import SwiftUI

    public extension View {
        /// Presents Windshield's on-device traffic inspector in a sheet.
        func windshieldInspector(isPresented: Binding<Bool>) -> some View {
            sheet(isPresented: isPresented) {
                WindshieldInspectorView()
            }
        }
    }
#endif

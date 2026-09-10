import SwiftUI

@main
struct SottoApp: App {
    @State private var coordinator = SessionCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(coordinator)
        }
    }
}

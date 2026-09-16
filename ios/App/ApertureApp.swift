import SwiftUI
import ApertureDomain
import ApertureTelemetry

/// Application entry point.
///
/// This file wires and nothing else. It contains no business logic, no networking, and no
/// persistence, because the composition root is the one place where every dependency is
/// visible and that property is only useful if it stays uncluttered.
@main
struct ApertureApp: App {
    @State private var container: DependencyContainer

    init() {
        let environment = AppEnvironment.current
        _container = State(initialValue: DependencyContainer.live(environment: environment))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
        }
    }
}

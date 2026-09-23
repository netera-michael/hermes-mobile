import ComposableArchitecture
import HermesKit
import SwiftUI

@main
struct HermesMobileApp: App {
  // Bridges APNs / notification callbacks into `PushClient` streams (#push C2).
  @UIApplicationDelegateAdaptor(PushAppDelegate.self) var pushDelegate

  @MainActor
  static let store: StoreOf<AppFeature> = {
    #if DEBUG
    if DemoMode.isActive { return DemoMode.makeStore() }
    #endif
    return Store(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.diagnostics = PersonalDiagnostics.start()
    }
  }()

  var body: some Scene {
    WindowGroup {
      AppView(store: HermesMobileApp.store)
    }
  }
}

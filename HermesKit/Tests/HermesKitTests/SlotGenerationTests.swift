import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct SlotGenerationTests {
  /// A refill's marker only protects the replacement until its own pop STARTS. An old
  /// destination may finish disappearing before that replacement's pop animation ends.
  /// The detached predicate alone then forwards the old callback into the new recording.
  @Test func staleDisappearanceAfterIdentityClearAndReplacementPop() async {
    let connection = ServerConnection(baseURL: URL(string: "http://hermes.test")!, token: "tok")
    let old = ChatFeature.State(connection: connection, resumeStoredID: "old")
    let cancellations = LockIsolated(0)
    let store = TestStore(initialState: AppFeature.State(
      home: SessionListFeature.State(connection: connection),
      path: StackState([ChatScreen.State(sessionKey: "old")]),
      liveChat: old
    )) {
      AppFeature()
    } withDependencies: {
      $0.audioRecorder.cancel = { cancellations.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.home(.delegate(.disconnect)))
    await store.send(.onboarding(.delegate(.connected(connection))))
    // Equivalent to dictation already started in a newly filled slot. No timer effect
    // is started here, so the test controls only the view lifecycle interleaving.
    var replacement = ChatFeature.State(connection: connection, resumeStoredID: "replacement")
    replacement.recording = .recording
    replacement.isSending = true
    await store.send(.fillLiveChat(replacement))
    await store.send(.path(.popFrom(id: store.state.path.ids.last!)))
    #expect(store.state.isChatDetached)

    // This is the OLD destination's callback, not the replacement's own disappearance.
    await store.send(.chatViewDisappeared)
    await store.finish()
    #expect(store.state.liveChat?.recording == .recording)
    #expect(cancellations.value == 0)
  }
}

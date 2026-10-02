import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

@MainActor
struct AuthLifecycleIntegrationTests {
  @Test func quitRejectsAlreadyEnqueuedPasswordCredentialsAndPersistence() async {
    let keychain = KeychainClient.inMemory()
    let activated = LockIsolated(0)
    let url = URL(string: "https://fixture.example")!
    var state = ReauthFeature.State(serverURL: url, method: .password, status: .validating)
    state.requestGeneration = 1
    let store = TestStore(initialState: state) { ReauthFeature() } withDependencies: {
      $0.keychain = keychain
      $0.keychain.activateCookieSession = { _ in activated.withValue { $0 += 1 } }
      $0.bearerTokens = BearerTokenStore()
    }
    let cookie = CookieSession(cookies: [], username: "fixture", provider: "basic")
    await store.send(.quitTapped) { $0.requestGeneration = 2 }
    await store.receive(\.delegate.quit)
    await store.send(.attemptResponse(1, .passwordCredentialsReceived(cookie)))
    await store.send(.attemptResponse(1, .reauthResponse(.success(.init(
      connection: ServerConnection(baseURL: url, auth: .cookie(cookie)), sameUser: true
    )))))
    #expect(activated.value == 0)
    #expect(keychain.loadSession(.shared) == nil)
  }

  @Test func foregroundWithoutSlotReenablesGlobalLiveness() async {
    let enabled = LockIsolated<[Bool]>([])
    let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
      $0.hermesGateway.setLivenessEnabled = { value in enabled.withValue { $0.append(value) } }
    }
    await store.send(.scenePhaseChanged(.background)) {
      $0.isSceneBackgrounded = true
      $0.backgroundGraceGeneration = 1
    }
    await store.finish()
    await store.send(.scenePhaseChanged(.active)) {
      $0.isSceneBackgrounded = false
      $0.backgroundGraceGeneration = 2
    }
    await store.finish()
    #expect(enabled.value == [false, true])
  }

  @Test func staleListVerdictsDoNotExpireReplacementCredentials() async {
    let old = ServerConnection(baseURL: URL(string: "https://fixture.example")!, token: "old")
    let current = ServerConnection(baseURL: old.baseURL, token: "current")
    var state = SessionListFeature.State(connection: current)
    state.requestGeneration = 2
    let store = TestStore(initialState: state) { SessionListFeature() }
    await store.send(.requestResponse(old, 2, .sessionsResponse(.failure(.unauthorized))))
    await store.send(.requestResponse(current, 1, .sessionsResponse(.failure(.unauthorized))))
    await store.send(.requestResponse(old, 2, .sessionsResponse(.success([]))))
    await store.finish()
  }

  @Test func staleBackgroundExpiryDoesNotSuspendNewGrace() async {
    var state = AppFeature.State()
    state.isSceneBackgrounded = true
    state.backgroundGraceGeneration = 2
    let store = TestStore(initialState: state) { AppFeature() }
    await store.send(.backgroundGraceExpiredFor(1))
    await store.finish()
  }

  @Test func cancelledOldGraceConsumerCannotEndReplacement() async {
    let memory = BackgroundTaskClient.inMemory()
    let first = await memory.client.begin("old")
    let reader = Task { for await _ in first {} }
    let second = await memory.client.begin("new")
    reader.cancel()
    await reader.value
    #expect(memory.activeTaskName == "new")
    memory.expire()
    for await _ in second {}
    #expect(memory.endCount == 2)
  }
}

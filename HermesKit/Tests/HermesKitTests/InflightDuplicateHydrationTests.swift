import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct InflightDuplicateHydrationTests {
  @Test func sameTextInEarlierTurnDoesNotHideNewInflightPrompt() async {
    let prompt = "Repeat this exactly"
    let response = ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123",
      messages: [
        SessionMessage(id: 1, role: "user", content: prompt),
        SessionMessage(id: 2, role: "assistant", content: "Done"),
      ],
      running: true,
      inflight: SessionInflight(user: prompt, assistant: "Working on the new turn", streaming: true)
    )
    let store = TestStore(initialState: ChatFeature.State(
      connection: ServerConnection(baseURL: URL(string: "http://localhost:9119")!, token: "test"),
      resumeStoredID: "stored123"
    )) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.activateResult(.success(response)))
    let bubbles = store.state.visibleRows.filter { row in
      if case let .message(role, text, _) = row.kind {
        return role == .user && text == prompt
      }
      return false
    }
    #expect(bubbles.count == 2)
    await store.send(.teardown)
  }

  @Test func persistedPromptAlsoInInflightRendersOneUserBubble() async {
    let prompt = "Explain the same prompt once"
    // A real session.resume shape: the accepted prompt has a persisted row ID, while
    // inflight.user echoes that same running turn without its own row ID.
    let response: JSONValue = .object([
      "session_id": .string("live123"),
      "resumed": .string("stored123"),
      "messages": .array([
        .object([
          "id": .number(42), "role": .string("user"), "text": .string(prompt),
        ]),
      ]),
      "running": .bool(true),
      "inflight": .object([
        "user": .string(prompt),
        "assistant": .string("Working on it"),
        "streaming": .bool(true),
      ]),
    ])
    let store = TestStore(initialState: ChatFeature.State(
      connection: ServerConnection(baseURL: URL(string: "http://localhost:9119")!, token: "test"),
      resumeStoredID: "stored123"
    )) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in response }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    // Assert the visible rows, not merely distinct row IDs: two different IDs for
    // the same accepted prompt still paint two user bubbles in the collection view.
    let visibleUserBubbles = store.state.visibleRows.filter { row in
      if case let .message(role, text, _) = row.kind {
        return role == .user && text == prompt
      }
      return false
    }
    #expect(visibleUserBubbles.count == 1)

    await store.send(.teardown)
  }

  @Test func persistedPromptFollowedByMidTurnRowsStillDeduplicates() async {
    // Live failure shape (2026-09-25): the prompt is persisted, then the RUNNING turn streams
    // assistant/tool rows into history. messages.last is no longer the prompt — the old
    // tail-only check appended the inflight copy anyway → two bubbles.
    let prompt = "Yes wire the full chain plz"
    let response = ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123",
      messages: [
        SessionMessage(id: 1, role: "user", content: "Earlier question"),
        SessionMessage(id: 2, role: "assistant", content: "Earlier answer, turn complete."),
        SessionMessage(id: 3, role: "user", content: prompt),
        SessionMessage(id: 4, role: "assistant", content: ""),
        SessionMessage(id: 5, role: "tool", content: "{\"status\": \"success\", \"output\": \"ok\"}"),
        SessionMessage(id: 6, role: "assistant", content: ""),
      ],
      running: true,
      inflight: SessionInflight(user: prompt, assistant: "Working on it", streaming: true)
    )
    let store = TestStore(initialState: ChatFeature.State(
      connection: ServerConnection(baseURL: URL(string: "http://localhost:9119")!, token: "test"),
      resumeStoredID: "stored123"
    )) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.activateResult(.success(response)))
    let bubbles = store.state.visibleRows.filter { row in
      if case let .message(role, text, _) = row.kind {
        return role == .user && text == prompt
      }
      return false
    }
    #expect(bubbles.count == 1)
    await store.send(.teardown)
  }
}

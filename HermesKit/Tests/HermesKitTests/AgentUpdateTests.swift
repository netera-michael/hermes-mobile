import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Synthetic-server regressions for the Settings agent updater (plan E1, review finding 9).
/// Never touches a live host: every REST call is a scripted closure.
@MainActor
struct AgentUpdateTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")
  private let other = ServerConnection(baseURL: URL(string: "http://other.tailnet:9119")!, token: "tok")

  private let available = AgentUpdateCheck(currentVersion: "1.0", behind: 3, updateAvailable: true, canApply: true)

  /// A gate a test opens explicitly, so a response can be held "slow".
  final class Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func open() { continuation.yield(); continuation.finish() }
    func wait() async { for await _ in stream { return } }
  }

  private func makeStore(
    preferences: PreferencesClient,
    connection: ServerConnection? = nil,
    status: @escaping @Sendable () async throws -> AgentUpdateActionStatus,
    start: @escaping @Sendable () async throws -> String = { "a-1" },
    posts: LockIsolated<Int> = LockIsolated(0)
  ) -> TestStoreOf<SettingsFeature> {
    let store = TestStore(initialState: SettingsFeature.State(connection: connection ?? self.connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.preferences = preferences
      $0.hermesREST.checkAgentUpdate = { [available] _ in available }
      $0.hermesREST.agentUpdateStatus = { _ in try await status() }
      $0.hermesREST.startAgentUpdate = { _ in posts.withValue { $0 += 1 }; return try await start() }
      $0.hermesREST.pushPluginInfo = { _ in PushPluginInfo(status: .unknown) }
      $0.push.authorizationStatus = { .notDetermined }
      $0.debugLog.stream = { AsyncStream { $0.finish() } }
      $0.connectionTrace.snapshot = { [] }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    return store
  }

  /// Regression for finding 9: slow startup recovery → fast availability → confirmed start
  /// with action ID → stale recovery says "running" → owned completion still lands.
  @Test func slowStartupRecoveryCannotStealOwnedUpdate() async {
    let preferences = PreferencesClient.inMemory()
    let recoveryGate = Gate()
    let calls = LockIsolated(0)
    let store = makeStore(preferences: preferences, status: {
      let n = calls.withValue { $0 += 1; return $0 }
      if n == 1 {
        await recoveryGate.wait()   // slow startup recovery: answers late with "running"
        return AgentUpdateActionStatus(running: true, actionID: "a-1")
      }
      return AgentUpdateActionStatus(running: false, actionID: "a-1",
        receipt: AgentUpdateReceipt(outcome: "success", postVersion: "1.1", finishedAt: "t"))
    })

    await store.send(.task)
    await store.receive(\.agentUpdateChecked) { $0.agentUpdateState = .ready }
    await store.send(.startAgentUpdateTapped)
    await store.send(.startAgentUpdateConfirmed)
    await store.receive(\.agentUpdateStarted) {
      $0.agentUpdateActionID = "a-1"
    }
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .succeeded("1.1"))
    recoveryGate.open()
    await store.receive(\.agentUpdateObserved)   // stale recovery: fenced out
    #expect(store.state.agentUpdateState == .succeeded("1.1"))
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == nil)
    await store.finish()
  }

  /// A stale recovery response arriving while the owned update is running must not flip it
  /// to external; the owned poll then delivers completion.
  @Test func staleRecoveryDuringOwnedRunKeepsOwnership() async {
    let preferences = PreferencesClient.inMemory()
    let recoveryGate = Gate()
    let pollGate = Gate()
    let calls = LockIsolated(0)
    let store = makeStore(preferences: preferences, status: {
      let n = calls.withValue { $0 += 1; return $0 }
      if n == 1 { await recoveryGate.wait(); return AgentUpdateActionStatus(running: true, actionID: "a-1") }
      await pollGate.wait()
      return AgentUpdateActionStatus(running: false, actionID: "a-1",
        receipt: AgentUpdateReceipt(outcome: "success", postVersion: "1.1", finishedAt: "t"))
    })
    await store.send(.task)
    await store.receive(\.agentUpdateChecked)
    await store.send(.startAgentUpdateTapped)
    await store.send(.startAgentUpdateConfirmed)
    await store.receive(\.agentUpdateStarted)
    #expect(store.state.agentUpdateState == .running)
    recoveryGate.open()
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .running)          // not .externalRunning
    #expect(store.state.agentUpdateActionID == "a-1")
    pollGate.open()
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .succeeded("1.1"))
    await store.finish()
  }

  /// Fence (not just ID compare): a recovery read taken before our start, reporting the
  /// PREVIOUS action still running, must not release our ownership when it arrives late.
  @Test func staleRecoveryOfPreviousActionCannotReleaseOwnership() async {
    let preferences = PreferencesClient.inMemory()
    let recoveryGate = Gate()
    let pollGate = Gate()
    let calls = LockIsolated(0)
    let store = makeStore(preferences: preferences, status: {
      let n = calls.withValue { $0 += 1; return $0 }
      if n == 1 { await recoveryGate.wait(); return AgentUpdateActionStatus(running: true, actionID: "x-0") }
      await pollGate.wait()   // owned poll held open; cancelled on disappear
      return AgentUpdateActionStatus(running: true, actionID: "a-1")
    })
    await store.send(.task)
    await store.receive(\.agentUpdateChecked)
    await store.send(.startAgentUpdateTapped)
    await store.send(.startAgentUpdateConfirmed)
    await store.receive(\.agentUpdateStarted)
    recoveryGate.open()
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .running)
    #expect(store.state.agentUpdateActionID == "a-1")
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == "a-1")
    await store.send(.settingsDisappeared)
    await store.finish()
  }

  /// A late availability response cannot reset an owned/external observation to ready.
  @Test func lateAvailabilityDoesNotOverrideExternalUpdate() async {
    let preferences = PreferencesClient.inMemory()
    let checkGate = Gate()
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: { [available] in
      $0.preferences = preferences
      $0.hermesREST.checkAgentUpdate = { _ in await checkGate.wait(); return available }
      $0.hermesREST.agentUpdateStatus = { _ in AgentUpdateActionStatus(running: true, actionID: "x-9") }
      $0.hermesREST.pushPluginInfo = { _ in PushPluginInfo(status: .unknown) }
      $0.push.authorizationStatus = { .notDetermined }
      $0.debugLog.stream = { AsyncStream { $0.finish() } }
      $0.connectionTrace.snapshot = { [] }
    }
    store.exhaustivity = .off
    await store.send(.task)
    await store.receive(\.agentUpdateObserved) { $0.agentUpdateState = .externalRunning }
    checkGate.open()
    await store.receive(\.agentUpdateChecked)
    #expect(store.state.agentUpdateState == .externalRunning)
    await store.send(.startAgentUpdateTapped)
    #expect(store.state.confirmationDialog == nil)
    await store.finish()
  }

  /// Update launched elsewhere finishes successfully: it stays external (never "succeeded"
  /// here); a recheck that sees it idle is the authoritative settlement that re-offers check.
  @Test func externalCompletionIsNeverOwnedSuccess() async {
    let preferences = PreferencesClient.inMemory()
    let running = LockIsolated(true)
    let store = makeStore(preferences: preferences, status: {
      running.value
        ? AgentUpdateActionStatus(running: true, actionID: "x-9")
        : AgentUpdateActionStatus(running: false, actionID: "x-9",
            receipt: AgentUpdateReceipt(outcome: "success", postVersion: "2.0", finishedAt: "t"))
    })
    await store.send(.task)
    await store.skipReceivedActions()
    #expect(store.state.agentUpdateState == .externalRunning)
    running.setValue(false)
    await store.send(.updateCheckTapped)
    await store.receive(\.agentUpdateObserved)
    await store.receive(\.updateCheckTapped)
    await store.receive(\.agentUpdateChecked)
    #expect(store.state.agentUpdateState == .ready)
    #expect(store.state.agentUpdateActionID == nil)
    await store.finish()
  }

  /// Dismiss Settings mid-update, then reopen/relaunch: the persisted owned ID resumes
  /// observation without a second POST and attributes the matching receipt to this phone.
  @Test func reopenRestoresOwnedObservationWithoutReplay() async {
    let preferences = PreferencesClient.inMemory()
    let posts = LockIsolated(0)
    let first = makeStore(preferences: preferences, status: {
      // Idle before our POST; afterwards our action is running.
      posts.value == 0
        ? AgentUpdateActionStatus(running: false, actionID: nil)
        : AgentUpdateActionStatus(running: true, actionID: "a-1")
    }, posts: posts)
    // Startup recovery sees nothing running.
    await first.send(.task)
    await first.skipReceivedActions()
    await first.send(.startAgentUpdateTapped)
    await first.send(.startAgentUpdateConfirmed)
    await first.receive(\.agentUpdateStarted)
    #expect(first.state.agentUpdateState == .running)
    await first.send(.settingsDisappeared)
    #expect(first.state.agentUpdateState == .uncertain)
    await first.finish()
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == "a-1")

    // "Relaunch": fresh state, same persisted store.
    let second = makeStore(preferences: preferences, status: {
      AgentUpdateActionStatus(running: false, actionID: "a-1",
        receipt: AgentUpdateReceipt(outcome: "success", postVersion: "1.1", finishedAt: "t"))
    }, posts: posts)
    await second.send(.task)
    #expect(second.state.agentUpdateActionID == "a-1")
    await second.receive(\.agentUpdateObserved)
    #expect(second.state.agentUpdateState == .succeeded("1.1"))
    #expect(posts.value == 1)
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == nil)
    await second.finish()
  }

  /// Uncertain observation: a recheck is GET-only; start stays unavailable until settled.
  /// Real contract: a failed run has NO action ID; its receipt correlates by `started_at`.
  @Test func uncertainRecheckNeverPostsAndBlocksStartUntilSettled() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdateRequested(connection.notificationPreferenceScope, "a-1", postedAt)
    let posts = LockIsolated(0)
    let reachable = LockIsolated(false)
    let store = makeStore(preferences: preferences, status: {
      guard reachable.value else { throw RESTError.offline }
      return AgentUpdateActionStatus(running: false, actionID: nil, exitCode: 1,
        receipt: AgentUpdateReceipt(outcome: "failed", finishedAt: "2026-10-03T10:05:00+00:00",
                                    startedAt: "2026-10-03T10:00:00.123456+00:00"))
    }, posts: posts)
    await store.send(.task)
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .uncertain)
    await store.send(.startAgentUpdateTapped)
    #expect(store.state.confirmationDialog == nil)
    reachable.setValue(true)
    await store.send(.updateCheckTapped)
    await store.receive(\.agentUpdateObserved)
    if case .failed = store.state.agentUpdateState {} else { Issue.record("expected failed, got \(store.state.agentUpdateState)") }
    #expect(posts.value == 0)
    await store.finish()
  }

  /// Spec reviewer r1 (t_f154fdc1), adopted verbatim as a binding regression: an owned failed
  /// run in the real contract shape (no action ID, no recorded POST time) must not wedge.
  @Test func r1_failedOwnedRunWithRealContractSettlesOrUnblocks() async {
    let p = PreferencesClient.inMemory()
    let scope = connection.notificationPreferenceScope
    p.saveOwnedAgentUpdate(scope, "a-1")
    let posts = LockIsolated(0)
    let store = makeStore(preferences: p, status: {
      AgentUpdateActionStatus(running: false, actionID: nil, exitCode: 1,
        receipt: AgentUpdateReceipt(outcome: "failed", finishedAt: "t"))
    }, posts: posts)
    await store.send(.task)
    await store.skipReceivedActions()
    for _ in 0..<3 { await store.send(.updateCheckTapped); await store.skipReceivedActions() }
    let wedged = store.state.agentUpdateState == .uncertain
      && p.loadOwnedAgentUpdate(scope) == "a-1"
    #expect(!wedged, "owned ID never released: state=\(store.state.agentUpdateState)")
    #expect(posts.value == 0)
    await store.finish()
  }

  /// 2026-10-03T10:00:00Z — the phone's POST time in correlation tests.
  private var postedAt: Date { Date(timeIntervalSince1970: 1_791_021_600) }

  /// Real contract, live flow: our POST is accepted, the run fails. The server never emits
  /// our action ID (only success does); it reports idle + a finished failed receipt started
  /// after our POST. Settles as failed (never success), clears ownership, allows a new check.
  @Test func failedOwnedRunWithoutActionIDSettlesFailed() async {
    let preferences = PreferencesClient.inMemory()
    let posts = LockIsolated(0)
    let store = makeStore(preferences: preferences, status: {
      posts.value == 0
        ? AgentUpdateActionStatus(running: false, actionID: nil)
        : AgentUpdateActionStatus(running: false, actionID: nil, exitCode: 1,
            receipt: AgentUpdateReceipt(outcome: "failed", finishedAt: "2099-01-01T00:05:00+00:00",
                                        startedAt: "2099-01-01T00:00:00.5+00:00"))
    }, posts: posts)
    await store.send(.task)
    await store.skipReceivedActions()
    await store.send(.startAgentUpdateTapped)
    await store.send(.startAgentUpdateConfirmed)
    let before = store.state.agentUpdateGeneration
    await store.receive(\.agentUpdateStarted)
    await store.receive(\.agentUpdateObserved)
    if case .failed = store.state.agentUpdateState {} else { Issue.record("expected failed, got \(store.state.agentUpdateState)") }
    #expect(store.state.agentUpdateActionID == nil)
    #expect(store.state.agentUpdateGeneration > before)
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == nil)
    #expect(posts.value == 1)
    await store.finish()
  }

  /// A finished failed receipt that STARTED BEFORE our POST belongs to an older run: it must
  /// not settle ours as failed. Reopen stays uncertain and owned; only an explicit recheck
  /// releases ownership, as unknown — never failed, never success.
  @Test func olderFailedReceiptCannotSettleNewerOwnedRun() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdateRequested(connection.notificationPreferenceScope, "a-1", postedAt)
    let posts = LockIsolated(0)
    let store = makeStore(preferences: preferences, status: {
      AgentUpdateActionStatus(running: false, actionID: nil, exitCode: 1,
        receipt: AgentUpdateReceipt(outcome: "failed", finishedAt: "2026-10-03T09:59:00+00:00",
                                    startedAt: "2026-10-03T09:58:00+00:00"))
    }, posts: posts)
    await store.send(.task)
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .uncertain)
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == "a-1")
    await store.send(.updateCheckTapped)
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .uncertain)
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == nil)
    #expect(posts.value == 0)
    await store.finish()
  }

  /// No permanent wedge without user action: idle with no receipt releases the owned ID as
  /// unknown after a small bounded number of authoritative idle observations (owned poll).
  @Test func idleWithoutReceiptReleasesOwnershipAfterBoundedObservations() async {
    let preferences = PreferencesClient.inMemory()
    let posts = LockIsolated(0)
    let reads = LockIsolated(0)
    let store = makeStore(preferences: preferences, status: {
      if posts.value > 0 { reads.withValue { $0 += 1 } }
      return AgentUpdateActionStatus(running: false, actionID: nil)
    }, posts: posts)
    await store.send(.task)
    await store.skipReceivedActions()
    await store.send(.startAgentUpdateTapped)
    await store.send(.startAgentUpdateConfirmed)
    await store.receive(\.agentUpdateStarted)
    await store.receive(\.agentUpdateObserved)
    await store.receive(\.agentUpdateObserved)
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .uncertain)
    #expect(store.state.agentUpdateActionID == nil)
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == nil)
    await store.finish()
    // Bounded: not released on the first idle read, and the poll was cancelled at the bound.
    #expect(reads.value == 3)
    #expect(posts.value == 1)
  }

  /// Reopen with an owned ID while the server reports the normal in-progress shape
  /// (running, no ID): observe it by polling, and settle on the success marker.
  @Test func reopenWithRunningNilIDPollsToCompletion() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdateRequested(connection.notificationPreferenceScope, "a-1", postedAt)
    let reads = LockIsolated(0)
    let posts = LockIsolated(0)
    let store = makeStore(preferences: preferences, status: {
      reads.withValue { $0 += 1; return $0 } <= 2
        ? AgentUpdateActionStatus(running: true, actionID: nil)
        : AgentUpdateActionStatus(running: false, actionID: "a-1",
            receipt: AgentUpdateReceipt(outcome: "success", postVersion: "1.1", finishedAt: "t"))
    }, posts: posts)
    await store.send(.task)
    await store.finish()
    await store.skipReceivedActions()
    #expect(store.state.agentUpdateState == .succeeded("1.1"))
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == nil)
    #expect(posts.value == 0)
  }

  /// Success is never inferred from an unmarked receipt: an idle "success" receipt with no
  /// action ID (e.g. rotated log) does not settle ours as success.
  @Test func unmarkedSuccessReceiptIsNeverOwnedSuccess() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdateRequested(connection.notificationPreferenceScope, "a-1", postedAt)
    let store = makeStore(preferences: preferences, status: {
      AgentUpdateActionStatus(running: false, actionID: nil, exitCode: 0,
        receipt: AgentUpdateReceipt(outcome: "success", postVersion: "1.1",
                                    finishedAt: "2026-10-03T10:05:00+00:00", startedAt: "2026-10-03T10:00:01+00:00"))
    })
    await store.send(.task)
    await store.receive(\.agentUpdateObserved)
    // Not attributable either way: unknown and still owned until a recheck or the bound.
    #expect(store.state.agentUpdateState == .uncertain)
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == "a-1")
    await store.send(.updateCheckTapped)
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .uncertain)
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == nil)
    await store.finish()
  }

  // MARK: - Correction 2: success marker precedes receipt finalize (spec2 t_c6f23c17, bullet 5)

  private var scope: String { connection.notificationPreferenceScope }
  private func makeStore(_ p: PreferencesClient, status: @escaping @Sendable () async throws -> AgentUpdateActionStatus,
                         posts: LockIsolated<Int> = LockIsolated(0)) -> TestStoreOf<SettingsFeature> {
    makeStore(preferences: p, status: status, posts: posts)
  }
  private func isFailed(_ s: SettingsFeature.State.AgentUpdateState) -> Bool { if case .failed = s { return true }; return false }
  private func isSucceeded(_ s: SettingsFeature.State.AgentUpdateState) -> Bool { if case .succeeded = s { return true }; return false }

  /// Spec2 reviewer a9, adopted verbatim: our action ID is already in update.log (marker printed),
  /// but latest.json is still the PREVIOUS run's finished receipt. Must not settle either way.
  @Test(arguments: ["success", "failed"])
  func a9_matchingIDWithPreviousRunsReceiptDoesNotSettle(previous: String) async {
    let p = PreferencesClient.inMemory()
    p.saveOwnedAgentUpdateRequested(scope, "a-1", postedAt)
    let store = makeStore(p, status: {
      AgentUpdateActionStatus(running: false, actionID: "a-1", exitCode: 0,
        receipt: AgentUpdateReceipt(outcome: previous, postVersion: "0.9",
          finishedAt: "2026-10-01T08:05:00+00:00", startedAt: "2026-10-01T08:00:00+00:00"))
    })
    await store.send(.task)
    await store.receive(\.agentUpdateObserved)
    #expect(!isSucceeded(store.state.agentUpdateState), "settled success from previous run's receipt")
    #expect(!isFailed(store.state.agentUpdateState), "settled failed from previous run's receipt")
    await store.finish()
  }

  /// Marker seen + previous success receipt, then OUR receipt is finalized `partial`
  /// (restart.incomplete). Ends failed, never success; ownership kept until then; no POST.
  @Test func markerThenPreviousSuccessThenOwnPartialEndsFailed() async {
    let p = PreferencesClient.inMemory()
    p.saveOwnedAgentUpdateRequested(scope, "a-1", postedAt)
    let reads = LockIsolated(0)
    let posts = LockIsolated(0)
    let sawSuccess = LockIsolated(false)
    let ownedWhilePending = LockIsolated(true)
    let scope = self.scope
    let store = makeStore(p, status: {
      let n = reads.withValue { $0 += 1; return $0 }
      // Ownership must survive every pending observation (checked at read time: preferences
      // are live, so a post-receive check would race the already-running poll).
      if n <= 4, p.loadOwnedAgentUpdate(scope) != "a-1" { ownedWhilePending.setValue(false) }
      return n <= 3
        ? AgentUpdateActionStatus(running: false, actionID: "a-1", exitCode: 0,
            receipt: AgentUpdateReceipt(outcome: "success", postVersion: "0.9",
              finishedAt: "2026-10-01T08:05:00+00:00", startedAt: "2026-10-01T08:00:00+00:00"))
        : AgentUpdateActionStatus(running: false, actionID: "a-1", exitCode: 1,
            receipt: AgentUpdateReceipt(outcome: "partial", postVersion: "1.1",
              finishedAt: "2026-10-03T10:06:00+00:00", startedAt: "2026-10-03T10:00:00.300000+00:00"))
    }, posts: posts)
    await store.send(.task)
    await store.receive(\.agentUpdateObserved)
    // Pending: truthful in-progress copy, still owned, observing.
    #expect(store.state.agentUpdateState == .running)
    for _ in 0..<3 {
      await store.receive(\.agentUpdateObserved)
      if isSucceeded(store.state.agentUpdateState) { sawSuccess.setValue(true) }
    }
    #expect(isFailed(store.state.agentUpdateState), "\(store.state.agentUpdateState)")
    #expect(!sawSuccess.value)
    #expect(ownedWhilePending.value, "ownership released while our receipt was pending")
    #expect(p.loadOwnedAgentUpdate(scope) == nil)
    #expect(reads.value >= 4)
    #expect(posts.value == 0)
    await store.finish()
  }

  /// Version comes only from the correlated receipt: previous 0.9 is skipped, ours 1.1 settles.
  @Test func matchingIDSucceedsOnlyFromCorrelatedReceiptVersion() async {
    let p = PreferencesClient.inMemory()
    p.saveOwnedAgentUpdateRequested(scope, "a-1", postedAt)
    let reads = LockIsolated(0)
    let store = makeStore(p, status: {
      reads.withValue { $0 += 1; return $0 } <= 2
        ? AgentUpdateActionStatus(running: false, actionID: "a-1", exitCode: 0,
            receipt: AgentUpdateReceipt(outcome: "success", postVersion: "0.9",
              finishedAt: "2026-10-01T08:05:00+00:00", startedAt: "2026-10-01T08:00:00+00:00"))
        : AgentUpdateActionStatus(running: false, actionID: "a-1", exitCode: 0,
            receipt: AgentUpdateReceipt(outcome: "success", postVersion: "1.1",
              finishedAt: "2026-10-03T10:06:00+00:00", startedAt: "2026-10-03T10:00:00+00:00"))
    })
    await store.send(.task)
    await store.finish()
    await store.skipReceivedActions()
    #expect(store.state.agentUpdateState == .succeeded("1.1"))
    #expect(p.loadOwnedAgentUpdate(scope) == nil)
  }

  /// The receipt never arrives: our poll's bound leaves it uncertain-but-owned (never
  /// success), and one explicit GET-only recheck releases it as unknown.
  @Test func pendingReceiptNeverArrivesReleasesAsUnknownOnRecheck() async {
    let p = PreferencesClient.inMemory()
    p.saveOwnedAgentUpdateRequested(scope, "a-1", postedAt)
    let posts = LockIsolated(0)
    let store = makeStore(p, status: {
      AgentUpdateActionStatus(running: false, actionID: "a-1", exitCode: 0,
        receipt: AgentUpdateReceipt(outcome: "success", postVersion: "0.9",
          finishedAt: "2026-10-01T08:05:00+00:00", startedAt: "2026-10-01T08:00:00+00:00"))
    }, posts: posts)
    await store.send(.task)
    // Drain all 360 bounded polls; the default 1 s finish timeout is too short under load.
    await store.finish(timeout: .seconds(60))
    await store.skipReceivedActions()
    #expect(store.state.agentUpdateState == .uncertain)
    #expect(p.loadOwnedAgentUpdate(scope) == "a-1")
    await store.send(.updateCheckTapped)
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .uncertain)
    #expect(p.loadOwnedAgentUpdate(scope) == nil)
    #expect(posts.value == 0)
    await store.finish()
  }

  /// Legacy stored ID without a POST time: a matching ID + finished success receipt is not
  /// verifiable, so it is never success. Uncertain, released as unknown on recheck.
  @Test func legacyOwnedIDWithoutRequestedAtNeverSucceeds() async {
    let p = PreferencesClient.inMemory()
    p.saveOwnedAgentUpdate(scope, "a-1")
    let store = makeStore(p, status: {
      AgentUpdateActionStatus(running: false, actionID: "a-1", exitCode: 0,
        receipt: AgentUpdateReceipt(outcome: "success", postVersion: "1.1",
          finishedAt: "2026-10-03T10:06:00+00:00", startedAt: "2026-10-03T10:00:00+00:00"))
    })
    await store.send(.task)
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .uncertain)
    #expect(p.loadOwnedAgentUpdate(scope) == "a-1")
    await store.send(.updateCheckTapped)
    await store.receive(\.agentUpdateObserved)
    #expect(!isSucceeded(store.state.agentUpdateState))
    #expect(store.state.agentUpdateState == .uncertain)
    #expect(p.loadOwnedAgentUpdate(scope) == nil)
    await store.finish()
  }

  /// Python `isoformat()` timestamps (with/without microseconds) parse; garbage does not.
  @Test func serverTimestampParsing() {
    #expect(parseServerTimestamp("2026-10-03T10:00:00.123456+00:00") == postedAt)
    #expect(parseServerTimestamp("2026-10-03T10:00:00+00:00") == postedAt)
    #expect(parseServerTimestamp("t") == nil)
  }

  /// Requested-at persists with the owned ID in the live store and follows its scope.
  @Test func liveStorePersistsRequestedAt() {
    let suite = "agent-update-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let scope = connection.notificationPreferenceScope
    PreferencesClient.live(defaults: defaults).saveOwnedAgentUpdateRequested(scope, "a-1", postedAt)
    let relaunched = PreferencesClient.live(defaults: UserDefaults(suiteName: suite)!)
    #expect(relaunched.loadOwnedAgentUpdate(scope) == "a-1")
    #expect(relaunched.loadOwnedAgentUpdateRequestedAt(scope) == postedAt)
    #expect(relaunched.loadOwnedAgentUpdateRequestedAt(other.notificationPreferenceScope) == nil)
    relaunched.clearOwnedAgentUpdate(scope, "a-1")
    #expect(relaunched.loadOwnedAgentUpdateRequestedAt(scope) == nil)
  }

  /// An exit code or the previous run's receipt is not our finished receipt.
  @Test func mismatchedOrUnfinishedReceiptIsNotSuccess() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdateRequested(connection.notificationPreferenceScope, "a-1", postedAt)
    let store = makeStore(preferences: preferences, status: {
      AgentUpdateActionStatus(running: false, actionID: "a-1", exitCode: 0,
        receipt: AgentUpdateReceipt(outcome: "success", postVersion: "1.1", finishedAt: nil))
    })
    await store.send(.task)
    // Correlatable owned ID (requestedAt known): the unfinished receipt keeps it pending and
    // polling, so assert after the bounded poll drains (as pendingReceiptNeverArrives does).
    await store.finish(timeout: .seconds(60))
    await store.skipReceivedActions()
    #expect(store.state.agentUpdateState == .uncertain)
    #expect(store.state.agentUpdateActionID == "a-1")
    await store.finish()
  }

  /// Owned ID never crosses server/account scope.
  @Test func ownedIdentityClearsOnScopeChange() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(connection.notificationPreferenceScope, "a-1")
    #expect(preferences.loadOwnedAgentUpdate(other.notificationPreferenceScope) == nil)
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == nil)
    preferences.saveOwnedAgentUpdate(connection.notificationPreferenceScope, "a-2")
    preferences.clearOwnedAgentUpdate(connection.notificationPreferenceScope, "a-1")
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == "a-2")
  }

  /// The UserDefaults implementation survives a "relaunch" (a new client on the same suite).
  @Test func liveStorePersistsAcrossInstances() {
    let suite = "agent-update-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let scope = connection.notificationPreferenceScope
    PreferencesClient.live(defaults: defaults).saveOwnedAgentUpdate(scope, "a-1")
    let relaunched = PreferencesClient.live(defaults: UserDefaults(suiteName: suite)!)
    #expect(relaunched.loadOwnedAgentUpdate(scope) == "a-1")
    #expect(relaunched.loadOwnedAgentUpdate(other.notificationPreferenceScope) == nil)
    #expect(relaunched.loadOwnedAgentUpdate(scope) == nil)
  }

  /// A different action now owns the host: ours is released as unknown, never success.
  @Test func supersededOwnedActionBecomesExternal() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveOwnedAgentUpdate(connection.notificationPreferenceScope, "a-1")
    let store = makeStore(preferences: preferences, status: {
      AgentUpdateActionStatus(running: true, actionID: "x-9")
    })
    await store.send(.task)
    await store.receive(\.agentUpdateObserved)
    #expect(store.state.agentUpdateState == .externalRunning)
    #expect(store.state.agentUpdateActionID == nil)
    #expect(preferences.loadOwnedAgentUpdate(connection.notificationPreferenceScope) == nil)
    await store.finish()
  }
}

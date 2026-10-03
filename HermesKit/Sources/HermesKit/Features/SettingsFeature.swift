import ComposableArchitecture
import Foundation

/// Settings sheet (Task 12): server info, token management (re-paste / clear), a manual
/// reconnect trigger, and a live feed of decoded gateway events for debugging.
///
/// Token-clear and reconnect are surfaced to the parent via delegates: clearing returns
/// the app to onboarding, reconnect reloads the session list.
@Reducer
public struct SettingsFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    public var token: String
    /// Transient confirmation after saving the token.
    public var savedConfirmation: Bool
    /// Live debug log, newest last; fed by `DebugLogClient`.
    public var log: [GatewayLogEntry]
    /// Safe, bounded trace only; never populated from the gateway debug log.
    public var connectionTrace: [ConnectionTraceEntry]
    public var diagnosticsSettings = DiagnosticsSettingsFeature.State()
    /// Whether the connected agent exposes the `hermes-push` plugin (passed down from the
    /// session list's capability probe). When false the notifications UI (C6) shows a
    /// "not available on this server" note instead of the toggle.
    public var pushAvailable: Bool
    /// Account-scoped intent combined with OS authorization; explicit Off always wins.
    /// Read OS status on appearance; turning On triggers the contextual permission prompt.
    public var notificationsEnabled: Bool
    public var notificationGeneration = 0
    public var notificationStatus: NotificationStatus = .idle
    public enum NotificationStatus: Equatable, Sendable {
      case idle, unregistering, off, unregisterFailed, removalTokenMissing, registrationFailed
      public var message: String? {
        switch self {
        case .idle: nil
        case .unregistering: "Turning off server notifications…"
        case .off: "Notifications are off for this account on this server."
        case .unregisterFailed: "Off on this device, but server removal could not be confirmed. Pushes may still arrive. Turn off notifications in iOS Settings to block delivery, or try Off again."
        case .removalTokenMissing: "Off on this device, but server removal is unconfirmed. This app has no saved device token to retry removal. Ask the server administrator to remove this device registration. No automatic retry is scheduled."
        case .registrationFailed: "Couldn't register for notifications. This build may lack push entitlements, or the server may be unavailable."
        }
      }
    }
    /// `true` when notifications were denied at the OS level — the view shows guidance to
    /// enable them in iOS Settings (opening the URL is a thin view concern). Set when the
    /// authorization request is declined or status reads `.denied`.
    public var notificationsDenied: Bool
    /// Drives the "Send test notification" button + result label.
    public var testPushStatus: TestPushStatus
    /// What the agent's plugin hub reports about `hermes-push` — read on appearance. `nil`
    /// until the probe lands (and left `nil` if it fails), which reads as "offer nothing".
    public var pushPlugin: PushPluginInfo?
    /// Drives the plugin-update row: button state and the result label under it.
    public var pluginUpdate: PluginUpdateStatus
    /// The session list's default trailing-swipe action, edited via the picker below and
    /// persisted immediately (seeded from the list's current value when presenting).
    public var defaultSwipeAction: SessionSwipeAction
    /// Whether the connected agent supports `DELETE /api/sessions/{id}` (seeded from the
    /// session list's capability flag). When false the swipe-action picker is hidden —
    /// Delete isn't offered anywhere, so the choice would be meaningless.
    public var deleteSupported: Bool
    /// Default chat-display prefs for NEW chats (personal-lane global defaults beside the
    /// per-chat ⋯-menu overrides). Seeded from `PreferencesClient` when Settings is
    /// presented; new chat slots seed from the same keys, so a change here applies to
    /// every chat created afterwards. Open chats keep their own live values.
    public var displayPrefs: ChatDisplayPrefs
    public var agentUpdateCheck: AgentUpdateCheck?
    public var agentUpdateState: AgentUpdateState
    public var agentUpdateActionID: String?
    public var agentUpdateChecking: Bool
    @Presents public var confirmationDialog: ConfirmationDialogState<DialogAction>?

    public enum AgentUpdateState: Equatable, Sendable {
      case checking, ready, checkingFailed(String), unsupported
      case starting, running, externalRunning, succeeded(String?), failed(String), uncertain

      public var isCheckFailure: Bool {
        if case .checkingFailed = self { return true }
        return false
      }
    }

    /// The outcome of a "send test notification" attempt, surfaced in the view/snapshots.
    public enum TestPushStatus: Equatable, Sendable {
      case idle
      case sending
      case sent
      case failed
    }

    /// State of the in-app "update the plugin" action.
    public enum PluginUpdateStatus: Equatable, Sendable {
      case idle
      case updating
      /// Pulled new commits — the agent MUST be restarted before the new code runs.
      case updated
      /// The pull succeeded but changed nothing ("Already up to date").
      case alreadyCurrent
      /// The agent refused or the request failed; carries the server's reason verbatim.
      case failed(String)
    }

    public init(
      connection: ServerConnection,
      pushAvailable: Bool = true,
      notificationsEnabled: Bool = false,
      notificationsDenied: Bool = false,
      testPushStatus: TestPushStatus = .idle,
      pushPlugin: PushPluginInfo? = nil,
      pluginUpdate: PluginUpdateStatus = .idle,
      defaultSwipeAction: SessionSwipeAction = .default,
      deleteSupported: Bool = true,
      displayPrefs: ChatDisplayPrefs = ChatDisplayPrefs(),
      agentUpdateCheck: AgentUpdateCheck? = nil,
      agentUpdateState: AgentUpdateState = .checking
    ) {
      self.connection = connection
      self.token = connection.token ?? ""
      self.savedConfirmation = false
      self.log = []
      self.connectionTrace = []
      self.pushAvailable = pushAvailable
      self.notificationsEnabled = notificationsEnabled
      self.notificationsDenied = notificationsDenied
      self.testPushStatus = testPushStatus
      self.pushPlugin = pushPlugin
      self.pluginUpdate = pluginUpdate
      self.defaultSwipeAction = defaultSwipeAction
      self.deleteSupported = deleteSupported
      self.displayPrefs = displayPrefs
      self.agentUpdateCheck = agentUpdateCheck
      self.agentUpdateState = agentUpdateState
      self.agentUpdateActionID = nil
      self.agentUpdateChecking = false
    }

    /// The installed plugin is behind `PushSetup.minimumPluginVersion` AND the agent can pull
    /// it in place → offer the one-tap update.
    ///
    /// Stays `false` once an update has been attempted: after a successful pull the hub reports
    /// the NEW version off disk while the running agent still has the old code loaded, so
    /// re-offering the button would be misleading — the outstanding action is a restart, which
    /// only the user can do.
    public var pluginUpdateAvailable: Bool {
      guard pluginUpdate == .idle, let pushPlugin else { return false }
      return pushPlugin.isOutdated && pushPlugin.canUpdateGit
    }

    /// The plugin is behind but the agent can't pull it (pip install, hand-copied directory,
    /// or an agent too old to report `can_update_git`) → point the user at the chat prompt
    /// instead of a button that would only 400.
    public var pluginUpdateNeedsManualSteps: Bool {
      guard pluginUpdate == .idle, let pushPlugin else { return false }
      return pushPlugin.isOutdated && !pushPlugin.canUpdateGit
    }

    public var serverURLString: String { connection.baseURL.absoluteString }
    public var canSaveToken: Bool {
      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && token != connection.token
    }
  }

  public enum DialogAction: Equatable, Sendable {
    case startAgentUpdateConfirmed
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case settingsDisappeared
    case updateCheckTapped
    case agentUpdateChecked(Result<AgentUpdateCheck, RESTError>)
    case startAgentUpdateTapped
    case startAgentUpdateConfirmed
    case confirmationDialog(PresentationAction<DialogAction>)
    case agentUpdateStarted(Result<String, RESTError>)
    case agentUpdatePolled(Result<AgentUpdateActionStatus, RESTError>)
    case agentUpdateObservationExpired
    case agentUpdateResumed(AgentUpdateActionStatus?)
    case agentUpdateRechecked(Result<AgentUpdateActionStatus, RESTError>)
    case logUpdated([GatewayLogEntry])
    case copyConnectionTraceTapped
    case diagnosticsSettings(DiagnosticsSettingsFeature.Action)
    case saveTokenTapped
    case clearTokenTapped
    case reconnectTapped
    case doneTapped
    /// The current OS authorization status, read on appearance (drives the toggle).
    case authorizationStatusLoaded(PushAuthorizationStatus)
    case notificationStatusLoaded(Int, PushAuthorizationStatus)
    /// User flipped the "Notify me about approvals" toggle.
    case notificationsToggled(Bool)
    /// Result of the contextual permission prompt (`true` ⇒ granted).
    case authorizationResult(Bool)
    case notificationAuthorizationResult(Int, Bool)
    case notificationOperationResult(Int, State.NotificationStatus)
    /// User tapped "Send test notification".
    case sendTestPushTapped
    /// Result of the test-push request.
    case testPushResult(Bool)
    case notificationTestResult(Int, Bool)
    /// The push guide's "Ask agent to install" button — dismiss Settings and bubble up so the
    /// app opens a new chat with the install prompt pre-filled.
    case askAgentToInstallTapped
    /// What the plugin hub reports about `hermes-push`, read on appearance.
    case pushPluginInfoLoaded(PushPluginInfo)
    /// User tapped "Update plugin" — asks the agent to `git pull` it in place.
    case updatePluginTapped
    /// Outcome of that pull.
    case pluginUpdateResult(PluginUpdateOutcome)
    /// User picked a different default swipe action for session rows.
    case defaultSwipeActionChanged(SessionSwipeAction)
    /// User flipped one of the global default chat-display prefs (applies to NEW chats;
    /// open chats keep their own live values).
    case showToolRowsToggled(Bool)
    case showThinkingRowsToggled(Bool)
    case autoFollowToggled(Bool)
    case delegate(Delegate)

    /// Result of the in-app plugin update, flattened to an `Equatable` shape (the failure
    /// carries the server's message rather than the error value, matching `testPushResult`).
    @CasePathable
    public enum PluginUpdateOutcome: Equatable, Sendable {
      /// Pulled new commits — restart required before the new code runs.
      case updated
      /// "Already up to date" — nothing changed, so nothing to restart for.
      case alreadyCurrent
      case failed(String)
    }

    @CasePathable
    public enum Delegate {
      case disconnect             // token cleared → back to onboarding
      case reconnect              // reload the session list
      case tokenSaved(String)     // re-pasted token persisted
      /// The push guide's "Ask agent to install" — dismiss Settings and open a new chat with
      /// the install prompt pre-filled (handled up the chain by `AppFeature`).
      case installPushPlugin
      /// The default swipe action changed — the session list mirrors it immediately so the
      /// rows are right the moment the sheet dismisses.
      case defaultSwipeActionChanged(SessionSwipeAction)
    }
  }

  private enum CancelID { case logStream, updatePoll }

  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.chatSnapshot) var chatSnapshot
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.connectionTrace) var connectionTrace
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.hermesREST) var rest
  @Dependency(\.push) var push
  @Dependency(\.bearerTokens) var bearerTokens
  @Dependency(\.continuousClock) var clock
  @Dependency(\.dismiss) var dismiss

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Scope(state: \.diagnosticsSettings, action: \.diagnosticsSettings) { DiagnosticsSettingsFeature() }
    Reduce { state, action in
      switch action {
      case .task:
        state.connectionTrace = connectionTrace.snapshot()
        return .merge(
          .run { [debugLog] send in
            for await entries in debugLog.stream() {
              await send(.logUpdated(entries))
            }
          }
          .cancellable(id: CancelID.logStream, cancelInFlight: true),
          // Reflect the real OS authorization status in the toggle on appearance.
          .run { [push, generation = state.notificationGeneration] send in
            await send(.notificationStatusLoaded(generation, push.authorizationStatus()))
          },
          // Read the installed plugin's version so we can offer an update. Never throws —
          // an unreachable/old agent maps to `.unknown`, which offers nothing.
          .run { [rest, connection = state.connection] send in
            await send(.pushPluginInfoLoaded(rest.pushPluginInfo(connection)))
          },
          .send(.updateCheckTapped),
          .run { [rest, connection = state.connection] send in
            // Recover an in-flight server update after Settings is reopened. No POST replay.
            let status = try? await rest.agentUpdateStatus(connection)
            await send(.agentUpdateResumed(status?.running == true ? status : nil))
          }
        )

      case .settingsDisappeared:
        if state.agentUpdateState == .running { state.agentUpdateState = .uncertain }
        return .cancel(id: CancelID.updatePoll)

      case .updateCheckTapped:
        guard state.agentUpdateActionID == nil, !state.agentUpdateChecking,
              state.agentUpdateState != .starting else { return .none }
        if state.agentUpdateState == .externalRunning {
          return .run { [rest, connection = state.connection] send in
            do { await send(.agentUpdateRechecked(.success(try await rest.agentUpdateStatus(connection)))) }
            catch { await send(.agentUpdateRechecked(.failure(asRESTError(error)))) }
          }
        }
        state.confirmationDialog = nil
        state.agentUpdateChecking = true
        state.agentUpdateState = .checking
        return .run { [rest, connection = state.connection] send in
          do {
            await send(.agentUpdateChecked(.success(try await rest.checkAgentUpdate(connection))))
          } catch {
            await send(.agentUpdateChecked(.failure(asRESTError(error))))
          }
        }

      case let .agentUpdateChecked(result):
        state.agentUpdateChecking = false
        if state.agentUpdateState == .externalRunning { return .none }
        switch result {
        case let .success(check):
          state.agentUpdateCheck = check
          state.agentUpdateState = .ready
        case let .failure(error):
          state.agentUpdateState = error.isMissingEndpointVerdict
            ? .unsupported : .checkingFailed(error.message)
        }
        return .none

      case .startAgentUpdateTapped:
        guard state.agentUpdateState == .ready,
              state.agentUpdateCheck?.canApply == true,
              state.agentUpdateCheck?.updateAvailable == true else { return .none }
        state.confirmationDialog = ConfirmationDialogState {
          TextState("Update Hermes agent?")
        } actions: {
          ButtonState(role: .destructive, action: .startAgentUpdateConfirmed) {
            TextState("Update Hermes")
          }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState("This updates the server and may restart the gateway and dashboard, interrupting active sessions. Start only when nobody is using Hermes.")
        }
        return .none

      case .confirmationDialog(.dismiss):
        return .none

      case .startAgentUpdateConfirmed, .confirmationDialog(.presented(.startAgentUpdateConfirmed)):
        guard state.confirmationDialog != nil,
              state.agentUpdateState == .ready,
              state.agentUpdateCheck?.canApply == true,
              state.agentUpdateCheck?.updateAvailable == true else { return .none }
        state.confirmationDialog = nil
        state.agentUpdateState = .starting
        return .run { [rest, connection = state.connection] send in
          do {
            await send(.agentUpdateStarted(.success(try await rest.startAgentUpdate(connection))))
          } catch {
            await send(.agentUpdateStarted(.failure(asRESTError(error))))
          }
        }

      case let .agentUpdateStarted(result):
        switch result {
        case let .failure(error):
          // An offline/timeout after POST is ambiguous: never offer an automatic retry.
          state.agentUpdateState = error == .unreachable || error == .offline
            ? .uncertain : .failed(error.message)
          return .none
        case let .success(id):
          state.agentUpdateActionID = id
          state.agentUpdateState = .running
          return .run { [rest, connection = state.connection, clock] send in
            // Bounded observation; the server update keeps running if Settings closes.
            for _ in 0..<360 {
              if Task.isCancelled { return }
              do {
                let status = try await rest.agentUpdateStatus(connection)
                await send(.agentUpdatePolled(.success(status)))
                if !status.running && status.actionID == id && status.receipt?.finishedAt != nil { return }
              } catch {
                await send(.agentUpdatePolled(.failure(asRESTError(error))))
              }
              do { try await clock.sleep(for: .seconds(5)) } catch { return }
            }
            await send(.agentUpdateObservationExpired)
          }
          .cancellable(id: CancelID.updatePoll, cancelInFlight: true)
        }

      case let .agentUpdatePolled(result):
        guard let id = state.agentUpdateActionID, state.agentUpdateState == .running else { return .none }
        switch result {
        case .failure:
          // A restart can briefly cut the connection. Keep trying while Settings is open.
          return .none
        case let .success(status):
          if status.running { return .none }
          // The status endpoint may expose the PREVIOUS run's receipt or an uncorrelated
          // exit code; neither proves that the action we started finished successfully.
          guard status.actionID == id, let receipt = status.receipt,
                receipt.finishedAt != nil else { return .none }
          switch receipt.outcome {
          case "success": state.agentUpdateState = .succeeded(receipt.postVersion)
          case "partial", "failed", "refused":
            state.agentUpdateState = .failed("The update did not complete cleanly. Check the server update log.")
          default: state.agentUpdateState = .uncertain
          }
          return .cancel(id: CancelID.updatePoll)
        }

      case let .agentUpdateResumed(status):
        guard let status, status.running else { return .none }
        // An update from another client may own the host. Do not present a second start.
        // Its eventual result is unowned by this phone, so never label it a success.
        state.agentUpdateState = .externalRunning
        return .none

      case let .agentUpdateRechecked(result):
        guard state.agentUpdateState == .externalRunning else { return .none }
        switch result {
        case let .success(status) where !status.running:
          state.agentUpdateState = .ready
          return .send(.updateCheckTapped)
        case let .failure(error):
          state.agentUpdateState = .checkingFailed(error.message)
        default: break
        }
        return .none

      case .agentUpdateObservationExpired:
        if state.agentUpdateState == .running { state.agentUpdateState = .uncertain }
        return .none

      case let .pushPluginInfoLoaded(info):
        state.pushPlugin = info
        return .none

      case .diagnosticsSettings(.consentChanged(false)):
        state.connectionTrace = []
        return .none

      case .diagnosticsSettings:
        return .none

      case .copyConnectionTraceTapped:
        // Legacy action retained for compatibility; UI uses reviewed preview below.
        // Snapshot at tap time so events added while Settings was open are included.
        let entries = connectionTrace.snapshot()
        state.connectionTrace = entries
        let text = (["Connection & Send trace (on-device, sanitized)"] + entries.map(\.line))
          .joined(separator: "\n")
        return .run { [pasteboard] _ in pasteboard.copy(text) }

      case .updatePluginTapped:
        guard state.pluginUpdate != .updating else { return .none }
        state.pluginUpdate = .updating
        return .run { [rest, connection = state.connection] send in
          do {
            let result = try await rest.updatePushPlugin(connection)
            await send(.pluginUpdateResult(result.unchanged ? .alreadyCurrent : .updated))
          } catch let error as RESTError {
            // Surface the agent's own reason (not a git checkout, non-fast-forward, git
            // missing) verbatim — the user has to act on it on their host.
            await send(.pluginUpdateResult(.failed(error.message)))
          } catch {
            await send(.pluginUpdateResult(.failed(RESTError.unreachable.message)))
          }
        }

      case let .pluginUpdateResult(outcome):
        switch outcome {
        case .updated: state.pluginUpdate = .updated
        case .alreadyCurrent: state.pluginUpdate = .alreadyCurrent
        case let .failed(reason): state.pluginUpdate = .failed(reason)
        }
        return .none

      case let .authorizationStatusLoaded(status), let .notificationStatusLoaded(_, status):
        if case let .notificationStatusLoaded(generation, _) = action,
           generation != state.notificationGeneration { return .none }
        guard preferences.loadNotificationsEnabled(state.connection.notificationPreferenceScope) != false else {
          state.notificationsEnabled = false
          state.notificationsDenied = false
          if state.notificationStatus != .unregistering {
            let removal = preferences.loadNotificationRemoval(state.connection.notificationPreferenceScope)
            state.notificationStatus = removal?.confirmed == true ? .off
              : ((removal?.token ?? preferences.loadPushDeviceToken()) == nil ? .removalTokenMissing : .unregisterFailed)
          }
          return .none
        }
        switch status {
        case .authorized, .provisional:
          state.notificationsEnabled = true
          state.notificationsDenied = false
        case .denied:
          state.notificationsEnabled = false
          state.notificationsDenied = true
        case .notDetermined:
          state.notificationsEnabled = false
          state.notificationsDenied = false
        }
        return .none

      case let .notificationsToggled(isOn):
        let scope = state.connection.notificationPreferenceScope
        // Persist intent synchronously, before permission, token, or network work.
        preferences.saveNotificationsEnabled(scope, isOn)
        state.notificationGeneration &+= 1
        let generation = state.notificationGeneration
        state.notificationsEnabled = isOn
        state.notificationsDenied = false
        state.testPushStatus = .idle
        state.notificationStatus = isOn ? .idle : .unregistering
        guard isOn else {
          let removal = preferences.loadNotificationRemoval(scope)
          let tokens = removal?.tokens ?? preferences.loadPushDeviceToken().map { [$0] } ?? []
          return .run { [preferences, rest, connection = state.connection] send in
            await preferences.notificationOperation(scope) {
              guard preferences.loadNotificationsEnabled(scope) == false,
                    preferences.loadNotificationRemoval(scope)?.operation == removal?.operation else { return }
              guard !tokens.isEmpty else {
                await send(.notificationOperationResult(generation, .removalTokenMissing))
                return
              }
              var failed = false
              for token in tokens {
                guard !Task.isCancelled,
                      preferences.loadNotificationsEnabled(scope) == false,
                      preferences.loadNotificationRemoval(scope)?.operation == removal?.operation else { return }
                do { try await rest.unregisterPush(connection, token) }
                catch { failed = true }
              }
              guard !Task.isCancelled else { return }
              if failed {
                // Keep the complete set for an idempotent retry after partial success.
                await send(.notificationOperationResult(generation, .unregisterFailed))
              } else {
                guard let removal, preferences.confirmNotificationRemoval(scope, removal.operation) else { return }
                await send(.notificationOperationResult(generation, .off))
              }
            }
          }
        }
        return .run { [push] send in
          await send(.notificationAuthorizationResult(generation, push.requestAuthorization()))
        }

      case let .notificationOperationResult(generation, status):
        guard generation == state.notificationGeneration else { return .none }
        state.notificationStatus = status
        return .none

      case let .authorizationResult(granted), let .notificationAuthorizationResult(_, granted):
        if case let .notificationAuthorizationResult(generation, _) = action,
           generation != state.notificationGeneration { return .none }
        guard preferences.loadNotificationsEnabled(state.connection.notificationPreferenceScope) != false else {
          return .none
        }
        if granted {
          state.notificationsEnabled = true
          state.notificationsDenied = false
          return .run { [rest, push, preferences, clock, connection = state.connection,
                        generation = state.notificationGeneration] send in
            let ok = await ensurePushRegistered(
              rest: rest, push: push, preferences: preferences,
              connection: connection, clock: clock
            )
            await send(.notificationOperationResult(generation, ok ? .idle : .registrationFailed))
          }
        } else {
          state.notificationsEnabled = false
          state.notificationsDenied = true
          return .none
        }

      case .sendTestPushTapped:
        guard state.pushAvailable,
              preferences.loadNotificationsEnabled(state.connection.notificationPreferenceScope) != false else { return .none }
        state.testPushStatus = .sending
        // Register if needed, then ask the plugin to deliver a sample push. The token wait is
        // bounded inside `ensurePushRegistered` — if no token is ever obtained we fail fast
        // rather than leaving `testPushStatus` stuck on `.sending`.
        return .run { [rest, push, preferences, clock, connection = state.connection,
                      generation = state.notificationGeneration] send in
          guard await ensurePushRegistered(
            rest: rest, push: push, preferences: preferences,
            connection: connection, clock: clock
          ) else {
            await send(.notificationTestResult(generation, false))
            return
          }
          do {
            try await rest.sendTestPush(connection)
            await send(.notificationTestResult(generation, true))
          } catch {
            await send(.notificationTestResult(generation, false))
          }
        }

      case let .testPushResult(ok), let .notificationTestResult(_, ok):
        if case let .notificationTestResult(generation, _) = action,
           generation != state.notificationGeneration { return .none }
        state.testPushStatus = ok ? .sent : .failed
        return .none

      case let .defaultSwipeActionChanged(action):
        state.defaultSwipeAction = action
        preferences.saveDefaultSessionSwipeAction(action)
        // Bubble up so the session list reflects the new default immediately on dismissal.
        return .send(.delegate(.defaultSwipeActionChanged(action)))

      // MARK: Global default chat-display prefs (personal lane)

      case let .showToolRowsToggled(show):
        guard state.displayPrefs.showToolRows != show else { return .none }
        state.displayPrefs.showToolRows = show
        preferences.saveShowToolRows(show)
        return .none

      case let .showThinkingRowsToggled(show):
        guard state.displayPrefs.showThinkingRows != show else { return .none }
        state.displayPrefs.showThinkingRows = show
        preferences.saveShowThinkingRows(show)
        return .none

      case let .autoFollowToggled(enabled):
        guard state.displayPrefs.autoFollowEnabled != enabled else { return .none }
        state.displayPrefs.autoFollowEnabled = enabled
        preferences.saveAutoFollowEnabled(enabled)
        return .none

      case .askAgentToInstallTapped:
        // Dismiss Settings and bubble up — `AppFeature` opens a new chat with the install
        // prompt pre-filled (the user reviews and sends).
        return .merge(
          .send(.delegate(.installPushPlugin)),
          .run { [dismiss] _ in await dismiss() }
        )

      case let .logUpdated(entries):
        state.log = entries
        return .none

      case .binding(\.token):
        state.savedConfirmation = false
        return .none

      case .binding:
        return .none

      case .saveTokenTapped:
        guard state.canSaveToken else { return .none }
        let token = state.token
        state.connection.token = token
        state.savedConfirmation = true
        try? keychain.saveToken(token)
        return .send(.delegate(.tokenSaved(token)))

      case .clearTokenTapped:
        // AppFeature handles this SAME action after the child reduction, capturing
        // cleanup before revocation. Do not enqueue a second logout/dismiss callback:
        // either could arrive after a replacement login.
        state.notificationGeneration &+= 1
        return .none

      case .reconnectTapped:
        return .merge(
          .send(.delegate(.reconnect)),
          .run { [dismiss] _ in await dismiss() }
        )

      case .doneTapped:
        return .run { [dismiss] _ in await dismiss() }

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$confirmationDialog, action: \.confirmationDialog)
  }
}

/// Seconds to wait for a fresh device token before falling back to the persisted one. A
/// token may never arrive (no entitlement / offline / simulator), so the wait MUST be bounded
/// — otherwise `testPushStatus` would stay `.sending` forever.
private let pushTokenWaitSeconds: UInt64 = 5

/// Ensure this device is registered with the agent's push plugin — mirrors the C4
/// `SessionListFeature` register path (obtain a device token, `registerPush` it threading the
/// compile-time APNs env + app version). The app never signs pushes (the plugin signs with a
/// shared secret), so there is nothing to persist on success.
///
/// Shared by the toggle-grant and "send test notification" paths. The wait for a device token
/// is **bounded** (`pushTokenWaitSeconds`): the first emitted token wins, but if none arrives
/// in time we fall back to the last persisted token. Returns `true` when registration
/// succeeded so the caller can surface a failure instead of hanging.
@Sendable
private func ensurePushRegistered(
  rest: HermesRESTClient,
  push: PushClient,
  preferences: PreferencesClient,
  connection: ServerConnection,
  clock: any Clock<Duration>
) async -> Bool {
  let scope = connection.notificationPreferenceScope
  guard !Task.isCancelled, preferences.loadNotificationsEnabled(scope) != false else { return false }
  // Race the live token stream against a timeout; fall back to the persisted token.
  let token: String? = await withTaskGroup(of: String?.self) { group in
    group.addTask {
      for await token in push.register() { return token }
      return nil
    }
    group.addTask {
      try? await clock.sleep(for: .seconds(pushTokenWaitSeconds))
      return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
  } ?? preferences.loadPushDeviceToken()

  guard let token else { return false }
  let registered = LockIsolated(false)
  await preferences.notificationOperation(scope) {
    guard !Task.isCancelled, preferences.loadNotificationsEnabled(scope) != false else { return }
    preferences.savePushDeviceToken(token)
    do {
      try await rest.registerPush(connection, token, PushClient.apnsEnv, push.appVersion())
      registered.setValue(preferences.loadNotificationsEnabled(scope) != false)
    } catch { }
  }
  return registered.value
}

import ComposableArchitecture
import HermesKit
import SwiftUI
import UIKit

/// Everyday preferences, with connection controls one level deeper under Advanced.
struct SettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  /// Presentation-only: the "how push works / install the plugin" info sheet. Pure view
  /// state — there's no reducer behavior behind it.
  @State private var showingPushGuide = false
  @AppStorage(TextSizePreference.storageKey) private var textSize = TextSizePreference.system.rawValue

  var body: some View {
    Form {
      Section {
        Picker("Text size", selection: $textSize) {
          ForEach(TextSizePreference.allCases) { size in
            Text(size.label).tag(size.rawValue)
          }
        }
      } header: {
        Text("Appearance")
      } footer: {
        Text("Applies to the whole app, including chats. “Match iPhone setting” follows Settings → Display & Brightness → Text Size.")
      }

      Section {
        Toggle(isOn: Binding(
          get: { store.displayPrefs.showThinkingRows },
          set: { store.send(.showThinkingRowsToggled($0)) }
        )) {
          Label("Show past thoughts", systemImage: "brain")
        }

        Toggle(isOn: Binding(
          get: { store.displayPrefs.showToolRows },
          set: { store.send(.showToolRowsToggled($0)) }
        )) {
          Label("Show activity details", systemImage: "wrench.and.screwdriver")
        }

        Toggle(isOn: Binding(
          get: { store.displayPrefs.autoFollowEnabled },
          set: { store.send(.autoFollowToggled($0)) }
        )) {
          Label("Follow new output", systemImage: "arrow.down.to.line")
        }
      } header: {
        Text("New chats")
      } footer: {
        Text("Defaults for chats you open later. Change the current chat from its ⋯ menu; live progress remains visible.")
      }

      // Only offered when the agent supports session deletion — otherwise Archive is the
      // only destructive action and the choice would be meaningless.
      if store.deleteSupported {
        Section {
          Picker(
            "Default swipe action",
            selection: Binding(
              get: { store.defaultSwipeAction },
              set: { store.send(.defaultSwipeActionChanged($0)) }
            )
          ) {
            Text("Archive").tag(SessionSwipeAction.archive)
            Text("Delete").tag(SessionSwipeAction.delete)
          }
        } header: {
          Text("Chats")
        } footer: {
          Text("The action a full swipe on a chat triggers. The long-press menu always offers both.")
        }
      }

      Section {
        // Plugin update, offered above the toggle because an out-of-date plugin sends pushes
        // the user is actively complaining about. Shown whether or not push is currently
        // available — an installed-but-disabled plugin is still worth updating.
        if store.pluginUpdateAvailable {
          VStack(alignment: .leading, spacing: 4) {
            Label("Plugin update available", systemImage: "arrow.down.circle")
              .font(.subheadline.weight(.semibold))
            Text(pluginUpdateExplanation)
              .font(.footnote).foregroundStyle(.secondary)
          }
          Button("Update plugin") { store.send(.updatePluginTapped) }
            .disabled(store.pluginUpdate == .updating)
        } else if store.pluginUpdateNeedsManualSteps {
          // Out of date but the agent can't pull it (pip install / hand-copied directory), so
          // a button here would only 400. Route to the guide, which offers the chat prompt.
          VStack(alignment: .leading, spacing: 4) {
            Label("Plugin update available", systemImage: "arrow.down.circle")
              .font(.subheadline.weight(.semibold))
            Text("\(pluginUpdateExplanation) This copy can't be updated from the app — ask your agent to update it.")
              .font(.footnote).foregroundStyle(.secondary)
          }
          Button("How to update the plugin") { showingPushGuide = true }
            .font(.footnote)
        }
        switch store.pluginUpdate {
        case .idle:
          EmptyView()
        case .updating:
          Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
            .foregroundStyle(.secondary).font(.footnote)
        case .updated:
          // A pull only changes files on disk — the running agent keeps the old code loaded.
          // This restart notice is the whole point of the success state; don't soften it.
          Label(
            "Plugin updated. Restart your Hermes agent to apply it.",
            systemImage: "exclamationmark.arrow.triangle.2.circlepath"
          )
          .foregroundStyle(.orange).font(.footnote)
        case .alreadyCurrent:
          Label("Plugin is already up to date", systemImage: "checkmark.circle")
            .foregroundStyle(.green).font(.footnote)
        case let .failed(reason):
          Label(reason, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange).font(.footnote)
        }

        if store.pushAvailable {
          Toggle(
            "Notify me about approvals",
            isOn: Binding(
              get: { store.notificationsEnabled },
              set: { store.send(.notificationsToggled($0)) }
            )
          )
          if store.notificationsDenied {
            VStack(alignment: .leading, spacing: 4) {
              Label("Notifications are turned off", systemImage: "bell.slash")
                .foregroundStyle(.orange).font(.footnote)
              if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Enable in iOS Settings", destination: url)
                  .font(.footnote)
              }
            }
          }
          Button("Send test notification") { store.send(.sendTestPushTapped) }
            .disabled(store.testPushStatus == .sending)
          switch store.testPushStatus {
          case .idle:
            EmptyView()
          case .sending:
            Label("Sending…", systemImage: "paperplane")
              .foregroundStyle(.secondary).font(.footnote)
          case .sent:
            Label("Test notification sent", systemImage: "checkmark.circle")
              .foregroundStyle(.green).font(.footnote)
          case .failed:
            Label("Couldn't send test notification", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange).font(.footnote)
          }
          Button("How push notifications work") { showingPushGuide = true }
            .font(.footnote)
        } else {
          Label("Notifications aren't available on this server", systemImage: "bell.slash")
            .foregroundStyle(.secondary).font(.footnote)
          Button("How to enable push notifications") { showingPushGuide = true }
        }
      } header: {
        Text("Notifications")
      } footer: {
        if store.pushAvailable {
          Text("Get a push when Hermes needs your approval, even while the app is closed.")
        } else {
          Text("Needs the hermes-push plugin running on your agent.")
        }
      }

      Section("About") {
        LabeledContent("Version", value: appVersion)
      }

      Section {
        NavigationLink("Connection & diagnostics") {
          AdvancedConnectionView(store: store)
        }
      } header: {
        Text("Advanced")
      } footer: {
        Text("Server address, sign-in token, connection checks and disconnect.")
      }
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { store.send(.doneTapped) }
      }
    }
    .sheet(isPresented: $showingPushGuide) {
      PushSetupGuideView(
        // Installed → the sheet drops the "Later" snooze and asks the agent to UPDATE rather
        // than install. It is never purely informational: an installed-but-outdated plugin is
        // exactly the case that needs an action here.
        pluginInstalled: store.pushAvailable,
        onAskAgent: {
          showingPushGuide = false
          store.send(.askAgentToInstallTapped)
        },
        onLater: { showingPushGuide = false }
      )
    }
    .task { store.send(.task) }
  }

  /// "0.1.0 (66)" — marketing version plus build number, straight from the Info.plist.
  private var appVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(version) (\(build))"
  }

  /// Why the update matters, naming both versions when the agent reported one. Kept in the
  /// view because it is pure display copy — the decision to show it lives in the reducer.
  private var pluginUpdateExplanation: String {
    let latest = PushSetup.minimumPluginVersion
    let reason = "Older versions send a “Turn complete” push each time a delegated subagent finishes."
    guard let installed = store.pushPlugin?.version else {
      return "Update to \(latest). \(reason)"
    }
    return "Installed \(installed), latest \(latest). \(reason)"
  }
}

/// Keeps the same feature store alive so saving, reconnecting and disconnecting still
/// run through the existing reducer actions, even when this destination is pushed.
private struct AdvancedConnectionView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section("Server") {
        LabeledContent("URL", value: store.serverURLString)
      }

      Section {
        SecureField("Session token", text: $store.token)
          .textContentType(.password)
        Button("Save token") { store.send(.saveTokenTapped) }
          .disabled(!store.canSaveToken)
        if store.savedConfirmation {
          Label("Token saved", systemImage: "checkmark.circle")
            .foregroundStyle(.green).font(.footnote)
        }
      } header: {
        Text("Token")
      } footer: {
        Text("Re-paste the stable token if it changed on the server.")
      }

      Section("Connection") {
        Button("Reconnect") { store.send(.reconnectTapped) }
        Button("Copy Connection & Send diagnostics") {
          store.send(.copyConnectionTraceTapped)
        }
        Text("Copies only local timestamps, slot numbers, random send IDs, outcomes and row counts. Review before sharing.")
          .font(.footnote).foregroundStyle(.secondary)
        NavigationLink {
          ConnectionDebugView(entries: store.log)
        } label: {
          LabeledContent("Debug log", value: "\(store.log.count)")
        }
      }

      Section {
        Button("Clear token & disconnect", role: .destructive) {
          store.send(.clearTokenTapped)
        }
      } footer: {
        Text("Removes the token from the Keychain and returns to the connection screen.")
      }
    }
    .navigationTitle("Connection")
    .navigationBarTitleDisplayMode(.inline)
  }
}

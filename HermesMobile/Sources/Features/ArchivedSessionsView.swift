import ComposableArchitecture
import HermesKit
import SwiftUI

/// The Archived sessions sheet: a flat list of soft-archived sessions. Swipe (or long-press)
/// to **Restore** (un-archive) or **Delete** permanently (immediate, no confirmation —
/// this is the bulk-cleanup surface), or tap to open/resume the session in the main stack.
struct ArchivedSessionsView: View {
  @Bindable var store: StoreOf<ArchivedSessionsFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      if let error = store.loadError {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .listRowSeparator(.hidden)
      }
      ForEach(store.sessions) { session in
        Button {
          store.send(.sessionTapped(id: session.id))
        } label: {
          SessionRowView(session: session, now: store.now)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
          // Delete FIRST: SwiftUI places the first listed button nearest the edge and
          // makes it the full-swipe target — a full swipe deletes (immediately, no
          // confirmation), matching the destructive-nearest-edge convention.
          if store.deleteSupported {
            deleteButton(session)
          }
          restoreButton(session)
            .tint(.green)
        }
        .contextMenu {
          restoreButton(session)
          Button("Copy ID", systemImage: "doc.on.doc") {
            store.send(.copyIDButtonTapped(id: session.id))
          }
          if store.deleteSupported {
            deleteButton(session)
          }
        }
      }
    }
    .listStyle(.plain)
    .listSectionSeparator(.hidden)
    .overlay {
      if store.sessions.isEmpty, !store.isLoading, store.loadError == nil {
        ContentUnavailableView("No archived chats", systemImage: "archivebox")
      }
    }
    .overlay(alignment: .bottom) {
      CopiedToastView(token: store.copiedIDToastToken)
    }
    .navigationTitle("Archived")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Done") { dismiss() }
      }
    }
    .task { store.send(.task) }
  }

  private func restoreButton(_ session: Session) -> some View {
    Button("Restore", systemImage: "arrow.uturn.backward") {
      store.send(.restoreButtonTapped(id: session.id))
    }
  }

  private func deleteButton(_ session: Session) -> some View {
    Button("Delete", systemImage: "trash", role: .destructive) {
      store.send(.deleteButtonTapped(id: session.id))
    }
  }
}

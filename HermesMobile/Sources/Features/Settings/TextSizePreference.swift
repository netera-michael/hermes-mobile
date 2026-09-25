import SwiftUI
import UIKit

/// In-app text size, overriding the iOS Dynamic Type setting for this app only.
///
/// Applied as a window trait override (`preferredContentSizeCategory`), so it reaches every
/// SwiftUI view, sheet and self-sizing transcript cell through the normal trait hierarchy —
/// no per-view plumbing. `.system` removes the override and follows iOS Settings again.
/// Presentation-only: stored in `UserDefaults` via `@AppStorage`, no reducer involvement.
enum TextSizePreference: String, CaseIterable, Identifiable {
  case system, extraSmall, small, standard, large, extraLarge, huge

  static let storageKey = "hermes.textSize"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .system: "Match iPhone setting"
    case .extraSmall: "Extra small"
    case .small: "Small"
    case .standard: "Default"
    case .large: "Large"
    case .extraLarge: "Extra large"
    case .huge: "Huge"
    }
  }

  /// `nil` = no override. `.large` is iOS's own default size, hence "Default".
  var category: UIContentSizeCategory? {
    switch self {
    case .system: nil
    case .extraSmall: .small
    case .small: .medium
    case .standard: .large
    case .large: .extraLarge
    case .extraLarge: .extraExtraLarge
    case .huge: .extraExtraExtraLarge
    }
  }

  /// Push the override onto every window of every connected scene (iPad can have several).
  @MainActor
  static func apply(rawValue: String) {
    let preference = TextSizePreference(rawValue: rawValue) ?? .system
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      for window in scene.windows {
        if let category = preference.category {
          window.traitOverrides.preferredContentSizeCategory = category
        } else {
          window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        }
      }
    }
  }
}

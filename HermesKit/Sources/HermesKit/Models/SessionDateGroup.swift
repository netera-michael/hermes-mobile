import Foundation

/// A chronological session-list section. The newest/today group has no label because the
/// list's existing top-level "Sessions" header names it; older groups use desktop-parity
/// calendar labels. Branch children stay in their parent's group.
public struct SessionDateGroup: Equatable, Sendable, Identifiable {
  public var id: String
  public var label: String?
  public var entries: [SessionBranchEntry]

  public init(id: String, label: String?, entries: [SessionBranchEntry]) {
    self.id = id
    self.label = label
    self.entries = entries
  }
}

public enum SessionDateGrouping {
  /// Group already-recency-ordered entries by the top-level row's local calendar bucket.
  /// A branch row inherits the preceding top-level parent cluster, so date dividers never
  /// split a parent from its children. The human day rolls over at 4 AM, matching Desktop.
  public static func groups(
    _ entries: [SessionBranchEntry],
    now: Date,
    calendar: Calendar = .current
  ) -> [SessionDateGroup] {
    guard !entries.isEmpty else { return [] }

    var result: [SessionDateGroup] = []
    var currentID: String?

    for entry in entries {
      let bucket: (id: String, label: String?)
      if entry.branchStem != nil, let currentID {
        bucket = (currentID, result.last?.label)
      } else {
        bucket = dateBucket(for: entry.session.updatedAt ?? .distantPast, now: now, calendar: calendar)
      }

      if result.last?.id == bucket.id {
        result[result.count - 1].entries.append(entry)
      } else {
        result.append(SessionDateGroup(id: bucket.id, label: bucket.label, entries: [entry]))
        currentID = bucket.id
      }
    }

    return result
  }

  private static func dateBucket(
    for date: Date,
    now: Date,
    calendar inputCalendar: Calendar
  ) -> (id: String, label: String?) {
    var calendar = inputCalendar
    calendar.locale = inputCalendar.locale ?? .current

    // Treat 00:00–03:59 as part of the previous evening, like Desktop.
    let shiftedDate = calendar.date(byAdding: .hour, value: -4, to: date) ?? date
    let shiftedNow = calendar.date(byAdding: .hour, value: -4, to: now) ?? now
    let day = calendar.startOfDay(for: shiftedDate)
    let today = calendar.startOfDay(for: shiftedNow)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

    if day >= today { return ("today", nil) }
    if day >= yesterday { return ("yesterday", "Yesterday") }

    let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
    if day >= weekStart { return ("this-week", "Earlier This Week") }

    let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
    if day >= lastWeekStart { return ("last-week", "Last Week") }

    let monthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
    if day >= monthStart { return ("this-month", "Earlier This Month") }

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = calendar.locale
    formatter.timeZone = calendar.timeZone
    if calendar.component(.year, from: day) == calendar.component(.year, from: today) {
      formatter.dateFormat = "LLLL"
    } else {
      formatter.dateFormat = "LLLL yyyy"
    }
    let label = formatter.string(from: day)
    return ("month:\(calendar.component(.year, from: day))-\(calendar.component(.month, from: day))", label)
  }
}

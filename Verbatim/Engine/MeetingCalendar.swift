import EventKit
import os

/// The people invited to the call, from the event in Calendar happening now. Their names help the
/// speech model and Claude spell them right. Only read when "Names from Calendar" is on.
enum MeetingCalendar {
    private static let store = EKEventStore()
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "meetings")

    static var allowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asks for Calendar access. Returns whether it was given.
    static func requestAccess() async -> Bool {
        if allowed { return true }
        do { return try await store.requestFullAccessToEvents() } catch {
            log.error("calendar access failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Names of the other people in the event that's on now (or starts within 10 minutes), without you.
    /// Empty when it's off, not allowed, or there's no event with people in it.
    static func attendees(at date: Date = Date()) -> [String] {
        guard Prefs.meetingCalendar, allowed else { return [] }
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-3 * 3600),
                                                 end: date.addingTimeInterval(600), calendars: nil)
        let events = store.events(matching: predicate).filter {
            !$0.isAllDay && $0.hasAttendees && $0.startDate <= date.addingTimeInterval(600) && $0.endDate > date
        }
        // Several at once: the one that started closest to now.
        guard let event = events.min(by: { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) })
        else { return [] }
        var names: [String] = []
        for p in (event.attendees ?? []) + [event.organizer].compactMap({ $0 }) where !p.isCurrentUser {
            guard let name = p.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  !name.contains("@"), !names.contains(name) else { continue }
            names.append(name)
        }
        log.notice("calendar: \(names.count) people in the event")
        return names
    }
}

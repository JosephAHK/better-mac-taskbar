import AppKit
import EventKit

/// One row of the calendar flyout's "Up Next" list — plain values copied out of an
/// EKEvent on the fetch queue, so nothing EventKit-owned ever crosses to main.
struct UpcomingEvent: Sendable, Equatable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// The calendar's colour in sRGB; EKCalendar/NSColor stay on the fetch queue.
    let red: Double
    let green: Double
    let blue: Double
    /// Opens this event (this occurrence, for repeating ones) in Calendar.
    let url: URL?

    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// Upcoming events for the calendar flyout, read from EventKit.
///
/// Fetches only while the flyout is open (on open, on store changes, and on the
/// clock's minute tick) and keeps the last result, so reopening shows the cached
/// list at once and the refresh lands a moment later. Access is never requested
/// at launch — only the first time the flyout opens.
@MainActor
final class UpcomingEvents {
    static let shared = UpcomingEvents()

    /// Posted on main when `events` or `access` changes.
    static let didChange = Notification.Name("UpcomingEventsDidChange")

    enum Access: Sendable, Equatable {
        case notDetermined
        case granted
        /// Denied, restricted, or write-only (which can't read events).
        case denied
    }

    /// From now through the end of the sixth day after today, like the Calendar widget.
    nonisolated private static let dayCount = 7

    private(set) var access: Access
    private(set) var events: [UpcomingEvent] = []

    private var isWatching = false
    /// Once per run: a prompt dismissed without an answer leaves the status
    /// .notDetermined, and asking again on every minute tick would loop.
    private var hasRequested = false
    /// Only the newest fetch is delivered, so a slow one can't overwrite a later one.
    private var generation = 0
    /// Set when access turns to granted after having been something else, so the
    /// next fetch resets the store — one created before the grant can keep
    /// returning nothing.
    private var needsReset = false

    private static let queue = DispatchQueue(label: "BetterMacTaskbar.upcoming-events", qos: .userInitiated)
    /// EKEventStore and the EKEvents it vends aren't Sendable, so the store is only
    /// ever touched on `queue`, which is what makes the unsafe access sound. Lazy
    /// (static let) so its costly init happens there on first fetch, not at launch.
    nonisolated(unsafe) private static let store = EKEventStore()

    private init() {
        access = Self.currentAccess()
        // EventKit posts this on an arbitrary thread.
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfWatching() }
        }
        // Minute tick: drops events that just ended and moves the "now" highlight.
        NotificationCenter.default.addObserver(forName: TaskbarClock.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfWatching() }
        }
    }

    /// Flyout opened: refresh now and keep refreshing until `endWatching`.
    func beginWatching() {
        isWatching = true
        refresh()
    }

    func endWatching() {
        isWatching = false
    }

    private func refreshIfWatching() {
        if isWatching { refresh() }
    }

    private func refresh() {
        setAccess(Self.currentAccess())
        switch access {
        case .notDetermined:
            requestAccess()
        case .denied:
            generation += 1
            publish([])
        case .granted:
            fetch()
        }
    }

    private func setAccess(_ new: Access) {
        guard new != access else { return }
        AppLog.info("calendar access changed", ["from": "\(access)", "to": "\(new)"])
        if new == .granted { needsReset = true }
        access = new
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Set while our access request awaits an answer. macOS can hold a request
    /// indefinitely (behind another app's pending permission prompt, say), so this
    /// alone doesn't mean a prompt is on screen — see `isAccessPromptInFront`.
    private var isRequestingAccess = false

    /// True while the system's Calendar prompt has focus. It is clicked in, which
    /// would otherwise close the flyout it was asked from — and the events the user
    /// just allowed would never appear.
    var isAccessPromptInFront: Bool {
        isRequestingAccess
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.UserNotificationCenter"
    }

    private func requestAccess() {
        guard !hasRequested else { return }
        hasRequested = true
        isRequestingAccess = true
        Self.queue.async {
            let completion: @Sendable (Bool, Error?) -> Void = { _, _ in
                // Re-read the status rather than trusting `granted`: on 14+ it's the
                // status that tells full access apart from write-only.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let events = UpcomingEvents.shared
                        events.isRequestingAccess = false
                        // Recorded even if the flyout closed while the prompt was up.
                        events.setAccess(Self.currentAccess())
                        events.refreshIfWatching()
                    }
                }
            }
            if #available(macOS 14.0, *) {
                Self.store.requestFullAccessToEvents(completion: completion)
            } else {
                Self.store.requestAccess(to: .event, completion: completion)
            }
        }
    }

    private func fetch() {
        generation += 1
        let requested = generation
        let reset = needsReset
        needsReset = false
        Self.queue.async {
            let result = Self.load(now: Date(), calendar: .autoupdatingCurrent, reset: reset)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let events = UpcomingEvents.shared
                    guard requested == events.generation else { return }
                    events.publish(result)
                }
            }
        }
    }

    private func publish(_ new: [UpcomingEvent]) {
        guard new != events else { return }
        if new.count != events.count {
            AppLog.debug("upcoming events changed", ["count": new.count])
        }
        events = new
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static func currentAccess() -> Access {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined { return .notDetermined }
        if #available(macOS 14.0, *) {
            return status == .fullAccess ? .granted : .denied
        }
        return status == .authorized ? .granted : .denied
    }

    // MARK: - Fetch queue

    /// Runs on `queue`. Sorted by day, all-day first within a day, then start time.
    nonisolated private static func load(now: Date, calendar: Calendar, reset: Bool) -> [UpcomingEvent] {
        if reset { store.reset() }
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: dayCount, to: today) else { return [] }

        // Overlap semantics: an event already in progress at `now` is included.
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let recurringStamp = DateFormatter()
        recurringStamp.locale = Locale(identifier: "en_US_POSIX")
        recurringStamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"

        let events = store.events(matching: predicate).compactMap { event -> UpcomingEvent? in
            guard let start = event.startDate, let finish = event.endDate, finish > now else { return nil }
            let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            if declined { return nil }

            let rgb = (event.calendar as EKCalendar?)?.color.usingColorSpace(.sRGB)
            let title = (event.title as String?) ?? ""
            return UpcomingEvent(
                title: title.isEmpty ? "New Event" : title,
                start: start,
                end: finish,
                isAllDay: event.isAllDay,
                red: Double(rgb?.redComponent ?? 0.5),
                green: Double(rgb?.greenComponent ?? 0.5),
                blue: Double(rgb?.blueComponent ?? 0.5),
                url: showURL(for: event, start: start, stamp: recurringStamp)
            )
        }

        return events.sorted { a, b in
            let dayA = calendar.startOfDay(for: max(a.start, today))
            let dayB = calendar.startOfDay(for: max(b.start, today))
            if dayA != dayB { return dayA < dayB }
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            if a.start != b.start { return a.start < b.start }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// `ical://ekevent/<calendarItemIdentifier>?method=show&options=more` is the
    /// handler Calendar.app registers for "show this event" (used the same way by
    /// Calendr, MeetingBar and Raycast's calendar extension). The identifier names
    /// the whole series, so a repeating event also gets the occurrence's start,
    /// UTC for timed events and floating local time for all-day ones, or Calendar
    /// jumps to the first occurrence.
    nonisolated private static func showURL(for event: EKEvent, start: Date, stamp: DateFormatter) -> URL? {
        guard let id = event.calendarItemIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        var occurrence = ""
        if event.hasRecurrenceRules {
            stamp.timeZone = event.isAllDay ? .current : TimeZone(secondsFromGMT: 0)
            occurrence = "/" + stamp.string(from: start)
        }
        return URL(string: "ical://ekevent\(occurrence)/\(id)?method=show&options=more")
    }
}

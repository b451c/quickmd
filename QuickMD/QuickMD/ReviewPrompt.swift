import Foundation

// MARK: - Review prompt policy (App Store build)

/// When to ask for an App Store rating: only after real, repeated use — never
/// on a first launch, never twice for one version, never more often than every
/// 120 days. Apple throttles `requestReview` on its own (at most three prompts
/// a year), but a prompt it does show at the wrong moment costs goodwill, so
/// the app asks only when a reader has clearly settled in.
///
/// Pure policy: no StoreKit, no SwiftUI, no clock of its own (`now` is always
/// passed in) and an injectable `UserDefaults`, so every rule is unit-tested.
/// It compiles into both builds, but only the App Store build calls it
/// (`ReviewPromptTrigger`, `#if APPSTORE`); the GitHub/Homebrew build never
/// touches these keys.
///
/// Anything unreadable in the defaults (wrong type, a hand-edited value, a
/// date from the future) reads as "nothing recorded yet": it can delay a
/// prompt, never cause one or crash.
struct ReviewPrompt {

    /// Every key lives under this prefix.
    static let keyPrefix = "reviewPrompt."

    enum Keys {
        /// Int — documents that finished their first render, ever.
        static let openCount = ReviewPrompt.keyPrefix + "openCount"
        /// [String] — local calendar days (`yyyy-MM-dd`) with at least one
        /// open, newest `maximumStoredDays` only.
        static let openDays = ReviewPrompt.keyPrefix + "openDays"
        /// Date — the first recorded open.
        static let firstOpen = ReviewPrompt.keyPrefix + "firstOpen"
        /// Date — the last time we asked StoreKit for a review.
        static let lastRequest = ReviewPrompt.keyPrefix + "lastRequest"
        /// String — `CFBundleShortVersionString` of that request.
        static let lastRequestVersion = ReviewPrompt.keyPrefix + "lastRequestVersion"
    }

    static let minimumOpens = 10
    static let minimumDistinctDays = 3
    static let minimumDaysSinceFirstOpen = 7
    static let minimumDaysBetweenRequests = 120
    /// The day set only has to answer "at least 3 days"; 30 keeps it bounded
    /// for a reader who opens documents every day for years.
    static let maximumStoredDays = 30
    /// At the moment of asking, the reader must have touched a key, the mouse
    /// or the trackpad within this many seconds: a window left open on an
    /// unattended Mac is not reading.
    static let maximumIdleAtRequest: TimeInterval = 60

    private static let secondsPerDay: TimeInterval = 86_400

    let defaults: UserDefaults
    /// Decides what "a day" is for the distinct-days rule (the user's local
    /// days in the app; a fixed time zone in tests).
    let calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    // MARK: Recording

    /// One document window/tab finished its first successful render. The
    /// caller guarantees once per window — reloads, zoom, theme changes and
    /// Source Edit saves are not new opens.
    func recordDocumentOpened(now: Date) {
        let count = openCount
        defaults.set(count == Int.max ? count : count + 1, forKey: Keys.openCount)

        // Sorted ascending; the key format sorts chronologically, so the cap
        // keeps the newest days even if the clock was once set back.
        var days = openDays
        days.insert(dayKey(for: now))
        defaults.set(Array(days.sorted().suffix(Self.maximumStoredDays)), forKey: Keys.openDays)

        // A missing, unreadable or future first-open date (clock set forward
        // once) would block the age rule for good: restart it from today.
        let firstIsUsable = firstOpen.map { $0 <= now } ?? false
        if !firstIsUsable {
            defaults.set(now, forKey: Keys.firstOpen)
        }
    }

    // MARK: Deciding

    /// True only when ALL hold: ≥ 10 opens, opens on ≥ 3 distinct days, ≥ 7
    /// days since the first open, no request yet for `appVersion`, and ≥ 120
    /// days since the last request (if there was one).
    func shouldRequest(now: Date, appVersion: String) -> Bool {
        guard openCount >= Self.minimumOpens else { return false }
        guard openDays.count >= Self.minimumDistinctDays else { return false }
        guard let first = firstOpen,
              now.timeIntervalSince(first) >= Double(Self.minimumDaysSinceFirstOpen) * Self.secondsPerDay
        else { return false }
        if let version = lastRequestVersion, version == appVersion { return false }
        if let last = lastRequest,
           now.timeIntervalSince(last) < Double(Self.minimumDaysBetweenRequests) * Self.secondsPerDay {
            // Also true for a request date in the future: wait, don't guess.
            return false
        }
        return true
    }

    /// Called right after the app asked StoreKit — whether or not the system
    /// actually showed the prompt (it never says).
    func markRequested(now: Date, appVersion: String) {
        defaults.set(now, forKey: Keys.lastRequest)
        defaults.set(appVersion, forKey: Keys.lastRequestVersion)
    }

    /// True when the last user input (seconds ago, from the system's event
    /// source) is recent enough to ask. Negative / NaN / infinite = unknown =
    /// not active: an unreadable answer must not cause a prompt.
    static func isUserActive(secondsSinceLastInput: TimeInterval) -> Bool {
        secondsSinceLastInput.isFinite
            && secondsSinceLastInput >= 0
            && secondsSinceLastInput < maximumIdleAtRequest
    }

    // MARK: Stored values, garbage-tolerant

    var openCount: Int {
        guard let count = defaults.object(forKey: Keys.openCount) as? Int, count > 0 else { return 0 }
        return count
    }

    /// Valid day keys only — a hand-written "x" must not count as a day.
    var openDays: Set<String> {
        guard let stored = defaults.object(forKey: Keys.openDays) as? [Any] else { return [] }
        return Set(stored.compactMap { $0 as? String }.filter(Self.isDayKey))
    }

    var firstOpen: Date? { Self.validDate(defaults.object(forKey: Keys.firstOpen)) }
    var lastRequest: Date? { Self.validDate(defaults.object(forKey: Keys.lastRequest)) }

    var lastRequestVersion: String? {
        guard let version = defaults.object(forKey: Keys.lastRequestVersion) as? String,
              !version.isEmpty else { return nil }
        return version
    }

    // MARK: Helpers

    /// `yyyy-MM-dd` in `calendar`'s time zone. Built from components, not a
    /// DateFormatter: no locale (or non-Gregorian era) can change the shape.
    func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func isDayKey(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count == 10 else { return false }
        for (index, byte) in bytes.enumerated() {
            if index == 4 || index == 7 {
                guard byte == UInt8(ascii: "-") else { return false }
            } else {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return false }
            }
        }
        return true
    }

    private static func validDate(_ value: Any?) -> Date? {
        guard let date = value as? Date, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return date
    }
}

// MARK: - Continuous display countdown

/// "The window has been on screen for 60 s in one go." Fed by a periodic tick
/// (about once a second) with whether the window is displayed right now; any
/// tick that is not resets the run. Pure so the rule is tested without timers.
///
/// Times are MONOTONIC seconds (`ProcessInfo.systemUptime`: it does not
/// advance while the Mac sleeps, and no clock change moves it). A gap of more
/// than `maximumGap` between two ticks also resets the run: the ticks stopped
/// (sleep, App Nap, a stalled main thread), so nobody can say the window was
/// being read in between.
struct ReviewPromptCountdown {
    let required: TimeInterval
    let maximumGap: TimeInterval
    /// Start of the current uninterrupted run; nil = not displayed.
    private(set) var displayedSince: TimeInterval?
    /// The previous displayed tick of this run.
    private(set) var lastTick: TimeInterval?

    init(required: TimeInterval, maximumGap: TimeInterval = 3) {
        self.required = required
        self.maximumGap = maximumGap
    }

    /// Returns true once `required` seconds of uninterrupted display have
    /// passed by `now`. Keeps returning true on later displayed ticks of the
    /// same run (the caller may still be waiting for other conditions).
    mutating func advance(isDisplayed: Bool, now: TimeInterval) -> Bool {
        guard isDisplayed else {
            reset()
            return false
        }
        guard let since = displayedSince, let last = lastTick,
              now >= last, now - last <= maximumGap else {
            displayedSince = now
            lastTick = now
            return false
        }
        lastTick = now
        return now - since >= required
    }

    /// Ends the current run (the window stopped being key); the next
    /// displayed tick starts a new one from zero.
    mutating func reset() {
        displayedSince = nil
        lastTick = nil
    }
}

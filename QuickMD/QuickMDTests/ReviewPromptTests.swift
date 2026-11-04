import XCTest
import Foundation

/// The App Store rating prompt's policy (`ReviewPrompt`) and its continuous
/// display countdown (`ReviewPromptCountdown`). Every date is built from a
/// fixed base in UTC, so nothing depends on the machine's clock, time zone or
/// speed.
final class ReviewPromptTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var policy: ReviewPrompt!
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-01-01 10:00 UTC.
    private let base = Date(timeIntervalSince1970: 1_767_261_600)
    private let version = "1.15.0"

    /// The per-test suite, stored in a temporary directory, never in
    /// `~/Library/Preferences` (see `TemporaryDefaults`).
    private var suite: TemporaryDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suite = try TemporaryDefaults("ReviewPromptTests")
        suiteName = suite.suiteName
        defaults = suite.defaults
        policy = ReviewPrompt(defaults: defaults, calendar: calendar)
    }

    override func tearDownWithError() throws {
        suite.remove()
        suite = nil
        defaults = nil
        policy = nil
        try super.tearDownWithError()
    }

    private func day(_ n: Int, hour: Int = 0) -> Date {
        base.addingTimeInterval(TimeInterval(n) * 86_400 + TimeInterval(hour) * 3_600)
    }

    /// `count` opens spread over days 0, 1 and 2 (the rest on day 2).
    private func recordQualifyingOpens(_ count: Int) {
        for i in 0..<count {
            policy.recordDocumentOpened(now: day(min(i, 2)))
        }
    }

    // MARK: - Opens threshold

    func testNineOpensDoNotQualifyTenDo() {
        recordQualifyingOpens(9)
        XCTAssertFalse(policy.shouldRequest(now: day(30), appVersion: version))
        policy.recordDocumentOpened(now: day(2))
        XCTAssertEqual(policy.openCount, 10)
        XCTAssertTrue(policy.shouldRequest(now: day(30), appVersion: version))
    }

    func testFreshInstallNeverQualifies() {
        XCTAssertFalse(policy.shouldRequest(now: day(1000), appVersion: version))
    }

    // MARK: - Distinct days

    func testSameDayOpensCountAsOneDay() {
        for hour in 0..<10 { policy.recordDocumentOpened(now: day(0, hour: hour)) }
        XCTAssertEqual(policy.openCount, 10)
        XCTAssertEqual(policy.openDays.count, 1)
        XCTAssertFalse(policy.shouldRequest(now: day(30), appVersion: version))

        policy.recordDocumentOpened(now: day(1))
        XCTAssertFalse(policy.shouldRequest(now: day(30), appVersion: version), "two days are not enough")
        policy.recordDocumentOpened(now: day(5))
        XCTAssertEqual(policy.openDays.count, 3)
        XCTAssertTrue(policy.shouldRequest(now: day(30), appVersion: version))
    }

    func testDaysFollowTheCalendarsTimeZone() {
        // 23:30 and 00:30 UTC are two days in UTC, one day in UTC+2.
        var plusTwo = Calendar(identifier: .gregorian)
        plusTwo.timeZone = TimeZone(secondsFromGMT: 7_200)!
        let local = ReviewPrompt(defaults: defaults, calendar: plusTwo)
        let late = base.addingTimeInterval(13.5 * 3_600)   // 23:30 UTC = 01:30 next day +2
        let early = base.addingTimeInterval(14.5 * 3_600)  // 00:30 UTC = 02:30 +2
        local.recordDocumentOpened(now: late)
        local.recordDocumentOpened(now: early)
        XCTAssertEqual(local.openDays.count, 1)
        XCTAssertEqual(policy.dayKey(for: late), "2026-01-01")
        XCTAssertEqual(policy.dayKey(for: early), "2026-01-02")
    }

    func testDaySetIsCappedToTheNewestDays() {
        for n in 0..<45 { policy.recordDocumentOpened(now: day(n)) }
        let stored = defaults.stringArray(forKey: ReviewPrompt.Keys.openDays) ?? []
        XCTAssertEqual(stored.count, ReviewPrompt.maximumStoredDays)
        XCTAssertEqual(stored.first, policy.dayKey(for: day(15)))
        XCTAssertEqual(stored.last, policy.dayKey(for: day(44)))
        XCTAssertEqual(policy.openCount, 45, "the open count is not capped")
    }

    // MARK: - Age since the first open

    func testSevenDaysSinceTheFirstOpen() {
        recordQualifyingOpens(10)
        XCTAssertEqual(policy.firstOpen, day(0))
        XCTAssertFalse(policy.shouldRequest(now: day(7).addingTimeInterval(-1), appVersion: version))
        XCTAssertTrue(policy.shouldRequest(now: day(7), appVersion: version))
    }

    func testFirstOpenIsNotMovedByLaterOpens() {
        policy.recordDocumentOpened(now: day(0))
        policy.recordDocumentOpened(now: day(3))
        XCTAssertEqual(policy.firstOpen, day(0))
    }

    // MARK: - Per-version guard and interval

    func testOneRequestPerVersion() {
        recordQualifyingOpens(10)
        policy.markRequested(now: day(10), appVersion: version)
        XCTAssertFalse(policy.shouldRequest(now: day(500), appVersion: version))
        XCTAssertTrue(policy.shouldRequest(now: day(500), appVersion: "1.16.0"))
    }

    func testOneHundredTwentyDaysBetweenRequests() {
        recordQualifyingOpens(10)
        policy.markRequested(now: day(10), appVersion: version)
        XCTAssertFalse(policy.shouldRequest(now: day(130).addingTimeInterval(-1), appVersion: "1.16.0"))
        XCTAssertTrue(policy.shouldRequest(now: day(130), appVersion: "1.16.0"))
    }

    func testMarkRequestedStoresDateAndVersion() {
        policy.markRequested(now: day(4), appVersion: version)
        XCTAssertEqual(policy.lastRequest, day(4))
        XCTAssertEqual(policy.lastRequestVersion, version)
    }

    func testKeysShareOnePrefix() {
        recordQualifyingOpens(10)
        policy.markRequested(now: day(10), appVersion: version)
        let ours = defaults.persistentDomain(forName: suiteName)?.keys.sorted() ?? []
        XCTAssertEqual(ours.count, 5)
        XCTAssertTrue(ours.allSatisfy { $0.hasPrefix(ReviewPrompt.keyPrefix) }, "\(ours)")
    }

    // MARK: - Garbage in the defaults

    func testGarbageValuesReadAsNothingRecorded() {
        defaults.set("lots", forKey: ReviewPrompt.Keys.openCount)
        defaults.set(["x", "2026-1-1", 42, "2026-01-0a"], forKey: ReviewPrompt.Keys.openDays)
        defaults.set("yesterday", forKey: ReviewPrompt.Keys.firstOpen)
        defaults.set(12, forKey: ReviewPrompt.Keys.lastRequestVersion)
        XCTAssertEqual(policy.openCount, 0)
        XCTAssertTrue(policy.openDays.isEmpty)
        XCTAssertNil(policy.firstOpen)
        XCTAssertNil(policy.lastRequestVersion)
        XCTAssertFalse(policy.shouldRequest(now: day(1000), appVersion: version))
    }

    func testGarbageIsRepairedByTheNextOpen() {
        defaults.set(-5, forKey: ReviewPrompt.Keys.openCount)
        defaults.set("not a list", forKey: ReviewPrompt.Keys.openDays)
        defaults.set(Data([1, 2, 3]), forKey: ReviewPrompt.Keys.firstOpen)
        policy.recordDocumentOpened(now: day(0))
        XCTAssertEqual(policy.openCount, 1)
        XCTAssertEqual(policy.openDays, [policy.dayKey(for: day(0))])
        XCTAssertEqual(policy.firstOpen, day(0))
    }

    func testGarbageCountWithEnoughDaysStillNeedsRealOpens() {
        defaults.set("999", forKey: ReviewPrompt.Keys.openCount)
        for n in 0..<3 { policy.recordDocumentOpened(now: day(n)) }
        XCTAssertEqual(policy.openCount, 3)
        XCTAssertFalse(policy.shouldRequest(now: day(30), appVersion: version))
    }

    func testFutureFirstOpenRestartsFromNow() {
        defaults.set(day(400), forKey: ReviewPrompt.Keys.firstOpen)
        policy.recordDocumentOpened(now: day(0))
        XCTAssertEqual(policy.firstOpen, day(0))
    }

    func testFutureRequestDateBlocks() {
        recordQualifyingOpens(10)
        defaults.set(day(200), forKey: ReviewPrompt.Keys.lastRequest)
        XCTAssertFalse(policy.shouldRequest(now: day(30), appVersion: version))
    }

    func testGarbageRequestDateReadsAsNever() {
        recordQualifyingOpens(10)
        defaults.set("soon", forKey: ReviewPrompt.Keys.lastRequest)
        XCTAssertNil(policy.lastRequest)
        XCTAssertTrue(policy.shouldRequest(now: day(30), appVersion: version))
    }

    func testSaturatedCountDoesNotOverflow() {
        defaults.set(Int.max, forKey: ReviewPrompt.Keys.openCount)
        policy.recordDocumentOpened(now: day(0))
        XCTAssertEqual(policy.openCount, Int.max)
    }

    func testDayKeyShape() {
        XCTAssertTrue(ReviewPrompt.isDayKey("2026-11-04"))
        XCTAssertFalse(ReviewPrompt.isDayKey("2026-11-4"))
        XCTAssertFalse(ReviewPrompt.isDayKey("2026/11/04"))
        XCTAssertFalse(ReviewPrompt.isDayKey("２０２６-11-04"))
        XCTAssertTrue(ReviewPrompt.isDayKey(policy.dayKey(for: base)))
    }

    // MARK: - Continuous display countdown

    /// Feeds displayed ticks one second apart from `start` through `end`
    /// (inclusive) and returns the last result.
    @discardableResult
    private func tick(_ countdown: inout ReviewPromptCountdown,
                      from start: TimeInterval, through end: TimeInterval) -> Bool {
        var result = false
        var now = start
        while now <= end {
            result = countdown.advance(isDisplayed: true, now: now)
            now += 1
        }
        return result
    }

    /// Monotonic seconds, like `systemUptime`.
    private let uptime: TimeInterval = 5_000

    func testCountdownNeedsUninterruptedDisplay() {
        var countdown = ReviewPromptCountdown(required: 60)
        XCTAssertFalse(tick(&countdown, from: uptime, through: uptime + 59))
        XCTAssertTrue(countdown.advance(isDisplayed: true, now: uptime + 60))
        XCTAssertTrue(countdown.advance(isDisplayed: true, now: uptime + 61), "a complete run stays complete")
    }

    func testCountdownRestartsAfterAnInterruption() {
        var countdown = ReviewPromptCountdown(required: 60)
        tick(&countdown, from: uptime, through: uptime + 50)
        XCTAssertFalse(countdown.advance(isDisplayed: false, now: uptime + 51))
        XCTAssertNil(countdown.displayedSince)
        XCTAssertFalse(tick(&countdown, from: uptime + 52, through: uptime + 111))
        XCTAssertTrue(countdown.advance(isDisplayed: true, now: uptime + 112))
    }

    func testCountdownRestartsAfterAGapBetweenTicks() {
        var countdown = ReviewPromptCountdown(required: 60, maximumGap: 3)
        tick(&countdown, from: uptime, through: uptime + 40)
        // 3 s since the previous tick is still continuous…
        XCTAssertFalse(countdown.advance(isDisplayed: true, now: uptime + 43))
        XCTAssertEqual(countdown.displayedSince, uptime)
        // …4 s is not (sleep, App Nap, a stalled main thread): a new run.
        XCTAssertFalse(countdown.advance(isDisplayed: true, now: uptime + 47))
        XCTAssertEqual(countdown.displayedSince, uptime + 47)
        XCTAssertFalse(tick(&countdown, from: uptime + 48, through: uptime + 106))
        XCTAssertTrue(countdown.advance(isDisplayed: true, now: uptime + 107))
    }

    func testCountdownResetStartsFromZero() {
        var countdown = ReviewPromptCountdown(required: 60)
        tick(&countdown, from: uptime, through: uptime + 59)
        countdown.reset()
        XCTAssertNil(countdown.displayedSince)
        XCTAssertNil(countdown.lastTick)
        XCTAssertFalse(countdown.advance(isDisplayed: true, now: uptime + 60))
    }

    // MARK: - Reading: display AND recent input on every tick

    /// Feeds the trigger's ticks one second apart, the window displayed, with
    /// the reader's input at `inputs` (monotonic seconds). Returns the first
    /// tick at which the run completed, or nil.
    private func firstCompletion(_ countdown: inout ReviewPromptCountdown,
                                 from start: TimeInterval, through end: TimeInterval,
                                 inputs: [TimeInterval]) -> TimeInterval? {
        var now = start
        while now <= end {
            let lastInput = inputs.filter { $0 <= now }.max()
            let idle = lastInput.map { now - $0 } ?? .infinity
            if countdown.advance(isDisplayed: true, secondsSinceLastInput: idle, now: now) { return now }
            now += 1
        }
        return nil
    }

    /// A window left open on an unattended Mac never completes a run.
    func testAnUnattendedWindowNeverCompletesARun() {
        var countdown = ReviewPromptCountdown(required: 60)
        XCTAssertNil(firstCompletion(&countdown, from: uptime, through: uptime + 600,
                                     inputs: [uptime - 1_000]))
        XCTAssertNil(firstCompletion(&countdown, from: uptime + 601, through: uptime + 900, inputs: []))
    }

    /// The E2E case (2026-11-04, App Store build): 150 s unattended, then a
    /// single mouse move and nothing more. The old trigger asked 33.6 s after
    /// that move, because the 60 s run had been counting while the reader was
    /// away. One touch must never be enough.
    func testASingleTouchAfterABreakIsNotEnough() {
        var countdown = ReviewPromptCountdown(required: 60)
        let touch = uptime + 150
        XCTAssertNil(firstCompletion(&countdown, from: uptime, through: touch + 300,
                                     inputs: [uptime - 1_000, touch]))
    }

    /// A reader who came back and keeps using the Mac (a scroll every 20 s)
    /// completes the run exactly one minute after coming back, not before.
    func testAnActiveReaderCompletesAMinuteAfterComingBack() {
        var countdown = ReviewPromptCountdown(required: 60)
        let back = uptime + 150
        let inputs = [uptime - 1_000] + stride(from: back, through: back + 200, by: 20).map { $0 }
        XCTAssertEqual(firstCompletion(&countdown, from: uptime, through: back + 200, inputs: inputs),
                       back + 60)
    }

    /// A pause that leaves a full minute without input ends the run before it
    /// completes: the minute is counted again from the first touch after it.
    func testAPauseOfAMinuteRestartsTheRun() {
        var countdown = ReviewPromptCountdown(required: 60)
        let start = uptime + 10    // one touch: active through start + 59, idle 60 s at start + 60
        let resume = start + 100
        let inputs = [start] + stride(from: resume, through: resume + 200, by: 20).map { $0 }
        XCTAssertEqual(firstCompletion(&countdown, from: uptime, through: resume + 200, inputs: inputs),
                       resume + 60)
    }

    func testCountdownSurvivesTimeGoingBack() {
        var countdown = ReviewPromptCountdown(required: 60)
        tick(&countdown, from: uptime, through: uptime + 30)
        XCTAssertFalse(countdown.advance(isDisplayed: true, now: uptime - 100))
        XCTAssertEqual(countdown.displayedSince, uptime - 100)
        XCTAssertTrue(tick(&countdown, from: uptime - 99, through: uptime - 40))
    }

    // MARK: - Idle check at the moment of asking

    func testUserActivityWindow() {
        XCTAssertTrue(ReviewPrompt.isUserActive(secondsSinceLastInput: 0))
        XCTAssertTrue(ReviewPrompt.isUserActive(secondsSinceLastInput: 59.9))
        XCTAssertFalse(ReviewPrompt.isUserActive(secondsSinceLastInput: 60))
        XCTAssertFalse(ReviewPrompt.isUserActive(secondsSinceLastInput: 3_600))
        XCTAssertFalse(ReviewPrompt.isUserActive(secondsSinceLastInput: -1))
        XCTAssertFalse(ReviewPrompt.isUserActive(secondsSinceLastInput: .nan))
        XCTAssertFalse(ReviewPrompt.isUserActive(secondsSinceLastInput: .infinity))
    }
}

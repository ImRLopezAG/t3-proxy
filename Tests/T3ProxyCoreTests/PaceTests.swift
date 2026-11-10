import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct QuotaPaceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func reading(_ kind: QuotaWindowKind, used: Double?, resetIn: TimeInterval, observedAgo: TimeInterval = 0) -> QuotaReading {
        QuotaReading(observedAt: now.addingTimeInterval(-observedAgo),
                     windows: [.init(id: kind == .session ? "five-hour" : "seven-day", label: kind.title, usedPercent: used,
                                     resetAt: now.addingTimeInterval(resetIn))],
                     models: [:], plan: nil)
    }

    @Test func screenshotCase() throws {
        // 38% of the week elapsed, 92% used: 54 points in deficit, empty in about 5h 34m at the average rate.
        let week = 7 * 86400.0
        let p = try #require(QuotaPace.of(reading(.weekly, used: 92, resetIn: week * 0.62), .weekly, now: now, calendar: utc))
        #expect(abs(p.expectedUsed - 38) < 0.001)
        #expect(p.roundedDelta == 54 && p.summary == "54% in deficit")
        #expect(p.stage == .deficit(.far))
        let eta = try #require(p.runsOutAt).timeIntervalSince(now)
        #expect(abs(eta - 8 / (92 / (week * 0.38))) < 1)
        #expect(p.projection(now: now) == "Runs out in 5h 33m")   // 8 ÷ (92% per 2.66 days) = 5h 33m 5s
        #expect(!p.lastsUntilReset)
        #expect(abs(p.expectedRemaining - 62) < 0.001)
    }

    @Test func reserveLastsUntilReset() throws {
        let p = try #require(QuotaPace.of(reading(.weekly, used: 20, resetIn: 3.5 * 86400), .weekly, now: now, calendar: utc))
        #expect(p.summary == "30% in reserve" && p.stage == .reserve(.far))
        #expect(p.lastsUntilReset && p.runsOutAt == nil)
        #expect(p.projection(now: now) == "Lasts until reset")
    }

    @Test func stagesAndOnPace() {
        #expect(QuotaPace.stage(2) == .onPace && QuotaPace.stage(-2) == .onPace)
        #expect(QuotaPace.stage(5) == .deficit(.slightly) && QuotaPace.stage(-10) == .reserve(.clearly))
        #expect(QuotaPace.stage(13) == .deficit(.far))
    }

    @Test func refusesWhatCannotBeJudged() {
        // No reset, past reset, reset further than a window away, unknown use.
        #expect(QuotaPace.of(QuotaReading(observedAt: now, windows: [.init(id: "seven-day", label: "", usedPercent: 10, resetAt: nil)], models: [:], plan: nil), .weekly, now: now) == nil)
        #expect(QuotaPace.of(reading(.weekly, used: 10, resetIn: -60), .weekly, now: now) == nil)
        #expect(QuotaPace.of(reading(.weekly, used: 10, resetIn: 8 * 86400), .weekly, now: now) == nil)
        #expect(QuotaPace.of(reading(.weekly, used: nil, resetIn: 86400), .weekly, now: now) == nil)
        // 5-hour: the first 3% of the window says nothing; a used-up window has no pace, only its reset.
        #expect(QuotaPace.of(reading(.session, used: 5, resetIn: 5 * 3600 - 300), .session, now: now) == nil)
        #expect(QuotaPace.of(reading(.session, used: 100, resetIn: 3600), .session, now: now) == nil)
        // A reading from before the current window started belongs to an older window.
        #expect(QuotaPace.of(reading(.session, used: 40, resetIn: 3600, observedAgo: 4.5 * 3600), .session, now: now) == nil)
    }

    @Test func rateIsMeasuredAtTheReading() throws {
        // Half the 5-hour window had passed at the reading (50% used); an hour later the even-pace mark has moved on.
        let p = try #require(QuotaPace.of(reading(.session, used: 50, resetIn: 1.5 * 3600, observedAgo: 3600), .session, now: now))
        #expect(abs(p.expectedUsed - 70) < 0.001)
        #expect(p.summary == "20% in reserve")
        #expect(p.lastsUntilReset)   // 50% per 2.5 h empties exactly at the reset
        let fast = try #require(QuotaPace.of(reading(.session, used: 80, resetIn: 1.5 * 3600, observedAgo: 3600), .session, now: now))
        // 80% in 2.5 h → 20% more takes 37.5 min after the reading, which is already past: runs out now.
        #expect(fast.runsOutAt == now && fast.projection(now: now) == "Runs out now")
    }

    @Test func weeklyDayMarksAreLocalMidnights() throws {
        // The window starts 3 h before today's UTC midnight (now is 08:00 UTC): seven midnights fall inside it.
        let start = utc.startOfDay(for: now).addingTimeInterval(-3 * 3600)
        let reset = start.addingTimeInterval(7 * 86400)
        let r = QuotaReading(observedAt: now, windows: [.init(id: "seven-day", label: "", usedPercent: 10, resetAt: reset)], models: [:], plan: nil)
        let p = try #require(QuotaPace.of(r, .weekly, now: now, calendar: utc))
        #expect(p.dayMarks.count == 7)
        #expect(abs(p.dayMarks[0] - 3.0 / 168 * 100) < 0.001)
        #expect(QuotaPace.of(reading(.session, used: 40, resetIn: 3600), .session, now: now)?.dayMarks == [])
    }

    @Test func dayMarksStayOnMidnightAfterASkippedMidnight() throws {
        // São Paulo, 4 Nov 2018: clocks jumped from 00:00 to 01:00, so that day began at 01:00.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let start = try #require(cal.date(from: DateComponents(year: 2018, month: 11, day: 1, hour: 12)))
        let reset = start.addingTimeInterval(7 * 86400)
        let now = start.addingTimeInterval(86400)
        let r = QuotaReading(observedAt: now, windows: [.init(id: "seven-day", label: "", usedPercent: 10, resetAt: reset)], models: [:], plan: nil)
        let p = try #require(QuotaPace.of(r, .weekly, now: now, calendar: cal))
        let hours = p.dayMarks.map { cal.component(.hour, from: start.addingTimeInterval($0 / 100 * 7 * 86400 + 0.5)) }
        #expect(hours == [0, 0, 1, 0, 0, 0, 0], "\(hours)")   // 2, 3, 4 Nov (begins 01:00), then midnight again on 5–8 Nov
    }
}

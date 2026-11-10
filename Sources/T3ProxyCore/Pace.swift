import Foundation

/// How one account's limit window is being spent compared with an even pace to its reset.
///
/// Even pace means using the window at a constant rate: halfway through the window, 50% used. Ahead of that is a
/// deficit (the window empties early at this rate), behind it is a reserve. The projection extends the account's
/// average rate over the elapsed part of the window, measured at the reading's own time so an older reading
/// doesn't distort the rate. Inspired by CodexBar's pace display (MIT); this is an independent implementation.
public struct QuotaPace: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case onPace
        /// Using faster than even pace by `slightly` (≤ 6 points), `clearly` (≤ 12) or `far` (more).
        case deficit(Grade)
        /// Using slower than even pace.
        case reserve(Grade)
    }
    public enum Grade: Int, Sendable, Comparable {
        case slightly, clearly, far
        public static func < (a: Grade, b: Grade) -> Bool { a.rawValue < b.rawValue }
    }

    /// Percentage of the window that would be used by now at an even pace.
    public let expectedUsed: Double
    /// Percentage actually used at the reading.
    public let used: Double
    /// `used - expectedUsed`: positive is a deficit, negative a reserve.
    public let delta: Double
    public let stage: Stage
    /// When the window empties at the current average rate, if before the reset.
    public let runsOutAt: Date?
    /// True when the current average rate lasts until the reset.
    public let lastsUntilReset: Bool
    public let resetAt: Date
    /// Local midnights inside the window, as percent of the window from its start (weekly bars draw them as ticks).
    public let dayMarks: [Double]

    /// Remaining percent an even pace would leave now: where the pace marker sits on a "% left" bar.
    public var expectedRemaining: Double { 100 - expectedUsed }

    /// Rounded points of deficit (positive) or reserve (negative); 0 means on pace.
    public var roundedDelta: Int { stage == .onPace ? 0 : Int(delta.rounded()) }

    static func stage(_ delta: Double) -> Stage {
        let size = abs(delta)
        if size <= 2 { return .onPace }
        let grade: Grade = size <= 6 ? .slightly : size <= 12 ? .clearly : .far
        return delta > 0 ? .deficit(grade) : .reserve(grade)
    }

    /// The pace of one window of a reading. Nil without a fresh reading, a future reset inside one window length,
    /// or enough of the window elapsed to judge (5-hour windows need 3% elapsed; a new window says nothing yet).
    public static func of(_ reading: QuotaReading, _ kind: QuotaWindowKind, now: Date,
                          calendar: Calendar = .current) -> QuotaPace? {
        guard let w = reading.window(kind) else { return nil }
        return of(AccountWindow(w), observedAt: reading.observedAt, now: now, calendar: calendar)
    }

    /// Pace for any measured window whose duration and current reset are known.
    public static func of(_ w: AccountWindow, observedAt: Date?, now: Date,
                          calendar: Calendar = .current) -> QuotaPace? {
        guard let duration = w.duration, let used = w.window.usedPercent, used.isFinite,
              let reset = w.window.resetAt, reset > now, let observedAt, observedAt <= now else { return nil }
        return compute(used: used, resetAt: reset, observedAt: observedAt, duration: duration,
                       now: now, calendar: calendar)
    }

    static func compute(used usedRaw: Double, resetAt reset: Date, observedAt observed: Date, duration: TimeInterval,
                        now: Date, calendar: Calendar) -> QuotaPace? {
        guard duration > 0 else { return nil }
        let start = reset.addingTimeInterval(-duration)
        // A reset further away than one window length means the window length is not what we assume.
        guard reset.timeIntervalSince(now) <= duration, observed >= start else { return nil }
        let used = min(100, max(0, usedRaw))
        let elapsedNow = min(duration, max(0, now.timeIntervalSince(start)))
        let expected = elapsedNow / duration * 100
        if duration <= 5 * 3600, expected < 3 || used >= 100 { return nil }
        let elapsedAtReading = observed.timeIntervalSince(start)
        guard elapsedAtReading > 0 else { return nil }

        // The average rate up to the reading, extended from the reading.
        var runsOut: Date?
        var lasts = false
        if used >= 100 {
            runsOut = observed
        } else if used <= 0 {
            lasts = true
        } else {
            let perSecond = used / elapsedAtReading
            let empty = observed.addingTimeInterval((100 - used) / perSecond)
            if empty >= reset { lasts = true } else { runsOut = max(now, empty) }
        }

        var marks: [Double] = []
        if duration >= 7 * 86400 {
            // Each day's own end, not "+1 day": after a DST change that skips midnight, adding days would keep
            // the shifted hour for every later tick.
            var cursor = start
            while let next = calendar.dateInterval(of: .day, for: cursor)?.end, next > cursor, next < reset {
                marks.append(next.timeIntervalSince(start) / duration * 100)
                cursor = next
            }
        }
        // Pace compares to now: usage can only have grown since the reading, so a stale reading understates it.
        let delta = used - expected
        return QuotaPace(expectedUsed: expected, used: used, delta: delta, stage: stage(delta), runsOutAt: runsOut,
                         lastsUntilReset: lasts, resetAt: reset, dayMarks: marks)
    }

    /// "54% in deficit", "12% in reserve" or "On pace".
    public var summary: String {
        switch stage {
        case .onPace: "On pace"
        case .deficit: "\(abs(roundedDelta))% in deficit"
        case .reserve: "\(abs(roundedDelta))% in reserve"
        }
    }

    /// "Runs out in 5h 34m", "Runs out now" or "Lasts until reset".
    public func projection(now: Date) -> String? {
        if lastsUntilReset { return "Lasts until reset" }
        guard let at = runsOutAt else { return nil }
        return at.timeIntervalSince(now) < 60 ? "Runs out now" : "Runs out in \(shortDuration(until: at, from: now))"
    }
}

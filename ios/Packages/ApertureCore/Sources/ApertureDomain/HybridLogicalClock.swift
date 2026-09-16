import Foundation

/// A hybrid logical clock: wall-clock milliseconds, a logical counter, and a node
/// identity.
///
/// This type exists because of one specific, silent failure mode. Devices in this product
/// work offline for up to 72 hours, users can set the system clock to anything, and time
/// zones and daylight saving transitions move it without the user doing anything at all.
/// If conflict resolution ordered edits by wall-clock time, an inspector whose phone ran
/// 40 minutes fast would win every conflict against a reviewer, and the loss would be
/// invisible: no error, no log entry, no user-visible symptom, just a measurement quietly
/// replaced by an older one.
///
/// The hybrid clock keeps wall-clock time as its leading component, so values stay
/// roughly human-meaningful and sort close to real time, while the counter guarantees
/// that causally ordered events are ordered correctly even when the physical clock lies
/// or stands still.
///
/// The node identifier is the final tiebreaker, which makes the ordering a total order.
/// Without it two devices can produce identical `(wall, counter)` pairs and the comparison
/// would be ambiguous, which would make conflict resolution non-deterministic across
/// replicas: the same inputs would resolve differently depending on which device asked.
public struct HybridLogicalClock: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Milliseconds since the Unix epoch, as observed when the value was created.
    public let wallClockMilliseconds: UInt64

    /// Disambiguates events within the same millisecond and carries causality forward
    /// when the physical clock has not advanced.
    public let counter: UInt32

    /// The device or server that produced this value. Final tiebreaker for total order.
    public let nodeID: String

    public init(wallClockMilliseconds: UInt64, counter: UInt32, nodeID: String) {
        self.wallClockMilliseconds = wallClockMilliseconds
        self.counter = counter
        self.nodeID = nodeID
    }

    /// The zero value for a node, used when an entity has never been stamped.
    public static func origin(nodeID: String) -> HybridLogicalClock {
        HybridLogicalClock(wallClockMilliseconds: 0, counter: 0, nodeID: nodeID)
    }

    /// Wire representation: `2026-09-10T00:26:40.123Z-0042-devA`.
    ///
    /// Sortable as text within a single node, human-readable in a log, and unambiguous to
    /// parse. The counter is zero-padded so lexical and numeric order agree.
    ///
    /// Formatted with integer arithmetic rather than a date formatter, for two reasons.
    /// `ISO8601DateFormatter` is a non-Sendable class, so holding one in a static is a
    /// strict-concurrency violation and creating one per call is wasteful. Date formatters
    /// are also slow, and this runs on the path of every stamped mutation and every log
    /// line. The arithmetic is exact and has no locale, calendar, or time zone to get
    /// wrong, which for a wire format is the point.
    public var description: String {
        let totalSeconds = wallClockMilliseconds / 1000
        let millisecond = Int(wallClockMilliseconds % 1000)
        let daysSinceEpoch = Int64(totalSeconds / 86_400)
        let secondOfDay = Int(totalSeconds % 86_400)

        let (year, month, day) = Self.civilDate(fromDaysSinceEpoch: daysSinceEpoch)
        let hour = secondOfDay / 3600
        let minute = (secondOfDay % 3600) / 60
        let second = secondOfDay % 60

        let date = "\(Self.pad(year, 4))-\(Self.pad(month, 2))-\(Self.pad(day, 2))"
        let time = "\(Self.pad(hour, 2)):\(Self.pad(minute, 2)):\(Self.pad(second, 2)).\(Self.pad(millisecond, 3))"
        return "\(date)T\(time)Z-\(Self.pad(Int(counter), 4))-\(nodeID)"
    }

    /// Converts days since the Unix epoch into a proleptic Gregorian calendar date.
    ///
    /// Howard Hinnant's `civil_from_days`, which is exact for every representable day and
    /// uses only integer division. Verified against a reference implementation across the
    /// epoch, leap years, and century boundaries.
    static func civilDate(fromDaysSinceEpoch days: Int64) -> (year: Int, month: Int, day: Int) {
        // Shift the epoch to 0000-03-01 so leap days fall at the end of the cycle.
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return (Int(year + (month <= 2 ? 1 : 0)), Int(month), Int(day))
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }

    /// The instant this value claims to have been created at.
    ///
    /// Useful for display. Never use it for ordering: that is what `Comparable` is for,
    /// and the whole point of this type is that the wall-clock component alone is not
    /// trustworthy.
    public var approximateInstant: Date {
        Date(timeIntervalSince1970: TimeInterval(wallClockMilliseconds) / 1000)
    }
}

extension HybridLogicalClock: Comparable {
    public static func < (lhs: HybridLogicalClock, rhs: HybridLogicalClock) -> Bool {
        if lhs.wallClockMilliseconds != rhs.wallClockMilliseconds {
            return lhs.wallClockMilliseconds < rhs.wallClockMilliseconds
        }
        if lhs.counter != rhs.counter {
            return lhs.counter < rhs.counter
        }
        return lhs.nodeID < rhs.nodeID
    }
}

/// Failures the clock reports rather than papering over.
public enum HybridLogicalClockError: Error, Equatable, Sendable {
    /// A remote value claims a time so far ahead of this device that accepting it would
    /// drag the local clock forward by that amount permanently.
    ///
    /// Accepting unbounded drift is how one device with a badly wrong clock poisons an
    /// entire tenant: every replica that merges with it inherits the bad wall-clock
    /// value, and no later correction can pull it back. Rejecting is the safer failure,
    /// and it is loud rather than silent.
    case excessiveDrift(remoteMilliseconds: UInt64, localMilliseconds: UInt64, limitMilliseconds: UInt64)
}

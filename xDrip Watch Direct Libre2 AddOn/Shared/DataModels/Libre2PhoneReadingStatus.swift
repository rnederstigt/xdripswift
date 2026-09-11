import Foundation

/// A received BLE reading and permission to transfer are separate observations.
/// This is an in-memory snapshot for the current phone connection, never a cached database reading.
struct Libre2PhoneReadingStatus {
    private(set) var lastReadingAt: Date?
    private(set) var verifiedUnlockCode: UInt32?

    mutating func receivedBLEReading(at date: Date, verifiedUnlockCode: UInt32?) {
        guard lastReadingAt.map({ date >= $0 }) ?? true else { return }
        lastReadingAt = date
        self.verifiedUnlockCode = verifiedUnlockCode
    }

    func hasRecentReading(at now: Date = Date()) -> Bool {
        guard let lastReadingAt else { return false }
        let age = now.timeIntervalSince(lastReadingAt)
        return age >= 0 && age < ConstantsLibre2.recentReadingInterval
    }

    func hasRecentVerifiedReading(at now: Date = Date()) -> Bool {
        verifiedUnlockCode != nil && hasRecentReading(at: now)
    }

    /// The checklist shows an absolute timestamp, so only a freshness boundary needs a timer.
    func nextFreshnessChange(at now: Date = Date()) -> Date? {
        guard let lastReadingAt, lastReadingAt.timeIntervalSince1970.isFinite else { return nil }
        if lastReadingAt > now { return lastReadingAt }
        let expiry = lastReadingAt.addingTimeInterval(ConstantsLibre2.recentReadingInterval)
        return expiry > now ? expiry : nil
    }
}

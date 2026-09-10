import Foundation

/// Display-ready values. Both relayed and direct readings pass the same validation.
struct Libre2ReadingBatch {
    let values: [Double]
    let dates: [Double]
    let slope: Int
    let delta: Double
    let generatedAt: Date

    func isAcceptable(after previousDate: Date?, now: Date = Date()) -> Bool {
        guard values.count == dates.count,
              let latest = dates.first,
              !values.isEmpty,
              values.allSatisfy({ $0.isFinite && $0 > 0 }),
              dates.allSatisfy({ $0.isFinite }),
              latest > now.addingTimeInterval(-3600).timeIntervalSince1970,
              latest <= now.addingTimeInterval(30).timeIntervalSince1970,
              latest >= (previousDate?.timeIntervalSince1970 ?? 0) else {
            return false
        }
        return true
    }
}

enum Libre2ReadingPipeline {
    /// The new BLE frame replaces its overlapping interval; retain only older chart history.
    static func merging(_ samples: [Libre2Sample], with previous: [Libre2Sample], now: Date = Date()) -> [Libre2Sample] {
        let oldestFrameDate = samples.last?.timeStamp ?? now
        let olderHistory = previous.filter { sample in
            sample.timeStamp < oldestFrameDate && sample.timeStamp > now.addingTimeInterval(-12 * 3600)
        }
        return (samples + olderHistory).sorted { $0.timeStamp > $1.timeStamp }
    }

    static func trend(from samples: [Libre2Sample]) -> (delta: Double, slopeOrdinal: Int) {
        let delta = samples.count > 1 ? samples[0].glucoseLevelRaw - samples[1].glucoseLevelRaw : 0
        let minutes = samples.count > 1 ? max(samples[0].timeStamp.timeIntervalSince(samples[1].timeStamp) / 60, 1) : 1
        let rate = delta / minutes
        let slope: Int

        if rate > 3 {
            slope = 1
        } else if rate > 2 {
            slope = 2
        } else if rate > 1 {
            slope = 3
        } else if rate < -3 {
            slope = 7
        } else if rate < -2 {
            slope = 6
        } else if rate < -1 {
            slope = 5
        } else {
            slope = 4
        }
        return (delta, slope)
    }
}

import Foundation

/// Display-ready direct readings. Phone relay retains its upstream validation in the host.
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

    /// Match Calibrator.findSlope, BgReading.slopeOrdinal and WatchManager.currentBgReadings.
    static func trend(from samples: [Libre2Sample], isMgDl: Bool = true) -> (delta: Double, slopeOrdinal: Int) {
        guard samples.count > 1 else { return (0, 0) }
        let latest = samples[0]
        let previous = samples[1]
        var actualValueInUserUnit = latest.glucoseLevelRaw
        var previousValueInUserUnit = previous.glucoseLevelRaw
        if !isMgDl {
            actualValueInUserUnit = (actualValueInUserUnit * ConstantsLibre2.mgDlToMmoll * 10).rounded() / 10
            previousValueInUserUnit = (previousValueInUserUnit * ConstantsLibre2.mgDlToMmoll * 10).rounded() / 10
        }
        let delta = actualValueInUserUnit - previousValueInUserUnit

        // The phone hides the arrow for equal timestamps or a gap over 21 minutes.
        let milliseconds = latest.timeStamp.timeIntervalSince1970 * 1000 - previous.timeStamp.timeIntervalSince1970 * 1000
        guard milliseconds != 0, milliseconds <= Double(ConstantsLibre2.maxSlopeInMinutes * 60 * 1000) else {
            return (delta, 0)
        }
        let rate = (latest.glucoseLevelRaw - previous.glucoseLevelRaw) / milliseconds * 60000
        let slope: Int

        if rate <= -3.5 {
            slope = 7
        } else if rate <= -2 {
            slope = 6
        } else if rate <= -1 {
            slope = 5
        } else if rate <= 1 {
            slope = 4
        } else if rate <= 2 {
            slope = 3
        } else if rate <= 3.5 {
            slope = 2
        } else {
            slope = 1
        }
        return (delta, slope)
    }
}

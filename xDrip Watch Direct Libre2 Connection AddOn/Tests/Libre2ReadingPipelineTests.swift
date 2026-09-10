import XCTest

@testable import Libre2ExperimentCore

final class Libre2ReadingPipelineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ secondsAgo: TimeInterval, _ glucose: Double) -> Libre2Sample {
        Libre2Sample(timeStamp: now.addingTimeInterval(-secondsAgo), glucoseLevelRaw: glucose)
    }

    func testNewFrameReplacesOverlapAndKeepsOnlyOlderRecentHistory() {
        let previous = [sample(0, 90), sample(60, 91), sample(120, 92), sample(180, 93), sample(13 * 3600, 94)]
        let frame = [sample(0, 110), sample(60, 109), sample(120, 108)]
        let result = Libre2ReadingPipeline.merging(frame, with: previous, now: now)
        XCTAssertEqual(result, frame + [sample(180, 93)])
    }

    func testBothReadingSourcesRejectMalformedOrOlderUpdates() {
        let valid = Libre2ReadingBatch(values: [110], dates: [now.timeIntervalSince1970], slope: 4, delta: 0, generatedAt: now)
        XCTAssertTrue(valid.isAcceptable(after: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(valid.isAcceptable(after: now, now: now))
        XCTAssertFalse(valid.isAcceptable(after: now.addingTimeInterval(1), now: now))
        for values in [[], [110, 111], [Double.nan], [Double.infinity], [0], [-1]] {
            let malformed = Libre2ReadingBatch(values: values, dates: valid.dates, slope: 4, delta: 0, generatedAt: now)
            XCTAssertFalse(malformed.isAcceptable(after: nil, now: now))
        }
    }

    func testReadingFreshnessAndFutureTimestampBoundsRemainUnchanged() {
        for (age, accepted) in [(3599.0, true), (3600, false), (-30, true), (-31, false)] {
            let batch = Libre2ReadingBatch(values: [110], dates: [now.addingTimeInterval(-age).timeIntervalSince1970], slope: 4, delta: 0, generatedAt: now)
            XCTAssertEqual(batch.isAcceptable(after: nil, now: now), accepted)
        }
        let invalidDate = Libre2ReadingBatch(values: [110], dates: [.nan], slope: 4, delta: 0, generatedAt: now)
        XCTAssertFalse(invalidDate.isAcceptable(after: nil, now: now))
    }

    func testTrendUsesElapsedMinutesAndHandlesMissingHistory() {
        let rising = Libre2ReadingPipeline.trend(from: [sample(0, 115), sample(120, 110)])
        XCTAssertEqual(rising.delta, 5)
        XCTAssertEqual(rising.slopeOrdinal, 2)
        let flat = Libre2ReadingPipeline.trend(from: [sample(0, 115)])
        XCTAssertEqual(flat.delta, 0)
        XCTAssertEqual(flat.slopeOrdinal, 4)
    }
}

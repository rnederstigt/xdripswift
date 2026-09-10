import Foundation

/// Portable coefficients for the existing native Libre glucose conversion.
struct Libre2Calibration: Codable, Equatable {
    let slopeSlope: Double
    let offsetSlope: Double
    let slopeOffset: Double
    let offsetOffset: Double
    let extraSlope: Double
    let extraOffset: Double

    var isValid: Bool {
        [slopeSlope, offsetSlope, slopeOffset, offsetOffset, extraSlope, extraOffset].allSatisfy { $0.isFinite } && extraSlope > 0
    }

    func glucose(raw: Int, temperature: Int) -> Double {
        let slope = slopeSlope * Double(temperature) + offsetSlope
        let temperatureOffset = slopeOffset * Double(temperature)
        let glucoseBeforeCorrection = slope * Double(raw) + temperatureOffset + offsetOffset
        return glucoseBeforeCorrection * extraSlope + extraOffset
    }
}

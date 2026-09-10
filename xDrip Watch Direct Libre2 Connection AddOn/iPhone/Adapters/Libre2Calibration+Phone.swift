import Foundation

extension Libre2Calibration {
    init(_ parameters: Libre1DerivedAlgorithmParameters) {
        self.init(slopeSlope: parameters.slope_slope, offsetSlope: parameters.offset_slope,
                  slopeOffset: parameters.slope_offset, offsetOffset: parameters.offset_offset,
                  extraSlope: parameters.extraSlope, extraOffset: parameters.extraOffset)
    }
}

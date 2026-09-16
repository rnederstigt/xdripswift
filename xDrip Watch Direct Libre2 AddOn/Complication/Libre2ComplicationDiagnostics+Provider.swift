import Foundation

extension XDripWatchComplication.Provider {
    /// Records the entry handed to WidgetKit, not proof of what watchOS rendered onscreen.
    func recordLibreDiagnostics(_ event: String, entry: Entry, isPreview: Bool) {
        let state = entry.widgetState
        Libre2ComplicationDiagnostics.shared.record(event,
            value: state.bgValueInMgDl, sampleDate: state.bgReadingDate,
            displayValue: state.bgValueStringInUserChosenUnit(),
            details: "preview=\(isPreview) units=\(state.isMgDl ? "mg/dL" : "mmol/L") disabled=\(state.keepAliveIsDisabled)")
    }
}

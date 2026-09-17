import SwiftUI

/// Direct mode shows the Bluetooth link; the reading-age text shows freshness.
struct Libre2SourceStatusView: View {
    @EnvironmentObject var watchState: WatchStateModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var connectionColor: Color {
        let state = watchState.directLibre.connectionState
        if state == .connected { return .green }
        return state.isConnecting ? .orange : .gray
    }

    private var shouldBlink: Bool {
        let state = watchState.directLibre.connectionState
        return (state == .scanning || state == .restarting)
            && scenePhase == .active && !isLuminanceReduced && !reduceMotion
    }

    var body: some View {
        if watchState.directLibre.isDirect {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundColor(connectionColor)
                .symbolEffect(.pulse.wholeSymbol, options: .repeating, isActive: shouldBlink)
                .accessibilityLabel(watchState.directLibre.indicatorText)
                .padding(.trailing, 2)
        } else {
            Image(systemName: ConstantsAppleWatch.requestingDataIconSFSymbolName)
                .font(.system(size: ConstantsAppleWatch.requestingDataIconFontSize, weight: .heavy))
                .foregroundStyle(watchState.requestingDataIconColor)
                .padding(.top, 4)
                .padding(.trailing, 2)
        }
    }
}

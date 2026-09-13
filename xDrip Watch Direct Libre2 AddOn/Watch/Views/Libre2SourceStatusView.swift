import SwiftUI

/// Direct mode shows the Bluetooth link; the reading-age text shows freshness.
struct Libre2SourceStatusView: View {
    @EnvironmentObject var watchState: WatchStateModel

    var body: some View {
        if watchState.directLibre.isDirect {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundColor(watchState.directLibre.isConnected ? .green : .gray)
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

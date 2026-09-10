import SwiftUI

/// Reading-age marker shared by the large-value, chart and AGP pages.
struct Libre2SourceStatusView: View {
    @EnvironmentObject var watchState: WatchStateModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            if watchState.directLibre.isDirect {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(watchState.directLibre.isReceiving ? .green : .gray)
                    .accessibilityLabel(watchState.directLibre.indicatorText)
            } else {
                Image(systemName: ConstantsAppleWatch.requestingDataIconSFSymbolName)
                    .font(.system(size: ConstantsAppleWatch.requestingDataIconFontSize, weight: .heavy))
                    .foregroundStyle(watchState.requestingDataIconColor)
                    .padding(.top, 4)
            }
        }
        .padding(.trailing, 2)
    }
}

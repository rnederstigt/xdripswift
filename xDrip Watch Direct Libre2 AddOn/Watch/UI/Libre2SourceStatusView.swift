import SwiftUI

/// Reading-age marker shared by the large-value, chart and AGP pages.
struct Libre2SourceStatusView: View {
    @EnvironmentObject var watchState: WatchStateModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReceiving = false

    var body: some View {
        Group {
            if watchState.directLibre.isDirect {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(isReceiving ? .green : .gray)
                    .accessibilityLabel(watchState.directLibre.indicatorText)
            } else {
                Image(systemName: ConstantsAppleWatch.requestingDataIconSFSymbolName)
                    .font(.system(size: ConstantsAppleWatch.requestingDataIconFontSize, weight: .heavy))
                    .foregroundStyle(watchState.requestingDataIconColor)
                    .padding(.top, 4)
            }
        }
        .padding(.trailing, 2)
        .onAppear { refreshIndicator() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshIndicator() }
        }
        .onChange(of: watchState.directLibre.isReceiving) { _, _ in refreshIndicator() }
        .onReceive(watchState.timer) { _ in
            // Reuse the upstream display clock; only a freshness transition changes this view's state.
            guard scenePhase == .active, watchState.directLibre.isDirect else { return }
            refreshIndicator()
        }
    }

    private func refreshIndicator() {
        let receiving = watchState.directLibre.isReceiving
        if isReceiving != receiving { isReceiving = receiving }
    }
}

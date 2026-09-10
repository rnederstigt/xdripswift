import SwiftUI

/// The ordinary marker has no experimental timer or lifecycle subscriptions.
struct Libre2SourceStatusView: View {
    @EnvironmentObject var watchState: WatchStateModel

    var body: some View {
        if watchState.directLibre.isDirect {
            Libre2DirectSourceStatusView()
        } else {
            Image(systemName: ConstantsAppleWatch.requestingDataIconSFSymbolName)
                .font(.system(size: ConstantsAppleWatch.requestingDataIconFontSize, weight: .heavy))
                .foregroundStyle(watchState.requestingDataIconColor)
                .padding(.top, 4)
                .padding(.trailing, 2)
        }
    }
}

/// Only direct mode subscribes to the host's existing display clock.
private struct Libre2DirectSourceStatusView: View {
    @EnvironmentObject var watchState: WatchStateModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReceiving = false

    var body: some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .foregroundColor(isReceiving ? .green : .gray)
            .accessibilityLabel(watchState.directLibre.indicatorText)
            .padding(.trailing, 2)
            .onAppear { refreshIndicator() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshIndicator() }
            }
            .onChange(of: watchState.directLibre.isReceiving) { _, _ in refreshIndicator() }
            .onReceive(watchState.timer) { _ in
                guard scenePhase == .active else { return }
                refreshIndicator()
            }
    }

    private func refreshIndicator() {
        let receiving = watchState.directLibre.isReceiving
        if isReceiving != receiving { isReceiving = receiving }
    }
}

import SwiftUI
import WatchConnectivity

/// Reads the Watch's persisted preference on entry/reachability changes, without polling.
struct Libre2LocationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var handoff = Libre2PhoneHandoff.shared
    @State private var enabled: Bool?
    @State private var accuracy: Libre2LocationRequest.Accuracy?
    @State private var status = ""
    @State private var isBusy = false
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(Texts_DirectLibre.locationTitle, isOn: Binding(
                get: { enabled ?? false },
                set: { request(.setEnabled($0)) }))
                .disabled(enabled == nil || isBusy || !handoff.reachable)
            Text(Texts_DirectLibre.locationHelp).font(.caption).foregroundColor(.secondary)
            if let accuracy {
                Text(Texts_DirectLibre.locationAccuracyTitle).font(.subheadline)
                Picker(Texts_DirectLibre.locationAccuracyTitle, selection: Binding(
                    get: { self.accuracy ?? accuracy },
                    set: { if $0 != self.accuracy { request(.setAccuracy($0)) } })) {
                    ForEach(Libre2LocationRequest.Accuracy.allCases, id: \.self) { option in
                        Text(Texts_DirectLibre.locationAccuracyLabel(option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(enabled == nil || isBusy || !handoff.reachable)
                Text(Texts_DirectLibre.locationAccuracyHelp).font(.caption).foregroundColor(.secondary)
            } else if enabled != nil {
                Text(Texts_DirectLibre.locationAccuracyNeedsUpdate).font(.caption).foregroundColor(.secondary)
            }
            if isBusy { ProgressView() }
            Text(handoff.reachable ? status : Texts_DirectLibre.locationNeedsWatch)
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear {
            isVisible = true
            request(.inspect)
        }
        .onDisappear { isVisible = false }
        .onChange(of: handoff.reachable) { reachable in
            if reachable { request(.inspect) }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { request(.inspect) }
        }
    }

    private func request(_ request: Libre2LocationRequest) {
        guard isVisible, scenePhase == .active, !isBusy, handoff.reachable else { return }
        do {
            let message = try request.dictionary
            isBusy = true
            WCSession.default.sendMessage(message, replyHandler: { reply in
                DispatchQueue.main.async {
                    isBusy = false
                    guard let value = reply["enabled"] as? Bool, let detail = reply["status"] as? String else {
                        enabled = nil
                        status = Texts_DirectLibre.locationUnconfirmed
                        return
                    }
                    enabled = value
                    accuracy = (reply["accuracy"] as? Int).flatMap(Libre2LocationRequest.Accuracy.init(rawValue:))
                    status = Texts_DirectLibre.locationLastStatus(detail)
                }
            }, errorHandler: { _ in
                DispatchQueue.main.async {
                    isBusy = false
                    // A lost reply cannot establish whether the Watch applied the preference.
                    enabled = nil
                    status = Texts_DirectLibre.locationUnconfirmed
                }
            })
        } catch { status = Texts_DirectLibre.locationUnconfirmed }
    }
}

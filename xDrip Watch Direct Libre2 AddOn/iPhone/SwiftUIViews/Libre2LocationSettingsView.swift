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
    @State private var showsHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Texts_DirectLibre.backgroundSection).font(.headline)
                Spacer()
                Button { showsHelp = true } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(Texts_DirectLibre.backgroundHelpTitle)
            }
            Toggle(Texts_DirectLibre.backgroundEnabled, isOn: Binding(
                get: { enabled ?? false },
                set: { request(.setEnabled($0)) }))
                .disabled(enabled == nil || isBusy || !handoff.reachable)
            if enabled == true, let accuracy {
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
            } else if enabled == true {
                Text(Texts_DirectLibre.locationAccuracyNeedsUpdate).font(.caption).foregroundColor(.secondary)
            }
            if isBusy { ProgressView() }
            Text(handoff.reachable ? status : Texts_DirectLibre.locationNeedsWatch)
                .font(.caption).foregroundColor(.secondary)
            Libre2NotificationTestButton()
        }
        .alert(Texts_DirectLibre.backgroundHelpTitle, isPresented: $showsHelp) {
            Button(Texts_Common.Ok, role: .cancel) {}
        } message: {
            Text(Texts_DirectLibre.locationHelp + "\n\n" + Texts_DirectLibre.locationAccuracyHelp)
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

/// A manual diagnostic only. No queued requests, polling or automatic resends.
private struct Libre2NotificationTestButton: View {
    @ObservedObject private var handoff = Libre2PhoneHandoff.shared
    @State private var isScheduling = false
    @State private var status = ""
    @State private var showsHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(Texts_DirectLibre.notificationTestButton) { schedule() }
                    .disabled(isScheduling || !handoff.reachable)
                if isScheduling { ProgressView() }
                Spacer()
                Button { showsHelp = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel(Texts_DirectLibre.notificationTestButton)
            }
            Text(handoff.reachable ? Texts_DirectLibre.notificationTestShortHelp : Texts_DirectLibre.notificationTestNeedsWatch)
                .font(.caption2).foregroundColor(.secondary)
            if !status.isEmpty {
                Text(status).font(.caption2).foregroundColor(.secondary)
            }
        }
        .font(.caption)
        .alert(Texts_DirectLibre.notificationTestButton, isPresented: $showsHelp) {
            Button(Texts_Common.Ok, role: .cancel) {}
        } message: {
            Text(Texts_DirectLibre.notificationTestHelp)
        }
    }

    private func schedule() {
        let session = WCSession.default
        guard !isScheduling, session.activationState == .activated, session.isReachable else {
            status = Texts_DirectLibre.notificationTestNeedsWatch
            return
        }
        isScheduling = true
        status = ""
        session.sendMessage([Libre2NotificationTest.requestKey: true], replyHandler: { reply in
            DispatchQueue.main.async {
                isScheduling = false
                if let error = reply["error"] as? String {
                    status = error
                } else if let timestamp = reply[Libre2NotificationTest.scheduledAtKey] as? Double,
                    timestamp.isFinite, timestamp > 0 {
                    status = Texts_DirectLibre.notificationTestScheduled(Date(timeIntervalSince1970: timestamp))
                    Libre2ActivityLog.shared.record(status)
                } else {
                    status = Texts_DirectLibre.notificationTestUnconfirmed
                }
            }
        }, errorHandler: { _ in
            DispatchQueue.main.async {
                isScheduling = false
                // A lost acknowledgement does not prove that scheduling failed.
                status = Texts_DirectLibre.notificationTestUnconfirmed
            }
        })
    }
}

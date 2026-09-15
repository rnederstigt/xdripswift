import SwiftUI
import WatchConnectivity

/// Uses the existing Settings router so the experiment is reachable from Advanced Settings.
struct Libre2PhoneSettingsLink: View {
    @Environment(\.settingsNavigationActions) private var navigationActions

    var body: some View {
        Button {
            navigationActions?.push(Texts_DirectLibre.experimentTitle) { _ in
                AnyView(Libre2PhoneExperimentView())
            }
        } label: {
            HStack {
                Label(Texts_DirectLibre.experimentTitle, systemImage: "applewatch")
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.secondary)
            }
        }
    }
}

struct Libre2PhoneExperimentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var isManagingHistory = false
    @State private var historyStatus = ""
    @State private var unresolvedReadings: Libre2UnresolvedReadings?
    @ObservedObject private var handoff = Libre2PhoneHandoff.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(handoff.owner.displayTitle).font(.headline)
                if !handoff.status.isEmpty && handoff.status != handoff.owner.displayTitle {
                    Text(handoff.status).font(.callout)
                }
                controls
                Divider()
                Libre2ChecklistView(groups: handoff.checklistGroups)
                Divider()
                Libre2LocationSettingsView()
                Divider()
                historyCleanup
                Divider()
                Libre2ActivityLogView()
            }
            .padding()
        }
        .onAppear {
            isVisible = true
            handoff.isPageVisible = scenePhase == .active
            handoff.recordReachability()
            handoff.refreshChecklistSettings()
            handoff.refreshChecklist()
        }
        .onDisappear {
            isVisible = false
            handoff.isPageVisible = false
        }
        .onChange(of: scenePhase) { phase in
            handoff.isPageVisible = isVisible && phase == .active
            if isVisible && phase == .active {
                handoff.recordReachability()
                handoff.refreshChecklistSettings()
                handoff.refreshChecklist()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .receive(on: RunLoop.main)) { _ in
            guard scenePhase == .active else { return }
            handoff.refreshChecklistSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: Libre2SessionStore.didChange, object: Libre2SessionStore.shared)
            .receive(on: RunLoop.main)) { _ in
            guard scenePhase == .active else { return }
            handoff.refreshChecklist()
        }
        .task(id: freshnessDeadline) {
            guard let deadline = freshnessDeadline else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                try Task.checkCancellation()
                handoff.refreshChecklist()
            } catch {
                // A new reading, leaving the page or backgrounding cancels this deadline.
            }
        }
        .navigationTitle(Texts_DirectLibre.experimentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $unresolvedReadings) { readings in
            Alert(title: Text(Texts_DirectLibre.deleteUnresolvedReadings),
                  message: Text(Texts_DirectLibre.confirmDeleteUnresolved(readings.count)),
                  primaryButton: .destructive(Text(Texts_Common.delete)) {
                      requestHistoryCleanup(.delete(readings))
                  },
                  secondaryButton: .cancel())
        }
    }

    private var freshnessDeadline: Date? {
        guard scenePhase == .active, handoff.owner.allowsPhoneConnection else { return nil }
        return handoff.readingStatus.nextFreshnessChange()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: handoff.switchDevice) {
                Label(handoff.switchButtonTitle, systemImage: handoff.switchButtonSymbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!handoff.canSwitchDevice)
            Text(Texts_DirectLibre.ordinaryScanRecovery).font(.caption).foregroundColor(.secondary)
        }
    }

    private var historyCleanup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { requestHistoryCleanup(.inspect) } label: {
                Label(Texts_DirectLibre.deleteUnresolvedReadings, systemImage: "trash")
            }
            .disabled(isManagingHistory || !handoff.reachable)
            if isManagingHistory { ProgressView() }
            Text(handoff.reachable ? historyStatus : Texts_DirectLibre.historyCleanupNeedsWatch)
                .font(.caption).foregroundColor(.secondary)
        }
    }

    /// Read the count only on tap. Never queue or automatically retry a destructive request.
    private func requestHistoryCleanup(_ request: Libre2HistoryCleanupRequest) {
        guard !isManagingHistory else { return }
        guard handoff.reachable else {
            historyStatus = Texts_DirectLibre.historyCleanupNeedsWatch
            return
        }
        do {
            let message = try request.dictionary
            isManagingHistory = true
            historyStatus = ""
            WCSession.default.sendMessage(message, replyHandler: { reply in
                DispatchQueue.main.async {
                    isManagingHistory = false
                    do {
                        if let error = reply["error"] as? String {
                            historyStatus = error
                            return
                        }
                        let readings = try Libre2UnresolvedReadings.decode(reply)
                        switch request {
                        case .inspect:
                            if readings.count > 0 { unresolvedReadings = readings }
                            else { historyStatus = Texts_DirectLibre.noUnresolvedReadings }
                        case .delete(let confirmed):
                            historyStatus = Texts_DirectLibre.deletedUnresolved(confirmed.count)
                            Libre2ActivityLog.shared.record(historyStatus)
                        }
                    } catch { historyStatus = error.localizedDescription }
                }
            }, errorHandler: { _ in
                DispatchQueue.main.async {
                    isManagingHistory = false
                    // A missing reply does not tell us whether the Watch saved the deletion.
                    historyStatus = Texts_DirectLibre.historyCleanupNoReply
                }
            })
        } catch { historyStatus = error.localizedDescription }
    }
}

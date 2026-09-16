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
    @Environment(\.settingsNavigationActions) private var navigationActions
    @State private var isVisible = false
    @State private var pageID = UUID()
    @ObservedObject private var handoff = Libre2PhoneHandoff.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox { collectionSummary }
                GroupBox { Libre2LocationSettingsView() }
                GroupBox { Libre2ChecklistView(groups: handoff.checklistGroups) }
                GroupBox { Libre2RecentActivityView() }
                Button {
                    navigationActions?.push(Texts_DirectLibre.diagnosticsRecovery) { _ in
                        AnyView(Libre2DiagnosticsView())
                    }
                } label: {
                    HStack {
                        Label(Texts_DirectLibre.diagnosticsRecovery, systemImage: "wrench.and.screwdriver")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                }
            }
            .padding()
        }
        .onAppear {
            isVisible = true
            Libre2SettingsVisibility.update(pageID, active: scenePhase == .active)
            handoff.recordReachability()
            handoff.refreshChecklistSettings()
            handoff.refreshChecklist()
        }
        .onDisappear {
            isVisible = false
            Libre2SettingsVisibility.update(pageID, active: false)
        }
        .onChange(of: scenePhase) { phase in
            Libre2SettingsVisibility.update(pageID, active: isVisible && phase == .active)
            if isVisible && phase == .active {
                handoff.recordReachability()
                handoff.refreshChecklistSettings()
                handoff.refreshChecklist()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .receive(on: RunLoop.main)) { _ in
            guard isVisible, scenePhase == .active else { return }
            handoff.refreshChecklistSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: Libre2SessionStore.didChange, object: Libre2SessionStore.shared)
            .receive(on: RunLoop.main)) { _ in
            guard isVisible, scenePhase == .active else { return }
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
    }

    private var freshnessDeadline: Date? {
        guard isVisible, scenePhase == .active, handoff.owner.allowsPhoneConnection else { return nil }
        return handoff.readingStatus.nextFreshnessChange()
    }

    private var collectionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(handoff.owner.displayTitle).font(.title3).fontWeight(.semibold)
            if handoff.owner == .phone {
                Label(handoff.sensor?.isConnected == true ? Texts_DirectLibre.phoneConnected : Texts_DirectLibre.phoneWaiting,
                      systemImage: handoff.sensor?.isConnected == true ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                if let date = handoff.readingStatus.lastReadingAt {
                    Text(Texts_DirectLibre.phoneLatestReading(date)).font(.caption).foregroundColor(.secondary)
                }
            } else if handoff.owner == .watch {
                Label(handoff.reachable ? Texts_DirectLibre.watchReachable : Texts_DirectLibre.watchUnreachableLog,
                      systemImage: handoff.reachable ? "applewatch.radiowaves.left.and.right" : "applewatch")
                    .font(.subheadline)
                Text(Texts_DirectLibre.watchSensorStatusHelp).font(.caption).foregroundColor(.secondary)
                Libre2LatestPhoneReadingView()
            }
            if !handoff.status.isEmpty && handoff.status != handoff.owner.displayTitle {
                Text(handoff.status).font(.callout)
            }
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: handoff.switchDevice) {
                Label(handoff.switchButtonTitle, systemImage: handoff.switchButtonSymbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!handoff.canSwitchDevice)
        }
    }

}

/// Uses the phone's existing widget snapshot; never requests a reading from the Watch.
private struct Libre2LatestPhoneReadingView: View {
    @AppStorage(WidgetSharedUserDefaultsModel.widgetDataKey(for: Bundle.main.mainAppBundleIdentifier),
                store: UserDefaults(suiteName: Bundle.main.appGroupSuiteName)) private var widgetData: Data?

    private var date: Date? {
        guard let widgetData,
            let snapshot = try? JSONDecoder().decode(WidgetSharedUserDefaultsModel.self, from: widgetData),
            let timestamp = snapshot.bgReadingDatesAsDouble.filter({ $0.isFinite && $0 > 0 }).max()
        else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    var body: some View {
        Text(date.map(Texts_DirectLibre.phoneLatestReading) ?? Texts_DirectLibre.phoneLatestUnavailable)
            .font(.caption).foregroundColor(.secondary)
    }
}

/// Occasional tools remain within Advanced Settings, away from the collection controls.
struct Libre2DiagnosticsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var handoff = Libre2PhoneHandoff.shared
    @State private var isVisible = false
    @State private var pageID = UUID()
    @State private var isManagingHistory = false
    @State private var historyStatus = ""
    @State private var unresolvedReadings: Libre2UnresolvedReadings?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox { Libre2ActivityLogView() }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(Texts_DirectLibre.recoveryTitle).font(.headline)
                        Text(Texts_DirectLibre.ordinaryScanRecovery).font(.caption).foregroundColor(.secondary)
                        historyCleanup
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle(Texts_DirectLibre.diagnosticsRecovery)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isVisible = true
            Libre2SettingsVisibility.update(pageID, active: scenePhase == .active)
            handoff.recordReachability()
        }
        .onDisappear {
            isVisible = false
            Libre2SettingsVisibility.update(pageID, active: false)
        }
        .onChange(of: scenePhase) { phase in
            Libre2SettingsVisibility.update(pageID, active: isVisible && phase == .active)
            if isVisible && phase == .active { handoff.recordReachability() }
        }
        .alert(item: $unresolvedReadings) { readings in
            Alert(title: Text(Texts_DirectLibre.deleteUnresolvedReadings),
                  message: Text(Texts_DirectLibre.confirmDeleteUnresolved(readings.count)),
                  primaryButton: .destructive(Text(Texts_Common.delete)) {
                      requestHistoryCleanup(.delete(readings))
                  },
                  secondaryButton: .cancel())
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

/// Navigation can overlap appear/disappear callbacks. A disappearing page must not
/// disable event-driven UI refreshes for the other experimental settings page.
private enum Libre2SettingsVisibility {
    private static var activePages = Set<UUID>()

    static func update(_ pageID: UUID, active: Bool) {
        if active { activePages.insert(pageID) }
        else { activePages.remove(pageID) }
        Libre2PhoneHandoff.shared.isPageVisible = !activePages.isEmpty
    }
}

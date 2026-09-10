import SwiftUI

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
    @State private var confirmsReclaim = false
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
                Libre2ChecklistView(
                    groups: handoff.checklistGroups,
                    showsVerification: handoff.owner == .phone && !handoff.readingStatus.hasRecentVerifiedReading(),
                    canVerify: handoff.canVerifyPhoneConnection,
                    verify: handoff.verifyPhoneConnection
                )
                Divider()
                Libre2ActivityLogView()
            }
            .padding()
        }
        .onAppear {
            handoff.recordReachability()
            handoff.refreshChecklistSettings()
            handoff.refreshChecklist()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
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
        .alert(Texts_DirectLibre.reclaimTitle, isPresented: $confirmsReclaim) {
            Button(Texts_DirectLibre.reclaimTitle, role: .destructive) { handoff.reclaimViaNFC() }
            Button(Texts_DirectLibre.cancelAction, role: .cancel) {}
        } message: {
            Text(Texts_DirectLibre.confirmReclaim)
        }
        .navigationTitle(Texts_DirectLibre.experimentTitle)
        .navigationBarTitleDisplayMode(.inline)
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
            Button(Texts_DirectLibre.reclaimTitle) { confirmsReclaim = true }
                .disabled(!handoff.canReclaim)
            Text(Texts_DirectLibre.reclaimSummary).font(.caption).foregroundColor(.secondary)
        }
    }
}

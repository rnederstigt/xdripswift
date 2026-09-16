import SwiftUI
import WatchConnectivity

struct Libre2ChecklistView: View {
    let groups: [Libre2ChecklistGroup]
    @State private var isExpanded = false

    // Paused phone checks are explanatory, not failed Watch requirements.
    private var applicableItems: [Libre2ChecklistItem] {
        groups.filter { $0.note == nil }.flatMap(\.items)
    }
    private var missingIDs: [String] { applicableItems.filter { !$0.isSatisfied }.map(\.id) }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.title).font(.subheadline).fontWeight(.semibold).foregroundColor(.secondary)
                        if let note = group.note {
                            Text(note).font(.caption).foregroundColor(.secondary)
                        } else {
                            ForEach(group.items) { item in checklistRow(item) }
                        }
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(Texts_DirectLibre.checklistTitle).font(.headline)
                Text(Texts_DirectLibre.checklistProgress(applicableItems.count - missingIDs.count, applicableItems.count))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .onAppear { isExpanded = !missingIDs.isEmpty }
        .onChange(of: missingIDs) { missing in
            if !missing.isEmpty { isExpanded = true }
        }
    }

    private func checklistRow(_ item: Libre2ChecklistItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.isSatisfied ? "checkmark.circle.fill" : "circle")
                .foregroundColor(item.isSatisfied ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                if !item.isSatisfied || item.showsDetailWhenSatisfied {
                    Text(item.detail).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            item.isSatisfied
                ? Texts_DirectLibre.checkPassed
                : Texts_DirectLibre.checkMissing)
    }
}

struct Libre2ActivityLogView: View {
    @State private var entries = Libre2ActivityLog.shared.entries
    @State private var watchEntries: [Libre2ActivityLog.Entry] = []
    @State private var capturedAt: Date?
    @State private var isLoading = false
    @State private var loadError = ""
    @State private var isTracingEnabled = Libre2ActivityLog.shared.isTracingEnabled
    @ObservedObject private var handoff = Libre2PhoneHandoff.shared
    private static let pageSize = 5
    @State private var visibleCount = Libre2ActivityLogView.pageSize

    private struct Row: Identifiable {
        let source: String
        let entry: Libre2ActivityLog.Entry
        var id: String { source + entry.id.uuidString }
    }

    private var rows: [Row] {
        (entries.map { Row(source: "iPhone", entry: $0) }
            + watchEntries.map { Row(source: "Watch", entry: $0) })
            .sorted { $0.entry.date > $1.entry.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Texts_DirectLibre.activityLog).font(.headline)
            Toggle(Texts_DirectLibre.detailedDiagnostics, isOn: Binding(
                get: { isTracingEnabled }, set: { loadWatchActivity(tracing: $0) }))
                .disabled(isLoading || !handoff.reachable)
                .font(.caption)
            Text(Texts_DirectLibre.detailedDiagnosticsHelp)
                .font(.caption2).foregroundColor(.secondary)
            HStack {
                Button(Texts_DirectLibre.loadWatchActivity) { loadWatchActivity() }
                    .disabled(isLoading || !handoff.reachable)
                if isLoading { ProgressView() }
                Spacer()
                ShareLink(item: Libre2ActivityLog.report(phone: entries, watch: watchEntries, capturedAt: capturedAt)) {
                    Label(Texts_DirectLibre.shareActivity, systemImage: "square.and.arrow.up")
                }
                .disabled(rows.isEmpty)
            }
            .font(.caption)
            if let capturedAt {
                Text(Texts_DirectLibre.watchActivitySnapshot(capturedAt))
                    .font(.caption2).foregroundColor(.secondary)
            }
            Text(loadError.isEmpty ? Texts_DirectLibre.deliveryDiagnosticsHelp : loadError)
                .font(.caption).foregroundColor(.secondary)
            if rows.isEmpty {
                Text(Texts_DirectLibre.emptyLog).font(.caption).foregroundColor(.secondary)
            }
            ForEach(Array(rows.prefix(visibleCount))) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(row.source) · \(row.entry.date.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(row.entry.message).font(.caption)
                }
            }
            HStack {
                if rows.count > visibleCount {
                    Button(Texts_DirectLibre.showMoreActivity) {
                        visibleCount = min(visibleCount + Self.pageSize, rows.count)
                    }
                }
                if visibleCount > Self.pageSize {
                    Spacer()
                    Button(Texts_DirectLibre.showLessActivity) { visibleCount = Self.pageSize }
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { entries = Libre2ActivityLog.shared.entries }
        .onReceive(NotificationCenter.default.publisher(for: Libre2ActivityLog.didChange, object: Libre2ActivityLog.shared)
            .receive(on: RunLoop.main)) { _ in
            entries = Libre2ActivityLog.shared.entries
        }
    }

    private func loadWatchActivity(tracing: Bool? = nil) {
        guard !isLoading, handoff.reachable else { return }
        isLoading = true
        loadError = ""
        var request: [String: Any] = [Libre2ActivityLog.requestKey: true]
        if let tracing { request[Libre2ActivityLog.tracingKey] = tracing }
        WCSession.default.sendMessage(request, replyHandler: { reply in
            DispatchQueue.main.async {
                isLoading = false
                do {
                    let snapshot = try Libre2ActivityLog.decodeSnapshot(reply)
                    if let enabled = reply[Libre2ActivityLog.tracingKey] as? Bool {
                        isTracingEnabled = enabled
                        Libre2ActivityLog.shared.isTracingEnabled = enabled
                    } else if tracing != nil {
                        // An older companion must not appear to confirm a setting it ignores.
                        loadError = Texts_DirectLibre.watchActivityUnavailable
                    }
                    watchEntries = snapshot
                    capturedAt = Date()
                } catch {
                    loadError = Texts_DirectLibre.watchActivityUnavailable
                }
            }
        }, errorHandler: { error in
            DispatchQueue.main.async {
                isLoading = false
                loadError = error.localizedDescription
            }
        })
    }
}

/// Main-page summary of ordinary phone journal events; detailed traces stay in diagnostics.
struct Libre2RecentActivityView: View {
    @State private var entries = Libre2ActivityLog.shared.entries
    @State private var isVisible = false
    @State private var visibleCount = 3

    private var recent: [Libre2ActivityLog.Entry] {
        entries.reversed().filter {
            !$0.message.hasPrefix("Delivery:") && !$0.message.hasPrefix("Lifecycle:")
                && !$0.message.hasPrefix("Complication:")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Texts_DirectLibre.activityLog).font(.headline)
            Text(Texts_DirectLibre.activityOnPhone).font(.caption).foregroundColor(.secondary)
            if recent.isEmpty {
                Text(Texts_DirectLibre.emptyLog).font(.caption).foregroundColor(.secondary)
            }
            ForEach(Array(recent.prefix(visibleCount))) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .foregroundColor(.secondary).monospacedDigit()
                    Text(entry.message).lineLimit(2)
                }
                .font(.caption)
            }
            HStack {
                if recent.count > visibleCount {
                    Button(Texts_DirectLibre.showMoreActivity) { visibleCount += 3 }
                }
                if visibleCount > 3 {
                    Spacer()
                    Button(Texts_DirectLibre.showLessActivity) { visibleCount = 3 }
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            isVisible = true
            entries = Libre2ActivityLog.shared.entries
        }
        .onDisappear { isVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: Libre2ActivityLog.didChange, object: Libre2ActivityLog.shared)
            .receive(on: RunLoop.main)) { _ in
            if isVisible { entries = Libre2ActivityLog.shared.entries }
        }
    }
}

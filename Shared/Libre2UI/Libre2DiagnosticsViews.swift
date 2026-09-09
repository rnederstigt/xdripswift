import SwiftUI

struct Libre2ChecklistView: View {
    let groups: [Libre2ChecklistGroup]
    let showsVerification: Bool
    let canVerify: Bool
    let verify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Texts_DirectLibre.checklistTitle).font(.headline)
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title).font(.subheadline).fontWeight(.semibold).foregroundColor(.secondary)
                    if let note = group.note {
                        Text(note).font(.caption).foregroundColor(.secondary)
                    } else {
                        ForEach(group.items) { item in
                            checklistRow(item)
                        }
                        if group.id == .phone && showsVerification {
                            Button(Texts_DirectLibre.verifyPhoneConnection, action: verify)
                                .disabled(!canVerify)
                            Text(Texts_DirectLibre.verifyPhoneConnectionHelp).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checklistRow(_ item: Libre2ChecklistItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.isSatisfied == true ? "checkmark.circle.fill" : "circle")
                .foregroundColor(item.isSatisfied == true ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                if item.isSatisfied != true || item.showsDetailWhenSatisfied {
                    Text(item.detail).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            item.isSatisfied == true
                ? Texts_DirectLibre.checkPassed
                : (item.isSatisfied == nil ? Texts_DirectLibre.checkWaiting : Texts_DirectLibre.checkMissing))
    }
}

struct Libre2ActivityLogView: View {
    let entries: [Libre2ActivityLog.Entry]
    private static let pageSize = 5
    @State private var visibleCount = Libre2ActivityLogView.pageSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Texts_DirectLibre.activityLog).font(.headline)
            if entries.isEmpty {
                Text(Texts_DirectLibre.emptyLog).font(.caption).foregroundColor(.secondary)
            }
            ForEach(Array(entries.reversed().prefix(visibleCount))) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundColor(.secondary)
                    Text(entry.message).font(.caption)
                }
            }
            HStack {
                if entries.count > visibleCount {
                    Button(Texts_DirectLibre.showMoreActivity) {
                        visibleCount = min(visibleCount + Self.pageSize, entries.count)
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
    }
}

import AegisCore
import SwiftUI

/// Offline password audit. Nothing leaves the device and no network lookups are performed.
struct PasswordHealthView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    /// Called with an item ID when the user chooses to open a flagged record.
    var onOpen: ((UUID) -> Void)?

    var body: some View {
        let report = session.passwordHealth
        VStack(spacing: 0) {
            AegisSheetHeader(title: L10n.text("health.title"), subtitle: L10n.text("health.subtitle"), symbol: "heart.text.square",
                             close: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summary(report)
                    if session.unreadableRevisionCount > 0 {
                        Label(L10n.text("health.partial"), systemImage: "exclamationmark.triangle")
                            .aegisFont(size: 12).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if report.loginsWithPassword == 0 {
                        AegisEmptyState(title: L10n.text("health.noLogins"), message: L10n.text("health.noLoginsDescription"), symbol: "key.horizontal")
                    } else if report.isHealthy {
                        AegisEmptyState(title: L10n.text("health.allGood"), message: L10n.text("health.allGoodDescription"), symbol: "checkmark.shield")
                    } else {
                        if !report.weak.isEmpty {
                            AegisSection(title: L10n.format("health.weak", Int64(report.weak.count)), subtitle: L10n.text("health.weakDescription")) {
                                ForEach(Array(report.weak.enumerated()), id: \.element.id) { index, weak in
                                    if index > 0 {
                                        divider
                                    }
                                    row(weak.entry, detail: weak.evaluation.level.title, tint: PasswordStrengthMeter.tint(for: weak.evaluation.level))
                                }
                            }
                        }
                        if !report.reusedGroups.isEmpty {
                            AegisSection(title: L10n.format("health.reused", Int64(report.reusedEntryCount)), subtitle: L10n.text("health.reusedDescription")) {
                                ForEach(Array(report.reusedGroups.enumerated()), id: \.element.id) { groupIndex, group in
                                    if groupIndex > 0 {
                                        Rectangle().fill(AegisTheme.border).frame(height: 4)
                                    }
                                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                        if index > 0 {
                                            divider
                                        }
                                        row(entry, detail: L10n.format("health.reusedCount", Int64(group.entries.count)), tint: Color.orange)
                                    }
                                }
                            }
                        }
                        if !report.aged.isEmpty {
                            AegisSection(title: L10n.format("health.aged", Int64(report.aged.count)),
                                         subtitle: L10n.format("health.agedDescription", Int64(PasswordHealth.agedThresholdDays)))
                            {
                                ForEach(Array(report.aged.enumerated()), id: \.element.id) { index, aged in
                                    if index > 0 {
                                        divider
                                    }
                                    row(aged.entry, detail: L10n.format("health.ageDays", Int64(aged.ageDays)), tint: AegisTheme.secondary)
                                }
                            }
                        }
                    }
                    Label(L10n.text("health.privacy"), systemImage: "lock.shield")
                        .aegisFont(size: 11).foregroundStyle(AegisTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24).frame(maxWidth: 650).frame(maxWidth: .infinity)
            }
        }
        .background(AegisTheme.background).aegisSheetSize(width: 600, height: 680).vaultErrorPresenter().privacySensitive()
        .onAppear { session.touch() }
        .onChange(of: session.phase) { _, phase in
            if phase != .unlocked {
                dismiss()
            }
        }
    }

    private func summary(_ report: PasswordHealth.Report) -> some View {
        let tint: Color = report.score >= 85 ? AegisTheme.teal : report.score >= 60 ? AegisTheme.gold : AegisTheme.danger
        return HStack(spacing: 18) {
            ZStack {
                Circle().stroke(AegisTheme.border, lineWidth: 6)
                Circle().trim(from: 0, to: CGFloat(report.score) / 100).stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(report.score, format: .number).aegisFont(size: 20, weight: .semibold).monospacedDigit().foregroundStyle(AegisTheme.text)
            }.frame(width: 72, height: 72).accessibilityElement().accessibilityLabel(L10n.format("health.score", Int64(report.score)))
                .accessibilityIdentifier("healthScore")
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.format("health.checked", Int64(report.loginsWithPassword))).aegisFont(size: 14, weight: .semibold).foregroundStyle(AegisTheme.text)
                Text(L10n.format("health.affected", Int64(report.affectedEntryCount))).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary)
            }
            Spacer(minLength: 0)
        }.aegisCard()
    }

    private var divider: some View {
        Rectangle().fill(AegisTheme.border).frame(height: 0.5).padding(.leading, 64)
    }

    private func row(_ entry: VaultEntry, detail: String, tint: Color) -> some View {
        Button {
            if let onOpen {
                onOpen(entry.item.id); dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                ItemIcon(item: entry.item, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.item.title).aegisFont(size: 13, weight: .medium).foregroundStyle(AegisTheme.text).lineLimit(1)
                    Text(entry.listSubtitle).aegisFont(size: 11).foregroundStyle(AegisTheme.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(detail).aegisFont(size: 11, weight: .medium).foregroundStyle(tint)
                if onOpen != nil {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(AegisTheme.secondary)
                }
            }.padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(onOpen == nil)
    }
}

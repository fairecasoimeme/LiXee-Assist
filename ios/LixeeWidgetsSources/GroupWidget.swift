import AppIntents
import SwiftUI
import WidgetKit

extension Color {
    /// Une couleur publiée par la box, en `#rrggbb`.
    init?(hexString: String) {
        var text = hexString
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(uiColor: UIColor(hex: value))
    }
}

/// Un groupe d'actions, tel que la box le décrit.
struct GroupState {
    let name: String
    let icon: String?

    /// Tracé Material Design de l'icône. Absent des firmwares antérieurs à
    /// 4.23, qui ne publiaient qu'un emoji.
    let iconPath: String?
    let tint: Color?
    let count: Int
    let enabled: Bool

    /// Actions parties au dernier déclenchement, ou `nil` si jamais déclenché.
    let sent: Int?
    let timestamp: Date?
    let failedAt: Date?

    var unreachable: Bool {
        guard let failedAt else { return false }
        guard let timestamp else { return true }
        return failedAt > timestamp
    }

    static func load(key: String) -> GroupState {
        let raw = Shared.object("\(key).group")
        return GroupState(
            name: raw.string("name") ?? key,
            icon: raw.string("icon"),
            iconPath: raw.string("iconPath"),
            tint: raw.string("color").flatMap { Color(hexString: $0) },
            count: raw.int("count") ?? 0,
            enabled: raw["enabled"] == nil ? true : raw.bool("enabled"),
            sent: Shared.int("\(key).sent"),
            timestamp: Shared.date("\(key).ts"),
            failedAt: Shared.date("\(key).failedat")
        )
    }

    /// Ce que dit le pied du widget : ce que le groupe fera, ou ce qu'il vient
    /// de faire.
    var footnote: String {
        if unreachable { return "Échec" }
        guard let sent, let timestamp else {
            return "\(count) action\(count > 1 ? "s" : "")"
        }
        let age = relativeAge(Date.now.timeIntervalSince(timestamp))
        return "\(sent) envoyée\(sent > 1 ? "s" : "") · \(age)"
    }

    static var sample: GroupState {
        GroupState(
            name: "Tout éteindre",
            icon: "power",
            iconPath: "M16.56,5.44L15.11,6.89C16.84,7.94 18,9.83 18,12A6,6 0 0,1 12,18A6,6 0 0,1 6,12C6,9.83 7.16,7.94 8.88,6.88L7.44,5.44C5.36,6.88 4,9.28 4,12A8,8 0 0,0 12,20A8,8 0 0,0 20,12C20,9.28 18.64,6.88 16.56,5.44M13,3H11V13H13",
            tint: Color(hexString: "#1B75BC"),
            count: 4,
            enabled: true,
            sent: nil,
            timestamp: nil,
            failedAt: nil
        )
    }
}

struct GroupEntry: TimelineEntry {
    let date: Date
    let group: GroupEntity?
    let state: GroupState?
}

struct GroupProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GroupEntry {
        GroupEntry(
            date: .now,
            group: GroupEntity(id: "sample", label: "Tout éteindre", box: "LiXee-Box"),
            state: .sample
        )
    }

    func snapshot(for configuration: SelectGroupIntent, in context: Context) async -> GroupEntry {
        if context.isPreview { return placeholder(in: context) }
        return entry(for: configuration)
    }

    func timeline(for configuration: SelectGroupIntent, in context: Context) async -> Timeline<GroupEntry> {
        Timeline(
            entries: [entry(for: configuration)],
            policy: .after(.now.addingTimeInterval(15 * 60))
        )
    }

    private func entry(for configuration: SelectGroupIntent) -> GroupEntry {
        let group = configuration.group ?? GroupEntity.published().first
        return GroupEntry(
            date: .now,
            group: group,
            state: group.map { GroupState.load(key: $0.id) }
        )
    }
}

@available(iOS 17.0, *)
struct GroupWidgetView: View {
    let entry: GroupEntry

    var body: some View {
        Group {
            if let group = entry.group, let state = entry.state {
                content(group: group, state: state)
            } else {
                UnboundView(subject: "Groupe")
            }
        }
        .containerBackground(Palette.background, for: .widget)
    }

    /// Le widget entier est le bouton : un groupe n'a qu'une chose à faire.
    private func content(group: GroupEntity, state: GroupState) -> some View {
        Button(intent: LixeeActionIntent(url: WidgetAction.url("groupaction", [group.id]))) {
            VStack(spacing: 6) {
                icon(state)
                Text(state.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state.tint ?? Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(state.footnote)
                    .font(.system(size: 10))
                    .foregroundStyle(state.unreachable ? Palette.warn : Palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
            // Un groupe désactivé sur la box reste visible mais s'annonce tel :
            // le masquer laisserait un widget vide sans dire pourquoi.
            .opacity(state.enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!state.enabled)
    }

    @ViewBuilder
    private func icon(_ state: GroupState) -> some View {
        if let path = state.iconPath, !path.isEmpty {
            IconPath(commands: path)
                .fill(state.tint ?? Palette.accent)
                .frame(width: 36, height: 36)
        } else if let icon = state.icon, icon.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C }) {
            // Avant que la box ne publie les tracés, l'icône n'était qu'un
            // emoji — le seul cas où `icon` se dessine tel quel.
            Text(icon).font(.system(size: 28))
        }
    }
}

struct ActionGroupWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "LixeeGroupWidget",
            intent: SelectGroupIntent.self,
            provider: GroupProvider()
        ) { entry in
            GroupWidgetView(entry: entry)
        }
        .configurationDisplayName("LiXee — Groupe d'actions")
        .description("Déclenche un groupe d'actions d'un seul appui.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

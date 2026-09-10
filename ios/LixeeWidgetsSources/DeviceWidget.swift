import AppIntents
import SwiftUI
import WidgetKit

/// Une grandeur publiée par un appareil : « Température 21,5 °C ».
struct DeviceReading {
    let name: String
    let value: Double?
    let unit: String?

    /// La valeur telle qu'elle se lit, unité comprise.
    ///
    /// Une position de volet se dit mieux en mots qu'en pourcentage aux deux
    /// extrémités : « 100 % ouvert » lève le doute sur le sens de l'échelle,
    /// que 0 % laisserait entier.
    var display: String? {
        guard let value else { return nil }
        var text = formatted(value)
        if let unit { text += "\u{00A0}\(unit)" }
        if name == "current_position" {
            if value >= 99 { text += " ouvert" } else if value <= 1 { text += " fermé" }
        }
        return text
    }

    static func decode(_ raw: [String: Any]) -> DeviceReading {
        DeviceReading(
            name: raw.string("name") ?? "",
            value: raw.double("value"),
            unit: raw.string("unit")
        )
    }
}

/// Un bouton proposé par l'appareil, avec de quoi émettre sa commande.
///
/// Les paramètres voyagent avec le bouton plutôt que d'être relus à l'appui :
/// interroger l'inventaire de la box d'abord retardait le volet de plusieurs
/// secondes.
struct DeviceActionSpec {
    let name: String
    let command: Int
    let endpoint: Int?
    let value: Int
    let cluster: Int?
    let manufacturer: Int?

    static func decode(_ raw: [String: Any]) -> DeviceActionSpec {
        DeviceActionSpec(
            name: raw.string("name") ?? "",
            command: raw.int("command") ?? 0,
            endpoint: raw.int("endpoint"),
            value: raw.int("value") ?? 0,
            cluster: raw.int("cluster"),
            manufacturer: raw.int("mfr")
        )
    }

    /// L'URI que le rappel Dart attend, paramètres compris.
    func url(deviceKey: String, shortAddr: Int, fallbackEndpoint: Int) -> URL? {
        var query = [
            "sa": String(shortAddr),
            "e": String(endpoint ?? fallbackEndpoint),
            "c": String(command),
            "v": String(value),
        ]
        if let cluster { query["cl"] = String(cluster) }
        if let manufacturer { query["m"] = String(manufacturer) }
        return WidgetAction.url("devaction", [deviceKey, name], query: query)
    }
}

/// L'état d'un appareil, relu depuis l'App Group.
struct DeviceState {
    let label: String
    let shortAddr: Int
    let endpoint: Int
    let readings: [DeviceReading]
    let actions: [DeviceActionSpec]
    let timestamp: Date?
    let failedAt: Date?

    /// Un appareil n'a pas de forme connue d'avance : le gabarit de la box
    /// dicte combien de grandeurs et combien de boutons. Tout arrive donc en
    /// un seul objet JSON, contrairement aux relevés Linky.
    static func load(key: String) -> DeviceState {
        let raw = Shared.object("\(key).device")
        return DeviceState(
            label: raw.string("label") ?? key,
            shortAddr: raw.int("short") ?? 0,
            endpoint: raw.int("endpoint") ?? 1,
            readings: raw.list("readings").map(DeviceReading.decode),
            actions: raw.list("actions").map(DeviceActionSpec.decode),
            timestamp: Shared.date("\(key).ts"),
            failedAt: Shared.date("\(key).failedat")
        )
    }

    /// La grandeur qu'on lit de loin.
    var headline: DeviceReading? { readings.first }

    /// Les autres grandeurs chiffrées. Celles sans unité — « calibration »,
    /// « mouvement en cours » — sont des états, pas des mesures : les aligner
    /// avec les autres les ferait passer pour des relevés.
    var details: [DeviceReading] {
        readings.dropFirst().filter { $0.unit != nil && $0.display != nil }
    }

    static var sample: DeviceState {
        DeviceState(
            label: "Volet salon",
            shortAddr: 4242,
            endpoint: 1,
            readings: [
                DeviceReading(name: "current_position", value: 100, unit: "%"),
                DeviceReading(name: "Batterie", value: 85, unit: "%"),
            ],
            actions: [
                DeviceActionSpec(name: "Ouvrir", command: 0, endpoint: 1, value: 0, cluster: nil, manufacturer: nil),
                DeviceActionSpec(name: "Stop", command: 2, endpoint: 1, value: 0, cluster: nil, manufacturer: nil),
                DeviceActionSpec(name: "Fermer", command: 1, endpoint: 1, value: 0, cluster: nil, manufacturer: nil),
            ],
            timestamp: .now,
            failedAt: nil
        )
    }
}

struct DeviceEntry: TimelineEntry {
    let date: Date
    let device: DeviceEntity?
    let state: DeviceState?
}

struct DeviceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DeviceEntry {
        DeviceEntry(
            date: .now,
            device: DeviceEntity(id: "sample", label: "Volet salon", box: "LiXee-Box"),
            state: .sample
        )
    }

    func snapshot(for configuration: SelectDeviceIntent, in context: Context) async -> DeviceEntry {
        if context.isPreview { return placeholder(in: context) }
        return entry(for: configuration)
    }

    func timeline(for configuration: SelectDeviceIntent, in context: Context) async -> Timeline<DeviceEntry> {
        Timeline(
            entries: [entry(for: configuration)],
            policy: .after(.now.addingTimeInterval(15 * 60))
        )
    }

    private func entry(for configuration: SelectDeviceIntent) -> DeviceEntry {
        let device = configuration.device ?? DeviceEntity.published().first
        return DeviceEntry(
            date: .now,
            device: device,
            state: device.map { DeviceState.load(key: $0.id) }
        )
    }
}

@available(iOS 17.0, *)
struct DeviceWidgetView: View {
    let entry: DeviceEntry

    var body: some View {
        Group {
            if let device = entry.device, let state = entry.state {
                content(device: device, state: state)
            } else {
                UnboundView(subject: "Appareil")
            }
        }
        .containerBackground(Palette.background, for: .widget)
    }

    private func content(device: DeviceEntity, state: DeviceState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(
                title: state.label,
                freshness: freshness(timestamp: state.timestamp, failedAt: state.failedAt)
            )

            if let headline = state.headline, let display = headline.display {
                Text(headline.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Text(display)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Text("—")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }

            if !state.details.isEmpty {
                Text(state.details.compactMap { reading in
                    reading.display.map { "\(reading.name) \($0)" }
                }.joined(separator: "   "))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if !state.actions.isEmpty {
                buttons(device: device, state: state)
            }
        }
        .padding(10)
        .widgetURL(WidgetAction.url("devrefresh", [device.id]))
    }

    /// Les boutons sur trois colonnes, comme la grille Android. Au-delà de
    /// douze, le widget ne serait plus lisible : la box en propose rarement
    /// autant, et les derniers seraient illisibles.
    private func buttons(device: DeviceEntity, state: DeviceState) -> some View {
        let actions = Array(state.actions.prefix(12))
        let rows = stride(from: 0, to: actions.count, by: 3).map {
            Array(actions[$0..<min($0 + 3, actions.count)])
        }
        return VStack(spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, action in
                        WidgetButton(
                            title: action.name,
                            url: action.url(
                                deviceKey: device.id,
                                shortAddr: state.shortAddr,
                                fallbackEndpoint: state.endpoint
                            )
                        )
                    }
                    // Une rangée incomplète garde ses colonnes : sans cela le
                    // dernier bouton s'étirerait sur toute la largeur.
                    ForEach(row.count..<3, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, minHeight: 34)
                    }
                }
            }
        }
    }
}

struct DeviceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "LixeeDeviceWidget",
            intent: SelectDeviceIntent.self,
            provider: DeviceProvider()
        ) { entry in
            DeviceWidgetView(entry: entry)
        }
        .configurationDisplayName("LiXee — Appareil")
        .description("État d'un appareil Zigbee et ses commandes.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

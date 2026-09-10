import AppIntents
import SwiftUI
import WidgetKit

/// Une zone de thermostat, telle que la box la décrit.
struct ThermostatState {
    let name: String

    /// Consigne demandée — c'est elle que la jauge remplit, pas la mesure :
    /// c'est la valeur sur laquelle on agit.
    let setpoint: Double

    /// Température mesurée. Absente quand la zone n'a pas de sonde.
    let temperature: Double?

    /// Vrai en chauffage, faux en refroidissement.
    let heating: Bool

    /// La zone peut basculer entre chaud et froid.
    let reversible: Bool

    /// L'actionneur régule en ce moment.
    let active: Bool

    /// 0 automatique, 1 marche forcée, 2 arrêt forcé.
    let force: Int

    let frost: Bool
    let timestamp: Date?
    let failedAt: Date?

    static func load(key: String) -> ThermostatState {
        let raw = Shared.object("\(key).thermo")
        return ThermostatState(
            name: raw.string("name") ?? key,
            setpoint: raw.double("setpoint") ?? 0,
            temperature: raw.double("temp"),
            heating: raw.bool("heating"),
            reversible: raw.bool("reversible"),
            active: raw.bool("active"),
            force: raw.int("force") ?? 0,
            frost: raw.bool("frost"),
            timestamp: Shared.date("\(key).ts"),
            failedAt: Shared.date("\(key).failedat")
        )
    }

    var forceLabel: String {
        switch force {
        case 1: return "Marche forcée"
        case 2: return "Arrêt forcé"
        default: return "Auto"
        }
    }

    /// Ce que fait la zone, en une ligne.
    var summary: String {
        var parts = [heating ? "Chaud" : "Froid", forceLabel]
        if frost { parts.append("Hors-gel") }
        parts.append(active ? "régule" : "au repos")
        return parts.joined(separator: " · ")
    }

    static var sample: ThermostatState {
        ThermostatState(
            name: "Salon",
            setpoint: 20.5,
            temperature: 19.2,
            heating: true,
            reversible: false,
            active: true,
            force: 0,
            frost: false,
            timestamp: .now,
            failedAt: nil
        )
    }
}

/// La jauge : un arc de 270°, gradué de 5 à 35 °C.
///
/// L'arc est rempli jusqu'à la consigne ; la mesure, elle, n'est qu'un curseur
/// posé dessus. Confondre les deux ferait croire qu'on agit sur la
/// température, alors qu'on ne règle que ce qu'on demande à l'actionneur.
struct ThermostatGaugeView: View {
    let setpoint: Double
    let temperature: Double?
    let heating: Bool
    let active: Bool

    private static let minimum = 5.0
    private static let maximum = 35.0

    /// 270° sur les 360 du cercle, ouverts vers le bas.
    private static let sweep = 0.75
    private static let startAngle = 135.0

    private func fraction(_ value: Double) -> Double {
        min(1, max(0, (value - Self.minimum) / (Self.maximum - Self.minimum)))
    }

    /// Vif quand l'actionneur marche, pâle quand il est au repos.
    private var tint: Color {
        if heating { return active ? Palette.heatOn : Palette.heatOff }
        return active ? Palette.coolOn : Palette.coolOff
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let stroke = side * 0.11
            ZStack {
                Circle()
                    .trim(from: 0, to: Self.sweep)
                    .stroke(Palette.track, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(Self.startAngle))
                    .padding(stroke / 2)
                Circle()
                    .trim(from: 0, to: Self.sweep * fraction(setpoint))
                    .stroke(tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(Self.startAngle))
                    .padding(stroke / 2)
                if let temperature {
                    cursor(side: side, stroke: stroke, at: temperature)
                }
                center(side: side)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// La mesure, posée sur l'arc.
    private func cursor(side: CGFloat, stroke: CGFloat, at temperature: Double) -> some View {
        let angle = (Self.startAngle + 360 * Self.sweep * fraction(temperature)) * .pi / 180
        let radius = (side - stroke) / 2
        return ZStack {
            Circle().fill(Palette.background)
                .frame(width: stroke * 0.46, height: stroke * 0.46)
            Circle().fill(Palette.textPrimary)
                .frame(width: stroke * 0.30, height: stroke * 0.30)
        }
        .offset(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    private func center(side: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 1) {
            Text(temperature.map { formatted($0, decimals: 1) } ?? "—")
                .font(.system(size: side * 0.24, weight: .semibold))
                .foregroundStyle(temperature == nil ? Palette.textSecondary : Palette.textPrimary)
            Text("°C")
                .font(.system(size: side * 0.11, weight: .medium))
                .foregroundStyle(active ? Palette.warn : Palette.textSecondary)
        }
    }
}

struct ThermostatEntry: TimelineEntry {
    let date: Date
    let zone: ThermostatEntity?
    let state: ThermostatState?
}

struct ThermostatProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ThermostatEntry {
        ThermostatEntry(
            date: .now,
            zone: ThermostatEntity(id: "sample", label: "Salon", box: "LiXee-Box"),
            state: .sample
        )
    }

    func snapshot(for configuration: SelectThermostatIntent, in context: Context) async -> ThermostatEntry {
        if context.isPreview { return placeholder(in: context) }
        return entry(for: configuration)
    }

    func timeline(for configuration: SelectThermostatIntent, in context: Context) async -> Timeline<ThermostatEntry> {
        Timeline(
            entries: [entry(for: configuration)],
            policy: .after(.now.addingTimeInterval(15 * 60))
        )
    }

    private func entry(for configuration: SelectThermostatIntent) -> ThermostatEntry {
        let zone = configuration.zone ?? ThermostatEntity.published().first
        return ThermostatEntry(
            date: .now,
            zone: zone,
            state: zone.map { ThermostatState.load(key: $0.id) }
        )
    }
}

@available(iOS 17.0, *)
struct ThermostatWidgetView: View {
    let entry: ThermostatEntry

    var body: some View {
        Group {
            if let zone = entry.zone, let state = entry.state {
                content(zone: zone, state: state)
            } else {
                UnboundView(subject: "Thermostat")
            }
        }
        .containerBackground(Palette.background, for: .widget)
    }

    private func content(zone: ThermostatEntity, state: ThermostatState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(
                title: state.name,
                freshness: freshness(timestamp: state.timestamp, failedAt: state.failedAt)
            )

            HStack(spacing: 10) {
                ThermostatGaugeView(
                    setpoint: state.setpoint,
                    temperature: state.temperature,
                    heating: state.heating,
                    active: state.active
                )
                .frame(width: 86, height: 86)

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor(state))
                        .lineLimit(3)
                    if state.temperature == nil {
                        Text("Pas de sonde")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    setpointRow(zone: zone, state: state)
                }
            }

            modeRows(zone: zone, state: state)
        }
        .padding(10)
    }

    private func statusColor(_ state: ThermostatState) -> Color {
        guard state.active else { return Palette.textSecondary }
        return state.heating ? Palette.warn : Palette.accent
    }

    /// La consigne se règle sans confirmation : un demi-degré s'annule d'un
    /// appui sur l'autre bouton.
    private func setpointRow(zone: ThermostatEntity, state: ThermostatState) -> some View {
        HStack(spacing: 4) {
            WidgetButton(
                title: "−",
                url: WidgetAction.url("thermo", [zone.id], query: ["d": "-0.5"]),
                height: 32,
                size: 16
            )
            Text("\(formatted(state.setpoint, decimals: 1))\u{00A0}°C")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(state.active ? Palette.warn : Palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
            WidgetButton(
                title: "+",
                url: WidgetAction.url("thermo", [zone.id], query: ["d": "0.5"]),
                height: 32,
                size: 16
            )
        }
    }

    @ViewBuilder
    private func modeRows(zone: ThermostatEntity, state: ThermostatState) -> some View {
        HStack(spacing: 4) {
            forceButton("Auto", value: 0, zone: zone, state: state)
            forceButton("Marche", value: 1, zone: zone, state: state)
            forceButton("Arrêt", value: 2, zone: zone, state: state)
        }

        if state.reversible || state.heating {
            HStack(spacing: 4) {
                if state.reversible {
                    WidgetButton(
                        title: "Chaud",
                        url: WidgetAction.url("thermo", [zone.id], query: ["h": "1"]),
                        background: state.heating ? Palette.warn : Palette.actionBackground,
                        foreground: state.heating ? Palette.onAccent : Palette.textPrimary,
                        height: 30,
                        size: 11
                    )
                    WidgetButton(
                        title: "Froid",
                        url: WidgetAction.url("thermo", [zone.id], query: ["h": "0"]),
                        background: state.heating ? Palette.actionBackground : Palette.accent,
                        foreground: state.heating ? Palette.textPrimary : Palette.onAccent,
                        height: 30,
                        size: 11
                    )
                }
                // Le hors-gel n'a de sens qu'en chauffage : refroidir une pièce
                // ne risque pas de geler les canalisations.
                if state.heating {
                    WidgetButton(
                        title: "Hors-gel",
                        url: WidgetAction.url("thermo", [zone.id], query: ["g": "1"]),
                        background: state.frost ? Palette.frost : Palette.actionBackground,
                        foreground: state.frost ? Palette.onAccent : Palette.textPrimary,
                        height: 30,
                        size: 11
                    )
                }
            }
        }
    }

    private func forceButton(
        _ title: String, value: Int, zone: ThermostatEntity, state: ThermostatState
    ) -> some View {
        let selected = state.force == value
        return WidgetButton(
            title: title,
            url: WidgetAction.url("thermo", [zone.id], query: ["f": String(value)]),
            background: selected ? Palette.accent : Palette.actionBackground,
            foreground: selected ? Palette.onAccent : Palette.textPrimary,
            height: 30,
            size: 11
        )
    }
}

struct ThermostatWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "LixeeThermostatWidget",
            intent: SelectThermostatIntent.self,
            provider: ThermostatProvider()
        ) { entry in
            ThermostatWidgetView(entry: entry)
        }
        .configurationDisplayName("LiXee — Thermostat")
        .description("Consigne, température et modes d'une zone.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

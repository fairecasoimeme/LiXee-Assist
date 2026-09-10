import SwiftUI
import WidgetKit

/// Une heure de la série publiée par l'app : `heure:soutiré:injecté`.
struct HourPoint: Identifiable {
    let id: Int
    let hour: Int
    let drawn: Int
    let injected: Int

    /// Positif quand on a tiré du réseau, négatif quand on y a injecté plus.
    var net: Int { drawn - injected }
}

/// Le relevé d'une box, relu depuis l'App Group.
struct EnergySnapshot {
    let power: Int?
    let maxPower: Int?
    let productionPower: Int?
    let daily: Int?
    let cost: Double?
    let production: Int?
    let revenue: Double?
    let net: Int?
    let netCost: Double?
    let trend: Int?
    let hourly: [HourPoint]
    let timestamp: Date?
    let failedAt: Date?

    /// La box n'a pas répondu depuis le dernier relevé abouti.
    var unreachable: Bool {
        guard let failedAt else { return false }
        guard let timestamp else { return true }
        return failedAt > timestamp
    }

    /// Mêmes clés que le widget Android : « <box>.<suffixe> ».
    static func load(box: String) -> EnergySnapshot {
        func key(_ suffix: String) -> String { "\(box)\(suffix)" }
        return EnergySnapshot(
            power: Shared.int(key(".power")),
            maxPower: Shared.int(key(".maxpower")),
            productionPower: Shared.int(key(".prodpower")),
            daily: Shared.int(key(".daily")),
            cost: Shared.double(key(".cost")),
            production: Shared.int(key(".production")),
            revenue: Shared.double(key(".revenue")),
            net: Shared.int(key(".net")),
            netCost: Shared.double(key(".netcost")),
            trend: Shared.int(key(".trend")),
            hourly: parseHourly(Shared.string(key(".hourly"))),
            timestamp: Shared.date(key(".ts")),
            failedAt: Shared.date(key(".failedat"))
        )
    }

    static func parseHourly(_ raw: String?) -> [HourPoint] {
        guard let raw else { return [] }
        var points: [HourPoint] = []
        for (index, item) in raw.split(separator: ",").enumerated() {
            let parts = item.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2 else { continue }
            points.append(HourPoint(
                id: index,
                hour: parts[0],
                drawn: parts[1],
                injected: parts.count > 2 ? parts[2] : 0
            ))
        }
        return points
    }

    /// Valeurs vraisemblables pour l'aperçu de la galerie de widgets.
    static func sample(_ theme: EnergyTheme) -> EnergySnapshot {
        let drawn = [320, 300, 260, 220, 200, 190, 180, 210, 380, 520, 460, 400,
                     360, 330, 310, 340, 440, 580, 640, 550, 440, 380, 350, 330]
        let injected = [0, 0, 0, 0, 0, 0, 0, 40, 260, 620, 880, 1020,
                        1100, 980, 760, 420, 120, 10, 0, 0, 0, 0, 0, 0]
        let points = (0..<24).map {
            HourPoint(id: $0, hour: (15 + $0) % 24, drawn: drawn[$0], injected: injected[$0])
        }
        return EnergySnapshot(
            power: 370, maxPower: 9000, productionPower: 1240,
            daily: 4920, cost: 1.41, production: 8100, revenue: 1.05,
            net: -3180, netCost: -0.36, trend: theme == .production ? 23 : -12,
            hourly: points, timestamp: .now, failedAt: nil
        )
    }
}

/// Les trois thèmes énergie, calqués sur WidgetTheme côté Android.
enum EnergyTheme {
    case consumption
    case production
    case balance

    /// Doivent rester identiques à `_iosKinds` dans HomeWidgetBridge.
    var kind: String {
        switch self {
        case .consumption: return "LixeeConsoWidget"
        case .production: return "LixeeProductionWidget"
        case .balance: return "LixeeBalanceWidget"
        }
    }

    var displayName: String {
        switch self {
        case .consumption: return "LiXee — Consommation"
        case .production: return "LiXee — Production"
        case .balance: return "LiXee — Bilan"
        }
    }

    var summary: String {
        switch self {
        case .consumption: return "Puissance instantanée, consommation et coût sur 24 h"
        case .production: return "Injection solaire et revenu sur 24 h"
        case .balance: return "Solde entre soutirage et injection, et facture nette"
        }
    }

    /// Le bilan n'a pas de jauge : un solde n'a pas d'échelle de zéro à la
    /// puissance souscrite, et en dessiner une mentirait.
    var gaugeLabel: String? {
        switch self {
        case .consumption: return "Puissance"
        case .production: return "Injection"
        case .balance: return nil
        }
    }

    var columnLabel: String {
        switch self {
        case .consumption: return "Conso"
        case .production: return "Production"
        case .balance: return "Bilan"
        }
    }

    var accent: Color {
        self == .production ? Palette.production : Palette.accent
    }

    /// Consommer plus coûte, produire plus rapporte : la même hausse n'a pas
    /// le même sens d'un thème à l'autre.
    var risingIsGood: Bool { self == .production }

    func power(_ s: EnergySnapshot) -> Int? {
        switch self {
        case .consumption: return s.power
        case .production: return s.productionPower
        case .balance: return nil
        }
    }

    func energy(_ s: EnergySnapshot) -> Int? {
        switch self {
        case .consumption: return s.daily
        case .production: return s.production
        case .balance: return s.net
        }
    }

    func amount(_ s: EnergySnapshot) -> Double? {
        switch self {
        case .consumption: return s.cost
        case .production: return s.revenue
        case .balance: return s.netCost
        }
    }

    func value(of point: HourPoint) -> Int {
        switch self {
        case .consumption: return point.drawn
        case .production: return point.injected
        case .balance: return point.net
        }
    }
}

struct EnergyEntry: TimelineEntry {
    let date: Date
    let box: String?
    let snapshot: EnergySnapshot?
}

/// Relit les valeurs publiées par l'app ; ne fait aucun accès réseau.
///
/// C'est l'app qui relève les box et publie ; le widget ne fait que relire.
/// iOS décide seul quand il rafraîchit une chronologie : les 15 minutes
/// demandées sont un souhait, pas une promesse. L'app, elle, redemande un
/// rendu à chaque relevé abouti.
struct EnergyProvider: AppIntentTimelineProvider {
    let theme: EnergyTheme

    func placeholder(in context: Context) -> EnergyEntry {
        EnergyEntry(date: .now, box: "LiXee-Box", snapshot: .sample(theme))
    }

    func snapshot(for configuration: SelectBoxIntent, in context: Context) async -> EnergyEntry {
        if context.isPreview { return placeholder(in: context) }
        return entry(for: configuration)
    }

    func timeline(for configuration: SelectBoxIntent, in context: Context) async -> Timeline<EnergyEntry> {
        Timeline(
            entries: [entry(for: configuration)],
            policy: .after(.now.addingTimeInterval(15 * 60))
        )
    }

    private func entry(for configuration: SelectBoxIntent) -> EnergyEntry {
        let box = configuration.box?.id ?? Shared.boxNames().first
        return EnergyEntry(
            date: .now,
            box: box,
            snapshot: box.map { EnergySnapshot.load(box: $0) }
        )
    }
}

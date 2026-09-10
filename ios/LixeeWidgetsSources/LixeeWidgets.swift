import SwiftUI
import WidgetKit

/// Point d'entrée de l'extension : les trois widgets énergie.
///
/// Affichage seul pour ce premier jet. Les widgets Appareil, Groupe d'actions
/// et Thermostat, qui portent des boutons, demanderont iOS 17 et des
/// AppIntents interactifs : ils viendront dans un second temps.
@main
struct LixeeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ConsoWidget()
        ProductionWidget()
        BalanceWidget()
    }
}

/// Un widget énergie, paramétré par son thème.
///
/// Trois structures plutôt qu'une : iOS identifie un widget par son type, et
/// c'est ce qui leur donne trois entrées distinctes dans la galerie.
private func energyConfiguration(_ theme: EnergyTheme) -> some WidgetConfiguration {
    AppIntentConfiguration(
        kind: theme.kind,
        intent: SelectBoxIntent.self,
        provider: EnergyProvider(theme: theme)
    ) { entry in
        EnergyWidgetView(entry: entry, theme: theme)
    }
    .configurationDisplayName(theme.displayName)
    .description(theme.summary)
    .supportedFamilies([.systemMedium, .systemLarge])
}

struct ConsoWidget: Widget {
    var body: some WidgetConfiguration { energyConfiguration(.consumption) }
}

struct ProductionWidget: Widget {
    var body: some WidgetConfiguration { energyConfiguration(.production) }
}

struct BalanceWidget: Widget {
    var body: some WidgetConfiguration { energyConfiguration(.balance) }
}

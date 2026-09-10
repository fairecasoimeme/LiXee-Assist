import SwiftUI
import WidgetKit

/// Point d'entrée de l'extension : les six widgets, comme sur Android.
///
/// Les trois widgets énergie se contentent d'afficher. Les trois autres
/// portent des boutons : leur appui n'agit pas ici, il réveille le rappel Dart
/// qui commande la box — voir `LixeeActionIntent`.
@main
struct LixeeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ConsoWidget()
        ProductionWidget()
        BalanceWidget()
        DeviceWidget()
        ActionGroupWidget()
        ThermostatWidget()
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

package com.lixee.assist

/**
 * Ce qu'un widget lit et affiche.
 *
 * Les trois thèmes partagent le même stockage et le même rendu : ils ne
 * diffèrent que par les clés consultées et par leurs libellés. Chacun a sa
 * propre classe de provider pour apparaître séparément dans le sélecteur de
 * widgets, Android identifiant un provider par son nom de composant.
 */
enum class WidgetTheme(
    /** Suffixe de la puissance instantanée. Vide si le thème n'en a pas. */
    val powerKey: String?,
    /** Suffixe du total sur 24 h. */
    val dailyKey: String,
    /** Suffixe du montant sur 24 h. */
    val amountKey: String,
    val gaugeLabelRes: Int,
    val columnLabelRes: Int,
    /** Grandeur tracée par le graphe. */
    val chartSeries: WidgetChart.Series,
    /** Teinte du thème : jauge, barres et repère de l'heure en cours. */
    val accentColorRes: Int,
    /**
     * Une valeur qui monte est-elle une bonne nouvelle ?
     *
     * Consommer plus coûte, produire plus rapporte : la tendance ne peut pas
     * peindre toute hausse en rouge sans se tromper la moitié du temps.
     */
    val risingIsGood: Boolean,
    /**
     * Classe du provider, par son nom plutôt que par référence : une constante
     * d'enum qui pointerait sur une classe dont elle est elle-même le
     * paramètre créerait un cycle à l'initialisation.
     */
    val providerClassName: String,
) {
    CONSUMPTION(
        powerKey = ".power",
        dailyKey = ".daily",
        amountKey = ".cost",
        gaugeLabelRes = R.string.widget_gauge_label,
        columnLabelRes = R.string.widget_column_conso,
        chartSeries = WidgetChart.Series.DRAWN,
        accentColorRes = R.color.widget_accent,
        risingIsGood = false,
        providerClassName = "com.lixee.assist.ConsoWidgetProvider",
    ),

    PRODUCTION(
        powerKey = ".prodpower",
        dailyKey = ".production",
        amountKey = ".revenue",
        gaugeLabelRes = R.string.widget_gauge_label_production,
        columnLabelRes = R.string.widget_column_production,
        chartSeries = WidgetChart.Series.INJECTED,
        accentColorRes = R.color.widget_accent_production,
        risingIsGood = true,
        providerClassName = "com.lixee.assist.ProductionWidgetProvider",
    ),

    /**
     * Le solde n'a pas de jauge : une puissance nette est signée, et l'échelle
     * de la jauge — de zéro à la puissance souscrite — n'a pas de sens pour
     * elle. Son graphe est signé, consommation au-dessus de la ligne zéro et
     * production en-dessous.
     */
    BALANCE(
        powerKey = null,
        dailyKey = ".net",
        amountKey = ".netcost",
        gaugeLabelRes = R.string.widget_gauge_label,
        columnLabelRes = R.string.widget_column_balance,
        chartSeries = WidgetChart.Series.NET,
        accentColorRes = R.color.widget_accent,
        // Un solde qui monte, c'est tirer davantage du reseau.
        risingIsGood = false,
        providerClassName = "com.lixee.assist.BalanceWidgetProvider",
    );

    val hasGauge: Boolean get() = powerKey != null
}

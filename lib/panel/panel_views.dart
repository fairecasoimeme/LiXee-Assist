import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/home_screen.dart' show resolveMdnsIP;
import '../services/action_group_service.dart';
import '../services/box_client.dart';
import '../services/device_control_service.dart';
import '../services/energy_advice.dart';
import '../services/energy_detail_service.dart';
import 'panel_savings.dart';
import '../services/thermostat_service.dart';
import '../services/widget_data_service.dart';
import '../tv/tv_tabs.dart';
import '../tv/tv_theme.dart';
import 'panel_widgets.dart';

Widget _card({required Widget child, EdgeInsetsGeometry? padding}) => Container(
  padding: padding ?? const EdgeInsets.all(12),
  decoration: BoxDecoration(
    color: TvColors.panel,
    borderRadius: BorderRadius.circular(14),
  ),
  child: child,
);

// ---------------------------------------------------------------------------
// Énergie
// ---------------------------------------------------------------------------

/// La puissance en grand, le bilan sur 24 h, et le graphe heure par heure :
/// ce qu'on lit d'un coup d'œil en passant devant le panneau.
///
/// Sur un écran carré, la jauge et le bilan se partagent le haut. Sur un
/// écran vertical, la jauge prend toute la largeur et le bilan passe en
/// bandeau dessous : côte à côte, ils laisseraient deux colonnes à moitié
/// vides.
class PanelEnergyView extends StatelessWidget {
  final LinkySnapshot snapshot;
  final EnergyExtras? extras;

  /// Nom de la box affichée, qui porte son objectif du mois.
  final String box;

  const PanelEnergyView({
    super.key,
    required this.snapshot,
    required this.box,
    this.extras,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tall = constraints.maxHeight > constraints.maxWidth * 1.25;
        final wide = constraints.maxWidth > constraints.maxHeight * 1.25;
        if (tall) return _tall();
        return wide ? _wide() : _square();
      },
    );
  }

  Widget _square() {
    return Column(
      children: [
        ..._advice(compact: true),
        Expanded(
          flex: 11,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 10, child: _gauge()),
              const SizedBox(width: 8),
              Expanded(
                flex: 9,
                child: _card(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sur 24 h',
                        style: TextStyle(fontSize: 13, color: TvColors.muted),
                      ),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: _energy(32),
                      ),
                      if (snapshot.dailyCostEur != null) _cost(24),
                      if (_solar() case final solar?) solar,
                      if (_floor() case final floor?) floor,
                      const SizedBox(height: 4),
                      _age(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        ..._utilities(44, 15),
        const SizedBox(height: 8),
        Expanded(flex: 8, child: _chart()),
      ],
    );
  }

  /// Paysage (téléphone ou tablette couchés) : la jauge à gauche, le mois
  /// et les compteurs au milieu, l'électricité et son graphe à droite.
  Widget _wide() {
    final month = PanelMonthCard.of(extras, compact: true);
    final meters = extras?.utilities ?? const <UtilityMeter>[];
    final tiles = <Widget>[
      if (month != null) month,
      for (final meter in meters) TvUtilityTile(meter: meter, size: 18),
    ];
    return Column(
      children: [
        ..._advice(compact: true),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 4, child: _gauge()),
              const SizedBox(width: 8),
              Expanded(
                flex: 9,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _chart(header: true)),
                    // Le mois, le gaz et l'eau : une rangée de tuiles.
                    if (tiles.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 96,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final (i, tile) in tiles.indexed) ...[
                              if (i > 0) const SizedBox(width: 8),
                              Expanded(child: tile),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tall() {
    return Column(
      children: [
        ..._advice(compact: false),
        Expanded(flex: 10, child: _gauge()),
        // Le mois, puis les compteurs de la maison, chacun sur toute la
        // largeur : gaz, eau, et l'électricité avec son graphe.
        if (PanelMonthCard.of(extras) case final month?) ...[
          const SizedBox(height: 8),
          month,
        ],
        ..._utilities(64, 20, fullWidth: true),
        const SizedBox(height: 8),
        Expanded(flex: 8, child: _chart()),
      ],
    );
  }

  /// Gaz et eau, côte à côte, quand la box en suit.
  List<Widget> _utilities(
    double height,
    double size, {
    bool fullWidth = false,
  }) {
    final meters = extras?.utilities ?? const <UtilityMeter>[];
    if (meters.isEmpty) return const [];
    // Chacun sur sa ligne, le chiffre à gauche et les barres alignées sur
    // le graphe de l'électricité.
    if (fullWidth) {
      return [
        for (final meter in meters) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: height,
            child: TvUtilityTile(meter: meter, size: size, textWidth: 84),
          ),
        ],
      ];
    }
    return [
      const SizedBox(height: 8),
      SizedBox(
        height: height,
        child: Row(
          children: [
            for (final (i, meter) in meters.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: TvUtilityTile(meter: meter, size: size)),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _gauge() {
    final s = snapshot;
    final perHour = EnergyAdvice.costPerHour(s, extras);
    return _card(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          // Triphasé : une jauge par phase, sans total, car c'est une phase
          // qui fait sauter le disjoncteur. Producteur : la jauge d'injection
          // à côté, à l'échelle de l'abonnement.
          Expanded(
            child: Row(
              children: [
                if (s.threePhase) ..._phases(s) else Expanded(child: _arc(s)),
                if (s.productionPowerVA != null)
                  Expanded(child: _injectionArc(s)),
              ],
            ),
          ),
          if (EnergyAdvice.cutRisk(s, extras) case final risk?)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              // Dans une colonne étroite (paysage), le libellé court.
              child: LayoutBuilder(
                builder:
                    (context, box) =>
                        PanelRiskBar(risk: risk, short: box.maxWidth < 360),
              ),
            ),
          // En euros si le prix est saisi : c'est ce qui parle à tout le
          // monde. Sinon la jauge reste en VA, sans rien inventer.
          if (perHour != null &&
              perHour >= 0.01 &&
              (s.productionPowerVA ?? 0) == 0)
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '≈ ${tvNumber(perHour, decimals: 2)} € par heure à ce rythme',
                style: const TextStyle(fontSize: 15, color: TvColors.muted),
              ),
            ),
        ],
      ),
    );
  }

  /// L'injection en cours, en vert, sur l'échelle de l'abonnement.
  Widget _injectionArc(LinkySnapshot s) {
    final injected = s.productionPowerVA ?? 0;
    final max = s.subscribedPowerVA;
    return TvArcGauge(
      ratio: max == null || max == 0 ? 0 : injected / max,
      color: TvColors.solar,
      value: tvNumber(injected),
      caption: 'VA injectés',
      scaleText: true,
    );
  }

  /// Une jauge par phase : en triphasé, c'est une phase qui fait sauter le
  /// disjoncteur, même quand le total reste loin de l'abonnement.
  List<Widget> _phases(LinkySnapshot s) {
    final limit = s.phaseLimitVA;
    return [
      for (final (i, va) in s.phasePowersVA.indexed)
        Expanded(
          child: TvArcGauge(
            ratio: limit == null || limit == 0 ? 0 : va / limit,
            color: _phaseColor(limit == null || limit == 0 ? 0 : va / limit),
            value: tvNumber(va),
            caption:
                limit == null
                    ? 'Phase ${i + 1}'
                    : 'Phase ${i + 1} · sur ${tvNumber(limit)}',
            scaleText: true,
          ),
        ),
    ];
  }

  /// Bleu, puis orange à 70 %, rouge à 90 % de la limite de la phase.
  static Color _phaseColor(double ratio) =>
      ratio >= 0.9
          ? TvColors.bad
          : (ratio >= 0.7 ? TvColors.warn : TvColors.focus);

  Widget _arc(LinkySnapshot s) {
    return TvArcGauge(
      ratio:
          s.subscribedPowerVA == null || s.subscribedPowerVA == 0
              ? 0
              : (s.apparentPowerVA ?? 0) / s.subscribedPowerVA!,
      color: TvColors.focus,
      value: tvNumber(s.apparentPowerVA ?? 0),
      caption:
          s.subscribedPowerVA == null
              ? 'VA'
              : 'VA sur ${tvNumber(s.subscribedPowerVA!)}',
      scaleText: true,
    );
  }

  /// La consommation plancher : ce qui tourne même quand on ne fait rien.
  Widget? _floor() {
    final load = EnergyAdvice.baseLoad(snapshot, extras);
    if (load == null) return null;
    final yearly =
        load.yearlyEur != null
            ? '≈ ${tvNumber(load.yearlyEur!)} €/an'
            : '≈ ${tvNumber(load.yearlyKWh)} kWh/an';
    return Text(
      'Plancher ${tvNumber(load.watts)} W · $yearly',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13, color: TvColors.muted),
    );
  }

  /// La météo de l'électricité et les alertes, en pastilles : leur
  /// bandeau ne se déplie qu'à l'appui.
  List<Widget> _advice({required bool compact}) {
    final alerts = EnergyAdvice.alerts(snapshot, extras);
    final weather = EnergyAdvice.weather(snapshot, extras);
    if (weather == null && alerts.isEmpty) return const [];
    return [
      PanelStatusStrip(weather: weather, alerts: alerts, compact: compact),
      const SizedBox(height: 8),
    ];
  }

  Widget _energy(double size) => _figure(
    snapshot.dailyTotalWh == null
        ? '—'
        : tvNumber(snapshot.dailyTotalWh! / 1000, decimals: 2),
    'kWh',
    size,
  );

  Widget _cost(double size) =>
      _figure(tvNumber(snapshot.dailyCostEur!, decimals: 2), '€', size);

  /// L'injection en cours si la maison produit, sinon la production du jour.
  Widget? _solar() {
    final String text;
    if (snapshot.dailyProductionWh != null) {
      text =
          'Produit ${tvNumber(snapshot.dailyProductionWh! / 1000, decimals: 2)} kWh';
    } else {
      return null;
    }
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13, color: TvColors.solar),
    );
  }

  Widget _age() => Text(
    'Relevé ${tvAge(snapshot.timestamp)}',
    style: const TextStyle(fontSize: 12, color: TvColors.muted),
  );

  /// L'électricité comme le gaz et l'eau : son icône, son total et son
  /// coût à gauche, le graphe heure par heure à droite.
  /// [header] : les chiffres en une ligne au-dessus du graphe, qui prend
  /// alors toute la largeur (paysage).
  Widget _chart({bool header = false}) {
    final s = snapshot;
    final total = s.dailyTotalWh;
    final load = EnergyAdvice.baseLoad(s, extras);
    if (header) {
      final value =
          total == null
              ? '—'
              : '${tvNumber(total / 1000, decimals: 2)} kWh'
                  '${s.dailyCostEur == null ? '' : ' · ${tvNumber(s.dailyCostEur!, decimals: 2)} €'}';
      final details = [
        if (s.dailyProductionWh != null)
          'Produit ${tvNumber(s.dailyProductionWh! / 1000, decimals: 2)} kWh',
        if (load != null)
          'Plancher ${tvNumber(load.watts)} W'
              '${load.yearlyEur != null ? ' · ≈ ${tvNumber(load.yearlyEur!)} €/an' : ''}',
      ].join('   ');
      return _card(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(Icons.bolt, color: TvColors.focus, size: 24),
                const SizedBox(width: 6),
                const Text(
                  'Électricité · 24 h  ',
                  style: TextStyle(fontSize: 13, color: TvColors.muted),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    details,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: TvColors.muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child:
                  s.hourly.isEmpty
                      ? const Center(
                        child: Text(
                          'Historique indisponible',
                          style: TextStyle(color: TvColors.muted),
                        ),
                      )
                      : TvHourlyChart(
                        samples: s.hourly,
                        contract: s.contract,
                        subMeterColors: extras?.subMeterColors ?? const {},
                        legendSize: 12,
                        budgetWh: EnergyAdvice.hourlyBudgetWh(s, extras),
                      ),
            ),
          ],
        ),
      );
    }
    TextStyle small(Color color) => TextStyle(fontSize: 11.5, color: color);
    return _card(
      padding: const EdgeInsets.fromLTRB(10, 10, 12, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 124,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.bolt, color: TvColors.focus, size: 28),
                const SizedBox(height: 2),
                Text('Électricité · 24 h', style: small(TvColors.muted)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    total == null
                        ? '—'
                        : '${tvNumber(total / 1000, decimals: 2)} kWh',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (s.dailyCostEur != null)
                  Text(
                    '${tvNumber(s.dailyCostEur!, decimals: 2)} €',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (s.dailyProductionWh != null)
                  Text(
                    'Produit ${tvNumber(s.dailyProductionWh! / 1000, decimals: 2)} kWh',
                    style: small(TvColors.solar),
                  ),
                const Spacer(),
                if (load != null) ...[
                  Text(
                    'Plancher ${tvNumber(load.watts)} W',
                    style: small(TvColors.muted),
                  ),
                  Text(
                    load.yearlyEur != null
                        ? '≈ ${tvNumber(load.yearlyEur!)} €/an'
                        : '≈ ${tvNumber(load.yearlyKWh)} kWh/an',
                    style: small(TvColors.muted),
                  ),
                ],
                Text(
                  'Relevé ${tvAge(s.timestamp)}',
                  style: small(TvColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child:
                snapshot.hourly.isEmpty
                    ? const Center(
                      child: Text(
                        'Historique indisponible',
                        style: TextStyle(color: TvColors.muted),
                      ),
                    )
                    : TvHourlyChart(
                      samples: snapshot.hourly,
                      contract: snapshot.contract,
                      subMeterColors: extras?.subMeterColors ?? const {},
                      legendSize: 12,
                      budgetWh: EnergyAdvice.hourlyBudgetWh(snapshot, extras),
                    ),
          ),
        ],
      ),
    );
  }

  Widget _figure(String value, String unit, double size) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: value,
          style: TextStyle(fontSize: size, fontWeight: FontWeight.w700),
        ),
        TextSpan(
          text: ' $unit',
          style: TextStyle(fontSize: size * 0.5, color: TvColors.muted),
        ),
      ],
    ),
  );
}

/// Les pastilles du kiosque : le tarif en cours, puis une par alerte.
///
/// Un appui déplie le bandeau complet dessous ; il se replie au second
/// appui, ou de lui-même au bout de 20 secondes. Une alerte grave se
/// déplie seule, une fois : en simple pastille, elle passerait inaperçue.
class PanelStatusStrip extends StatefulWidget {
  final ElectricityWeather? weather;
  final List<EnergyAlert> alerts;
  final bool compact;

  const PanelStatusStrip({
    super.key,
    required this.weather,
    required this.alerts,
    this.compact = false,
  });

  @override
  State<PanelStatusStrip> createState() => _PanelStatusStripState();
}

class _PanelStatusStripState extends State<PanelStatusStrip> {
  /// -1 : le tarif ; 0 et plus : une alerte ; null : tout replié.
  int? _open;
  Timer? _fold;

  /// Alertes graves déjà montrées, par titre : elles ne se redéplient pas
  /// à chaque relevé.
  static final Set<String> _shown = {};

  @override
  void initState() {
    super.initState();
    _openUrgent();
  }

  @override
  void didUpdateWidget(PanelStatusStrip old) {
    super.didUpdateWidget(old);
    if (_open != null && _open! >= widget.alerts.length) _open = null;
    _openUrgent();
  }

  @override
  void dispose() {
    _fold?.cancel();
    super.dispose();
  }

  void _openUrgent() {
    for (final (i, alert) in widget.alerts.indexed) {
      if (alert.level == AdviceLevel.danger && _shown.add(alert.title)) {
        _open = i;
        _arm();
        return;
      }
    }
  }

  void _arm() {
    _fold?.cancel();
    _fold = Timer(const Duration(seconds: 20), () {
      if (mounted) setState(() => _open = null);
    });
  }

  void _toggle(int index) {
    setState(() => _open = _open == index ? null : index);
    if (_open != null) _arm();
  }

  static Color _alertColor(AdviceLevel level) => switch (level) {
    AdviceLevel.danger => TvColors.bad,
    AdviceLevel.warning => TvColors.warn,
    AdviceLevel.info => TvColors.focus,
  };

  @override
  Widget build(BuildContext context) {
    final weather = widget.weather;
    final open = _open;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: widget.compact ? 40 : 48,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (weather != null)
                Flexible(
                  child: _WeatherChip(
                    weather: weather,
                    selected: open == -1,
                    onTap: () => _toggle(-1),
                  ),
                ),
              for (final (i, alert) in widget.alerts.take(3).indexed) ...[
                const SizedBox(width: 8),
                _AlertChip(
                  color: _alertColor(alert.level),
                  icon:
                      alert.level == AdviceLevel.info
                          ? Icons.info_outline
                          : Icons.warning_amber_rounded,
                  selected: open == i,
                  onTap: () => _toggle(i),
                ),
              ],
            ],
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          alignment: Alignment.topCenter,
          child:
              open == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: GestureDetector(
                      onTap: () => _toggle(open),
                      child:
                          open == -1 && weather != null
                              ? PanelWeatherBanner(weather: weather)
                              : PanelAlertCard(alert: widget.alerts[open]),
                    ),
                  ),
        ),
      ],
    );
  }
}

/// La pastille du tarif : sa couleur, le nom court, le prix, et le point
/// de couleur de demain en Tempo.
class _WeatherChip extends StatelessWidget {
  final ElectricityWeather weather;
  final bool selected;
  final VoidCallback onTap;

  const _WeatherChip({
    required this.weather,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = priceLevelColor(weather.level);
    final price = weather.pricePerKWh;
    final tomorrow = weather.tomorrow;
    return Material(
      color: Color.alphaBlend(color.withValues(alpha: 0.18), TvColors.panel),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(99),
        side: BorderSide(color: color, width: selected ? 2.5 : 1.5),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_priceLevelIcon(weather.level), color: color, size: 22),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  weather.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
              if (price != null) ...[
                const SizedBox(width: 10),
                Text(
                  '${tvNumber(price, decimals: 4)} €',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
              if (tomorrow != null) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Demain',
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: PanelWeatherBanner.dayColor(tomorrow),
                      shape: BoxShape.circle,
                      border: Border.all(color: TvColors.muted, width: 1),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              Icon(
                selected ? Icons.expand_less : Icons.expand_more,
                color: TvColors.muted,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La pastille d'une alerte : un rond de la couleur de sa gravité.
class _AlertChip extends StatelessWidget {
  final Color color;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _AlertChip({
    required this.color,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: Material(
        color: Color.alphaBlend(
          color.withValues(alpha: selected ? 0.4 : 0.22),
          TvColors.panel,
        ),
        shape: CircleBorder(side: BorderSide(color: color, width: 1.5)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Icon(icon, color: color, size: 24),
        ),
      ),
    );
  }
}

/// Le risque que le disjoncteur saute, en une ligne : son niveau, une
/// barre jusqu'à l'abonnement, et le conseil quand il faut agir.
class PanelRiskBar extends StatelessWidget {
  final CutRisk risk;
  final double size;

  /// Dans une colonne étroite (TV), « Risque » suffit.
  final bool short;

  const PanelRiskBar({
    super.key,
    required this.risk,
    this.size = 14,
    this.short = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = switch (risk.level) {
      RiskLevel.low => TvColors.ok,
      RiskLevel.medium => TvColors.warn,
      RiskLevel.high => TvColors.bad,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.electric_bolt, size: size + 4, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: short ? 'Risque : ' : 'Risque de coupure : ',
                      style: const TextStyle(color: TvColors.muted),
                    ),
                    TextSpan(
                      text: risk.label,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: color,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: size),
              ),
            ),
            Text(
              '${(risk.ratio * 100).round()} %'
              '${risk.phase == null ? '' : ' · phase ${risk.phase}'}',
              style: TextStyle(fontSize: size - 1, color: TvColors.muted),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: risk.ratio.clamp(0.0, 1.0),
            minHeight: size * 0.55,
            backgroundColor: TvColors.panelHigh,
            color: color,
          ),
        ),
        // Le conseil n'apparaît que quand il y a quelque chose à faire.
        if (risk.level != RiskLevel.low) ...[
          const SizedBox(height: 3),
          Text(risk.advice, style: TextStyle(fontSize: size - 1, color: color)),
        ],
      ],
    );
  }
}

/// Couleur d'un niveau de prix : vert quand c'est le moment, orange quand
/// il vaut mieux attendre, rouge quand il faut éviter.
Color priceLevelColor(PriceLevel level) => switch (level) {
  PriceLevel.surplus => TvColors.solar,
  PriceLevel.cheap => TvColors.ok,
  PriceLevel.flat => TvColors.focus,
  PriceLevel.normal => TvColors.warn,
  PriceLevel.expensive => const Color(0xFFE67E22),
  PriceLevel.peak => TvColors.bad,
};

IconData _priceLevelIcon(PriceLevel level) => switch (level) {
  PriceLevel.surplus => Icons.wb_sunny,
  PriceLevel.cheap => Icons.thumb_up_alt,
  PriceLevel.flat => Icons.horizontal_rule,
  PriceLevel.normal => Icons.schedule,
  PriceLevel.expensive => Icons.trending_up,
  PriceLevel.peak => Icons.do_not_disturb_on,
};

/// La météo de l'électricité : le tarif en cours en grand, son prix, le
/// conseil du moment, et la couleur de demain en Tempo.
class PanelWeatherBanner extends StatelessWidget {
  final ElectricityWeather weather;

  /// Sur un petit écran, le conseil cède la place.
  final bool compact;

  const PanelWeatherBanner({
    super.key,
    required this.weather,
    this.compact = false,
  });

  static String _day(TempoColor color) => switch (color) {
    TempoColor.blue => 'bleu',
    TempoColor.white => 'blanc',
    TempoColor.red => 'rouge',
  };

  static Color dayColor(TempoColor color) => switch (color) {
    TempoColor.blue => const Color(0xFF3498DB),
    TempoColor.white => const Color(0xFFECF0F1),
    TempoColor.red => TvColors.bad,
  };

  @override
  Widget build(BuildContext context) {
    final color = priceLevelColor(weather.level);
    final price = weather.pricePerKWh;
    final tomorrow = weather.tomorrow;
    return Container(
      padding: EdgeInsets.fromLTRB(12, compact ? 8 : 10, 14, compact ? 8 : 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.16), TvColors.panel),
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: color, width: 5)),
      ),
      child: Row(
        children: [
          Icon(
            _priceLevelIcon(weather.level),
            color: color,
            size: compact ? 24 : 30,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  weather.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 16 : 19,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 2),
                  Text(
                    weather.advice,
                    maxLines: 3,
                    style: const TextStyle(fontSize: 13.5, height: 1.25),
                  ),
                ],
              ],
            ),
          ),
          if (price != null || tomorrow != null) const SizedBox(width: 10),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (price != null)
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: tvNumber(price, decimals: 4),
                        style: TextStyle(
                          fontSize: compact ? 18 : 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const TextSpan(
                        text: ' €/kWh',
                        style: TextStyle(fontSize: 12, color: TvColors.muted),
                      ),
                    ],
                  ),
                ),
              if (tomorrow != null) ...[
                if (price != null) const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Demain ',
                      style: TextStyle(fontSize: 12, color: TvColors.muted),
                    ),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: dayColor(tomorrow),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _day(tomorrow),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Une alerte en tête de la vue Énergie : ce qui se passe, et quoi faire.
class PanelAlertCard extends StatelessWidget {
  final EnergyAlert alert;
  final bool compact;

  const PanelAlertCard({super.key, required this.alert, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final color = switch (alert.level) {
      AdviceLevel.danger => TvColors.bad,
      AdviceLevel.warning => TvColors.warn,
      AdviceLevel.info => TvColors.focus,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.22), TvColors.panel),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Row(
        children: [
          Icon(
            alert.level == AdviceLevel.info
                ? Icons.info_outline
                : Icons.warning_amber_rounded,
            color: color,
            size: compact ? 22 : 28,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  alert.title,
                  style: TextStyle(
                    fontSize: compact ? 15 : 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  alert.message,
                  maxLines: compact ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.25),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Appareils
// ---------------------------------------------------------------------------

class PanelDevicesView extends StatefulWidget {
  final BoxDevice box;
  final List<DeviceSnapshot> devices;
  final ValueChanged<List<DeviceSnapshot>> onChanged;

  const PanelDevicesView({
    super.key,
    required this.box,
    required this.devices,
    required this.onChanged,
  });

  @override
  State<PanelDevicesView> createState() => _PanelDevicesViewState();
}

class _PanelDevicesViewState extends State<PanelDevicesView> {
  final Map<String, String> _status = {};

  List<DeviceSnapshot> get _shown =>
      widget.devices.where((d) => !tvIsMeter(d)).toList();

  Future<void> _send(DeviceSnapshot device, DeviceAction action) async {
    setState(() => _status[device.key] = '${tvActionLabel(action.name)}…');
    final ok = await DeviceControlService.send(
      widget.box,
      device,
      action,
      mdnsResolver: resolveMdnsIP,
    );
    if (!mounted) return;
    setState(() => _status[device.key] = ok ? 'Envoyé' : 'Échec de l\'envoi');
    if (!ok) return;

    // Relectures espacées pendant le mouvement : la box ne sert d'elle-même
    // que la dernière valeur rapportée, parfois en retard.
    for (final delay in const [4, 8, 18]) {
      await Future<void>.delayed(Duration(seconds: delay));
      if (!mounted) return;
      final current = widget.devices.firstWhere(
        (d) => d.key == device.key,
        orElse: () => device,
      );
      for (final reading in current.readings) {
        await DeviceControlService.forceRead(
          widget.box,
          current,
          reading,
          mdnsResolver: resolveMdnsIP,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final devices = await DeviceControlService.fetchAll(
        widget.box,
        mdnsResolver: resolveMdnsIP,
      );
      if (!mounted) return;
      if (devices.isNotEmpty) widget.onChanged(devices);
    }
    if (mounted) setState(() => _status.remove(device.key));
  }

  Future<void> _openActions(DeviceSnapshot device) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: TvColors.panel,
      isScrollControlled: true,
      builder:
          (_) => _ActionsSheet(
            deviceKey: device.key,
            devices: () => widget.devices,
            status: () => _status[device.key],
            onAction: (action) => _send(device, action),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = _shown;
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        mainAxisExtent: 112,
      ),
      itemCount: devices.length,
      itemBuilder: (context, i) {
        final device = devices[i];
        return PanelTap(
          onTap: device.actions.isEmpty ? null : () => _openActions(device),
          child: _DeviceTile(device: device, status: _status[device.key]),
        );
      },
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final DeviceSnapshot device;
  final String? status;

  const _DeviceTile({required this.device, this.status});

  @override
  Widget build(BuildContext context) {
    final readings = tvShownReadings(device);
    final primary = readings.isEmpty ? null : readings.first;
    final isPosition = primary?.name == 'current_position';
    // En second, seulement une grandeur qui parle : les gabarits exposent
    // aussi des réglages du module (« Window covering type »).
    final secondary =
        readings.skip(1).where((r) => _plain.contains(r.name)).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          device.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            primary == null
                ? 'Pas de mesure'
                : tvSelfExplanatory.contains(primary.name)
                ? tvReadingValue(primary)
                : '${tvReadingLabel(primary.name)} ${tvReadingValue(primary)}',
            style: TextStyle(
              fontSize: primary == null ? 14 : 21,
              fontWeight: FontWeight.w700,
              color: primary == null ? TvColors.muted : TvColors.text,
            ),
          ),
        ),
        if (isPosition) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: (primary!.value! / 100).clamp(0, 1).toDouble(),
              minHeight: 5,
              backgroundColor: TvColors.panelHigh,
              color: TvColors.focus,
            ),
          ),
        ],
        const Spacer(),
        Text(
          status ??
              (secondary == null
                  ? ''
                  : '${tvReadingLabel(secondary.name)} ${tvReadingValue(secondary)}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: status == null ? TvColors.muted : TvColors.focus,
          ),
        ),
      ],
    );
  }
}

/// Lectures qu'on affiche en petit sous la grandeur principale.
const _plain = {
  'temperature',
  'Temperature',
  'local_temperature',
  'humidity',
  'Humidity',
  'battery',
  'Bat',
};

IconData _actionIcon(String name) => switch (name.toUpperCase()) {
  'UP' || 'OPEN' => Icons.keyboard_arrow_up,
  'DOWN' || 'CLOSE' => Icons.keyboard_arrow_down,
  'STOP' => Icons.stop,
  'ON' => Icons.power_settings_new,
  'OFF' => Icons.power_off_outlined,
  'TOGGLE' => Icons.swap_horiz,
  _ => Icons.play_arrow,
};

/// Commandes d'un appareil, en gros boutons. Le panneau se redessine chaque
/// seconde pour suivre la relecture : un volet qui monte voit sa position
/// bouger.
class _ActionsSheet extends StatefulWidget {
  final String deviceKey;
  final List<DeviceSnapshot> Function() devices;
  final String? Function() status;
  final ValueChanged<DeviceAction> onAction;

  const _ActionsSheet({
    required this.deviceKey,
    required this.devices,
    required this.status,
    required this.onAction,
  });

  @override
  State<_ActionsSheet> createState() => _ActionsSheetState();
}

class _ActionsSheetState extends State<_ActionsSheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = widget.devices();
    final device = devices.firstWhere(
      (d) => d.key == widget.deviceKey,
      orElse: () => devices.first,
    );
    final readings = tvShownReadings(device);
    final primary = readings.isEmpty ? null : readings.first;
    final status = widget.status();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    device.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (primary != null)
                  Text(
                    tvReadingValue(primary),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: TvColors.focus,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final action in device.buttons)
                  SizedBox(
                    width: 142,
                    height: 62,
                    child: PanelTap(
                      color: TvColors.panelHigh,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      onTap: () => widget.onAction(action),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(_actionIcon(action.name), size: 26),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              tvActionLabel(action.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            if (device.positionAction case final position?) ...[
              const SizedBox(height: 12),
              _PositionSlider(
                // Reparti de la position lue quand elle change.
                key: ValueKey('${device.key}@${primary?.value}'),
                initial:
                    primary?.name == 'current_position' ? primary?.value : null,
                onChosen:
                    (percent) => widget.onAction(position.withValue(percent)),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              status ?? 'Touchez une commande',
              style: TextStyle(
                fontSize: 14,
                color: status == null ? TvColors.muted : TvColors.focus,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Curseur de position d'un volet. La commande part quand le doigt se
/// lève : pendant le glissement, seul le pourcentage affiché bouge.
class _PositionSlider extends StatefulWidget {
  final double? initial;
  final ValueChanged<int> onChosen;

  const _PositionSlider({super.key, this.initial, required this.onChosen});

  @override
  State<_PositionSlider> createState() => _PositionSliderState();
}

class _PositionSliderState extends State<_PositionSlider> {
  late double _value = (widget.initial ?? 50).clamp(0, 100).toDouble();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      decoration: BoxDecoration(
        color: TvColors.panelHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Position',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '${_value.round()} %',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: TvColors.focus,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 8,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 14),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
              activeTrackColor: TvColors.focus,
              inactiveTrackColor: TvColors.panel,
              thumbColor: TvColors.text,
            ),
            child: Slider(
              value: _value,
              min: 0,
              max: 100,
              divisions: 100,
              onChanged: (v) => setState(() => _value = v),
              onChangeEnd: (v) => widget.onChosen(v.round()),
            ),
          ),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Fermé',
                style: TextStyle(fontSize: 12, color: TvColors.muted),
              ),
              Text(
                'Ouvert',
                style: TextStyle(fontSize: 12, color: TvColors.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Groupes d'actions
// ---------------------------------------------------------------------------

class PanelGroupsView extends StatefulWidget {
  final BoxDevice box;
  final List<ActionGroup> groups;

  const PanelGroupsView({super.key, required this.box, required this.groups});

  @override
  State<PanelGroupsView> createState() => _PanelGroupsViewState();
}

class _PanelGroupsViewState extends State<PanelGroupsView> {
  final Map<String, String> _status = {};

  Future<void> _run(ActionGroup group) async {
    setState(() => _status[group.key] = 'Lancement…');
    final result = await ActionGroupService.run(
      widget.box,
      group.name,
      mdnsResolver: resolveMdnsIP,
    );
    if (!mounted) return;
    setState(
      () =>
          _status[group.key] =
              result.ok
                  ? 'Lancé · ${result.sent} action${result.sent > 1 ? 's' : ''}'
                  : 'Échec',
    );
    await Future<void>.delayed(const Duration(seconds: 6));
    if (mounted) setState(() => _status.remove(group.key));
  }

  static Color? _parseColor(String hex) {
    final clean = hex.replaceFirst('#', '');
    if (clean.length != 6) return null;
    final value = int.tryParse(clean, radix: 16);
    return value == null ? null : Color(0xFF000000 | value);
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        mainAxisExtent: 118,
      ),
      itemCount: widget.groups.length,
      itemBuilder: (context, i) {
        final group = widget.groups[i];
        final tint = _parseColor(group.color) ?? TvColors.focus;
        final status = _status[group.key];
        return Opacity(
          opacity: group.enabled ? 1 : 0.5,
          child: PanelTap(
            padding: const EdgeInsets.all(8),
            onTap: group.enabled ? () => _run(group) : null,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox.square(
                  dimension: 38,
                  child:
                      group.iconPath != null
                          ? CustomPaint(
                            painter: TvIconPainter(group.iconPath!, tint),
                          )
                          : Center(
                            child: Text(
                              group.icon.isEmpty ? '▶' : group.icon,
                              style: TextStyle(fontSize: 26, color: tint),
                            ),
                          ),
                ),
                const SizedBox(height: 6),
                Text(
                  group.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (status != null || !group.enabled)
                  Text(
                    status ?? 'Désactivé',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: status == null ? TvColors.muted : TvColors.focus,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Thermostats
// ---------------------------------------------------------------------------

/// Une zone par page, qu'on fait glisser du doigt : la consigne se règle
/// avec deux gros boutons.
class PanelThermostatsView extends StatefulWidget {
  final BoxDevice box;
  final List<ThermostatZone> zones;
  final ValueChanged<List<ThermostatZone>> onChanged;

  /// Appelé quand on glisse au-delà de la première ou de la dernière zone,
  /// avec le sens du geste : −1 vers la vue précédente, +1 vers la suivante.
  final ValueChanged<int>? onEdge;

  const PanelThermostatsView({
    super.key,
    required this.box,
    required this.zones,
    required this.onChanged,
    this.onEdge,
  });

  @override
  State<PanelThermostatsView> createState() => _PanelThermostatsViewState();
}

class _PanelThermostatsViewState extends State<PanelThermostatsView> {
  final _controller = PageController();
  int _page = 0;

  /// Le geste en cours a-t-il déjà été passé à la vue voisine ?
  bool _handedOver = false;

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollStartNotification) _handedOver = false;
    if (n is OverscrollNotification &&
        n.dragDetails != null &&
        !_handedOver &&
        n.overscroll.abs() > 2) {
      _handedOver = true;
      widget.onEdge?.call(n.overscroll < 0 ? -1 : 1);
    }
    return false;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zones = widget.zones;
    return Column(
      children: [
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: PageView.builder(
              controller: _controller,
              itemCount: zones.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder:
                  (context, i) => _ZonePage(
                    // La clé garde l'écart de consigne en attente sur sa zone.
                    key: ValueKey(zones[i].key),
                    box: widget.box,
                    zone: zones[i],
                    onChanged: widget.onChanged,
                  ),
            ),
          ),
        ),
        if (zones.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < zones.length; i++)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page ? TvColors.text : TvColors.panelHigh,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ZonePage extends StatefulWidget {
  final BoxDevice box;
  final ThermostatZone zone;
  final ValueChanged<List<ThermostatZone>> onChanged;

  const _ZonePage({
    super.key,
    required this.box,
    required this.zone,
    required this.onChanged,
  });

  @override
  State<_ZonePage> createState() => _ZonePageState();
}

class _ZonePageState extends State<_ZonePage> {
  /// Écart de consigne pas encore envoyé : les appuis s'additionnent, et la
  /// valeur part une seconde après le dernier.
  double _pending = 0;
  Timer? _debounce;
  bool _busy = false;

  static const _gaugeMin = 5.0;
  static const _gaugeMax = 35.0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  double get _shownSetpoint =>
      ThermostatService.nextSetpoint(widget.zone.setpoint, _pending);

  void _step(double step) {
    setState(() => _pending += step);
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), _sendSetpoint);
  }

  Future<void> _sendSetpoint() async {
    final delta = _shownSetpoint - widget.zone.setpoint;
    if (delta == 0) {
      setState(() => _pending = 0);
      return;
    }
    await _command(
      () => ThermostatService.command(
        widget.box,
        widget.zone.name,
        delta: delta,
        mdnsResolver: resolveMdnsIP,
      ),
    );
  }

  Future<void> _command(Future<bool> Function() send) async {
    setState(() => _busy = true);
    final ok = await send();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _pending = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('La box n\'a pas pris la commande')),
      );
      return;
    }
    // La box régule en continu : relire tout de suite donnerait l'état
    // d'avant.
    await Future<void>.delayed(const Duration(seconds: 2));
    final zones = await ThermostatService.fetchAll(
      widget.box,
      mdnsResolver: resolveMdnsIP,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pending = 0;
    });
    if (zones.isNotEmpty) widget.onChanged(zones);
  }

  @override
  Widget build(BuildContext context) {
    final z = widget.zone;
    final heatColor = z.heating ? TvColors.heat : TvColors.cool;
    final color = z.active ? heatColor : heatColor.withValues(alpha: 0.45);
    double position(double t) => (t - _gaugeMin) / (_gaugeMax - _gaugeMin);

    final (stateLabel, stateColor) =
        z.forceMode == 2
            ? ('Arrêt', TvColors.muted)
            : z.active
            ? (z.heating ? 'Chauffe' : 'Refroidit', heatColor)
            : ('En attente', TvColors.muted);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  z.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: TvColors.muted,
                    ),
                  ),
                ),
              TvPill(stateLabel, stateColor),
            ],
          ),
          Expanded(
            child: Row(
              children: [
                _stepButton(Icons.remove, () => _step(-0.5)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: TvArcGauge(
                      ratio: position(_shownSetpoint),
                      color: color,
                      value: '${tvNumber(_shownSetpoint, decimals: 1)}°',
                      caption:
                          z.hasReading
                              ? 'mesuré ${tvNumber(z.temperature!, decimals: 1)} °C'
                              : 'pas de mesure',
                      marker: z.hasReading ? position(z.temperature!) : null,
                    ),
                  ),
                ),
                _stepButton(Icons.add, () => _step(0.5)),
              ],
            ),
          ),
          Row(
            children: [
              for (final (mode, label) in const [
                (0, 'Auto'),
                (1, 'Marche'),
                (2, 'Arrêt'),
              ]) ...[
                Expanded(
                  child: _modeChip(
                    label,
                    selected: z.forceMode == mode,
                    onTap:
                        () => _command(
                          () => ThermostatService.command(
                            widget.box,
                            z.name,
                            forceMode: mode,
                            mdnsResolver: resolveMdnsIP,
                          ),
                        ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: _modeChip(
                  'Hors-gel',
                  selected: z.frost,
                  onTap:
                      () => _command(
                        () => ThermostatService.command(
                          widget.box,
                          z.name,
                          toggleFrost: true,
                          mdnsResolver: resolveMdnsIP,
                        ),
                      ),
                ),
              ),
              if (z.reversible) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: _modeChip(
                    z.heating ? 'Froid' : 'Chaud',
                    selected: false,
                    onTap:
                        () => _command(
                          () => ThermostatService.command(
                            widget.box,
                            z.name,
                            heat: !z.heating,
                            mdnsResolver: resolveMdnsIP,
                          ),
                        ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _stepButton(IconData icon, VoidCallback onTap) => SizedBox.square(
    dimension: 68,
    child: PanelTap(
      color: TvColors.panelHigh,
      radius: 34,
      padding: EdgeInsets.zero,
      onTap: _busy ? null : onTap,
      child: Icon(icon, size: 34),
    ),
  );

  Widget _modeChip(
    String label, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 44,
      child: PanelTap(
        color: selected ? TvColors.text : TvColors.panelHigh,
        radius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        onTap: _busy ? null : onTap,
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: selected ? TvColors.background : TvColors.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

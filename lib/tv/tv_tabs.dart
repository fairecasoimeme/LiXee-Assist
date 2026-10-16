import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_drawing/path_drawing.dart';

import '../screens/home_screen.dart' show resolveMdnsIP;
import '../screens/webview_device_screen.dart';
import '../services/action_group_service.dart';
import '../services/box_client.dart';
import '../panel/panel_chart_detail.dart';
import '../panel/panel_views.dart'
    show PanelAlertCard, PanelRiskBar, PanelWeatherBanner;
import '../services/device_control_service.dart';
import '../services/energy_advice.dart';
import '../services/energy_detail_service.dart';
import '../services/thermostat_service.dart';
import '../services/widget_data_service.dart';
import 'tv_data.dart';
import 'tv_theme.dart';

// ---------------------------------------------------------------------------
// Énergie
// ---------------------------------------------------------------------------

class TvEnergyTab extends StatelessWidget {
  final LinkySnapshot snapshot;
  final EnergyExtras? extras;

  const TvEnergyTab({super.key, required this.snapshot, this.extras});

  @override
  Widget build(BuildContext context) {
    // Sur un grand écran, la météo de l'électricité et l'alerte du moment
    // tiennent en entier : pas besoin de pastilles à déplier.
    final weather = EnergyAdvice.weather(snapshot, extras);
    final alert = EnergyAdvice.alerts(snapshot, extras).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (weather != null || alert != null) ...[
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (weather != null)
                  Expanded(child: PanelWeatherBanner(weather: weather)),
                if (weather != null && alert != null) const SizedBox(width: 16),
                if (alert != null)
                  Expanded(child: PanelAlertCard(alert: alert)),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Expanded(child: _panels(context)),
      ],
    );
  }

  Widget _panels(BuildContext context) {
    final s = snapshot;
    final trend = s.hourlyTrendPct;
    final wide = s.threePhase || s.productionPowerVA != null;
    final risk = EnergyAdvice.cutRisk(s, extras);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: s.threePhase ? 10 : (wide ? 7 : 5),
          child: _Panel(
            title: 'Puissance',
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Triphasé : une jauge par phase, sans total. Producteur :
                // l'injection à côté, à l'échelle de l'abonnement.
                Expanded(
                  child: Row(
                    children: [
                      if (s.threePhase)
                        for (final (i, va) in s.phasePowersVA.indexed)
                          Expanded(
                            child: TvArcGauge(
                              ratio:
                                  (s.phaseLimitVA ?? 0) == 0
                                      ? 0
                                      : va / s.phaseLimitVA!,
                              color: TvColors.focus,
                              value: tvNumber(va),
                              caption: 'Phase ${i + 1}',
                              scaleText: true,
                            ),
                          )
                      else
                        Expanded(
                          child: TvArcGauge(
                            ratio:
                                s.subscribedPowerVA == null ||
                                        s.subscribedPowerVA == 0
                                    ? 0
                                    : (s.apparentPowerVA ?? 0) /
                                        s.subscribedPowerVA!,
                            color: TvColors.focus,
                            value: tvNumber(s.apparentPowerVA ?? 0),
                            caption:
                                s.subscribedPowerVA == null
                                    ? 'VA'
                                    : 'VA sur ${tvNumber(s.subscribedPowerVA!)}',
                          ),
                        ),
                      if (s.productionPowerVA != null)
                        Expanded(
                          child: TvArcGauge(
                            ratio:
                                (s.subscribedPowerVA ?? 0) == 0
                                    ? 0
                                    : s.productionPowerVA! /
                                        s.subscribedPowerVA!,
                            color: TvColors.solar,
                            value: tvNumber(s.productionPowerVA!),
                            caption: 'VA injectés',
                          ),
                        ),
                    ],
                  ),
                ),
                if (risk != null) ...[
                  const SizedBox(height: 8),
                  PanelRiskBar(risk: risk, size: 15, short: true),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          flex: 4,
          child: _Panel(
            title: 'Sur 24 h',
            // Selon la box, une ligne de production ou de tendance s'ajoute :
            // le contenu se réduit plutôt que de déborder.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _figure(
                    s.dailyTotalWh == null
                        ? '—'
                        : tvNumber(s.dailyTotalWh! / 1000, decimals: 2),
                    'kWh',
                    34,
                  ),
                  if (s.dailyCostEur != null)
                    _figure(tvNumber(s.dailyCostEur!, decimals: 2), '€', 26),
                  if (s.dailyProductionWh != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Produit ${tvNumber(s.dailyProductionWh! / 1000, decimals: 2)} kWh',
                      style: const TextStyle(
                        fontSize: 16,
                        color: TvColors.solar,
                      ),
                    ),
                  ],
                  if (trend != null) ...[
                    const SizedBox(height: 6),
                    _trend(trend),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    'Relevé ${tvAge(s.timestamp)}',
                    style: const TextStyle(fontSize: 14, color: TvColors.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          flex: 9,
          child: _Panel(
            title:
                s.hourly.isEmpty
                    ? 'Heure par heure'
                    : 'Heure par heure · OK pour le détail',
            child:
                s.hourly.isEmpty
                    ? const Center(
                      child: Text(
                        'Historique indisponible',
                        style: TextStyle(color: TvColors.muted),
                      ),
                    )
                    : Column(
                      children: [
                        Expanded(
                          // OK ouvre le graphe en plein écran, où les
                          // flèches passent d'une heure à l'autre.
                          child: TvFocusable(
                            focusScale: 1,
                            color: TvColors.panel,
                            focusedColor: TvColors.panelHigh,
                            padding: const EdgeInsets.all(6),
                            radius: BorderRadius.circular(10),
                            onSelect:
                                () => PanelChartDetail.open(
                                  context,
                                  s,
                                  extras,
                                  remote: true,
                                ),
                            child: TvHourlyChart(
                              samples: s.hourly,
                              contract: s.contract,
                              subMeterColors:
                                  extras?.subMeterColors ?? const {},
                            ),
                          ),
                        ),
                        if (extras?.utilities.isNotEmpty ?? false) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 62,
                            child: Row(
                              children: [
                                for (final (i, meter)
                                    in extras!.utilities.indexed) ...[
                                  if (i > 0) const SizedBox(width: 12),
                                  Expanded(
                                    child: TvFocusable(
                                      focusScale: 1,
                                      padding: EdgeInsets.zero,
                                      color: TvColors.panelHigh,
                                      radius: BorderRadius.circular(12),
                                      onSelect:
                                          meter.hourly.isEmpty
                                              ? null
                                              : () => PanelUtilityDetail.open(
                                                context,
                                                meter,
                                                remote: true,
                                              ),
                                      child: TvUtilityTile(meter: meter),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
          ),
        ),
      ],
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
          style: TextStyle(fontSize: size * 0.45, color: TvColors.muted),
        ),
      ],
    ),
  );

  /// Sous 2 %, l'écart est du bruit de mesure : on dit « stable ».
  Widget _trend(double pct) {
    final String text;
    final Color color;
    if (pct > 2) {
      text = '↑ ${pct.round()} % vs heure précédente';
      color = TvColors.bad;
    } else if (pct < -2) {
      text = '↓ ${(-pct).round()} % vs heure précédente';
      color = TvColors.ok;
    } else {
      text = '→ stable';
      color = TvColors.muted;
    }
    return Text(text, style: TextStyle(fontSize: 15, color: color));
  }
}

class _Panel extends StatelessWidget {
  final String title;
  final Widget child;

  const _Panel({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: TvColors.panel,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, color: TvColors.muted),
          ),
          const SizedBox(height: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Jauge en arc de 270°, ouverte en bas, comme sur les widgets.
class TvArcGauge extends StatelessWidget {
  final double ratio;
  final Color color;
  final String value;
  final String caption;

  /// Position d'un repère sur l'arc (0 à 1), par exemple la température
  /// mesurée face à la consigne.
  final double? marker;

  /// Le texte grandit avec la jauge, au lieu de garder la taille prévue
  /// pour la TV : sur un panneau, la jauge occupe parfois tout l'écran.
  final bool scaleText;

  const TvArcGauge({
    super.key,
    required this.ratio,
    required this.color,
    required this.value,
    required this.caption,
    this.marker,
    this.scaleText = false,
  });

  @override
  Widget build(BuildContext context) {
    // Carré centré dans la place disponible : un AspectRatio sous des
    // contraintes serrées (dans un Expanded) cède, et l'arc devient ovale.
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 260.0,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 260.0,
        );
        return Center(
          child: SizedBox.square(dimension: side, child: _gauge(side)),
        );
      },
    );
  }

  Widget _gauge(double side) {
    final valueSize = scaleText ? (side * 0.2).clamp(40.0, 96.0) : 40.0;
    final captionSize = scaleText ? (side * 0.058).clamp(13.0, 26.0) : 13.0;
    return CustomPaint(
      painter: _ArcPainter(ratio.clamp(0, 1).toDouble(), color, marker),
      // Marge intérieure : le texte ne doit pas chevaucher l'arc.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: valueSize,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                caption,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: captionSize, color: TvColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  final double ratio;
  final Color color;
  final double? marker;

  _ArcPainter(this.ratio, this.color, this.marker);

  static const _start = math.pi * 0.75;
  static const _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.08;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final track =
        Paint()
          ..color = TvColors.panelHigh
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _start, _sweep, false, track);
    if (ratio > 0) {
      // Bout droit à l'avant, arrondi au départ seulement : avec deux bouts
      // arrondis, une faible valeur se réduisait à une pastille, qui ne
      // disait plus où s'arrêtait la mesure.
      canvas.drawArc(
        rect,
        _start,
        _sweep * ratio,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.butt,
      );
      canvas.drawCircle(
        Offset(
          rect.center.dx + rect.width / 2 * math.cos(_start),
          rect.center.dy + rect.width / 2 * math.sin(_start),
        ),
        stroke / 2,
        Paint()..color = color,
      );
    }
    if (marker != null) {
      final angle = _start + _sweep * marker!.clamp(0, 1);
      final center = rect.center;
      final radius = rect.width / 2;
      canvas.drawCircle(
        Offset(
          center.dx + radius * math.cos(angle),
          center.dy + radius * math.sin(angle),
        ),
        stroke * 0.42,
        Paint()..color = TvColors.text,
      );
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.ratio != ratio || old.color != color || old.marker != marker;
}

/// Une série du graphe : un index tarifaire ou un sous-compteur.
class TvEnergySeries {
  final String label;
  final Color color;

  /// Énergie de la série pour une heure, en Wh.
  final int Function(HourlySample) wh;

  const TvEnergySeries(this.label, this.color, this.wh);
}

/// Couleur d'un index tarifaire. En Tempo, celle du jour : bleu, blanc,
/// rouge, plus claire en heures creuses. Ailleurs, les heures creuses dans
/// le bleu de l'application et les heures pleines plus soutenues.
Color tvTariffColor(int attribute, String? contract) {
  final c = (contract ?? '').toUpperCase();
  final rank = (attribute - 256) ~/ 2;
  const tempo = [
    Color(0xFF5DADE2),
    Color(0xFF2E86C1),
    Color(0xFFECF0F1),
    Color(0xFFAAB7B8),
    Color(0xFFF1948A),
    Color(0xFFE74C3C),
  ];
  const others = [
    TvColors.focus,
    Color(0xFF1F6FB5),
    Color(0xFF7F8C8D),
    Color(0xFFBDC3C7),
    Color(0xFFE74C3C),
    Color(0xFFC0392B),
    Color(0xFFF5B041),
    Color(0xFFD35400),
    Color(0xFF8E44AD),
    Color(0xFFA569BD),
  ];
  final palette = c.contains('BBR') || c.contains('TEMPO') ? tempo : others;
  return rank >= 0 && rank < palette.length ? palette[rank] : TvColors.muted;
}

/// Les séries présentes sur 24 h : les index tarifaires dans leur ordre,
/// puis les sous-compteurs, dans la couleur choisie sur la box.
List<TvEnergySeries> tvEnergySeries(
  List<HourlySample> samples, {
  String? contract,
  Map<String, int> subMeterColors = const {},
}) {
  const spare = [
    Color(0xFFF5B041),
    Color(0xFF9B59B6),
    Color(0xFF1ABC9C),
    Color(0xFFE67E22),
    Color(0xFFEC7063),
  ];
  final attributes =
      <int>{for (final s in samples) ...s.tariffs.keys}.toList()..sort();
  final meters = <String>{for (final s in samples) ...s.subMeters.keys};
  return [
    for (final attribute in attributes)
      TvEnergySeries(
        tariffLabel(attribute, contract),
        tvTariffColor(attribute, contract),
        (s) => s.tariffs[attribute] ?? 0,
      ),
    for (final (i, name) in meters.indexed)
      TvEnergySeries(
        name,
        subMeterColors[name] == null
            ? spare[i % spare.length]
            : Color(0xFF000000 | subMeterColors[name]!),
        (s) => s.subMeters[name] ?? 0,
      ),
  ];
}

/// Graphe des 24 dernières heures, empilé par tarif et par sous-compteur.
/// L'heure en cours, partielle, est la dernière barre, plus appuyée ;
/// l'injection, en vert, descend sous l'axe.
class TvHourlyChart extends StatelessWidget {
  final List<HourlySample> samples;

  /// Contrat du compteur, qui donne leur nom aux index tarifaires.
  final String? contract;
  final Map<String, int> subMeterColors;

  /// Corps des heures ; la légende est un cran en dessous.
  final double legendSize;

  /// Le budget du mois rapporté à l'heure, en Wh : une ligne pointillée.
  final double? budgetWh;

  /// Barre mise en avant, les autres pâlissent ; `null` : aucune.
  final int? selected;

  /// Appelé avec l'indice de la barre touchée ou glissée sous le doigt.
  final ValueChanged<int>? onSelect;

  /// Nombre d'heures écrites sous l'axe, la première et la dernière
  /// comprises.
  final int hourMarks;

  const TvHourlyChart({
    super.key,
    required this.samples,
    this.contract,
    this.subMeterColors = const {},
    this.legendSize = 14,
    this.budgetWh,
    this.selected,
    this.onSelect,
    this.hourMarks = 4,
  });

  @override
  Widget build(BuildContext context) {
    final count = hourMarks.clamp(2, samples.length);
    final marks = [
      for (var i = 0; i < count; i++)
        (i * (samples.length - 1) / (count - 1)).round(),
    ];
    final series = tvEnergySeries(
      samples,
      contract: contract,
      subMeterColors: subMeterColors,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final chart = CustomPaint(
                size: Size.infinite,
                painter: _BarsPainter(
                  samples,
                  series,
                  budgetWh,
                  legendSize,
                  selected,
                ),
              );
              final select = onSelect;
              if (select == null) return chart;
              // La barre sous le doigt, d'après la position dans la zone
              // des barres, à droite des graduations.
              void pick(Offset at) {
                final left = _BarsPainter.gutter(legendSize);
                final slot = (constraints.maxWidth - left) / samples.length;
                if (slot <= 0) return;
                select(
                  ((at.dx - left) / slot).floor().clamp(0, samples.length - 1),
                );
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => pick(d.localPosition),
                onHorizontalDragUpdate: (d) => pick(d.localPosition),
                child: chart,
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: EdgeInsets.only(left: _BarsPainter.gutter(legendSize)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final (i, index) in marks.indexed)
                Text(
                  '${samples[index].hour}h',
                  style: TextStyle(
                    fontSize: legendSize,
                    color:
                        i == marks.length - 1 ? TvColors.focus : TvColors.muted,
                  ),
                ),
            ],
          ),
        ),
        // Une seule série n'a rien à distinguer : la légende ne dirait que
        // ce que le total dit déjà.
        if (series.length > 1) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: legendSize,
            runSpacing: 2,
            children: [
              for (final entry in series)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: legendSize * 0.7,
                      height: legendSize * 0.7,
                      decoration: BoxDecoration(
                        color: entry.color,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    SizedBox(width: legendSize * 0.4),
                    Text(
                      '${entry.label} ${tvNumber(samples.fold<int>(0, (sum, s) => sum + entry.wh(s)) / 1000, decimals: 1)} kWh',
                      style: TextStyle(
                        fontSize: legendSize - 1,
                        color: TvColors.muted,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<HourlySample> samples;
  final List<TvEnergySeries> series;
  final double? budgetWh;
  final double textSize;
  final int? selected;

  _BarsPainter(
    this.samples,
    this.series,
    this.budgetWh,
    this.textSize, [
    this.selected,
  ]);

  /// Largeur réservée aux graduations, à gauche des barres.
  static double gutter(double textSize) => textSize * 3.4;

  /// Un pas rond qui donne deux ou trois graduations sous [top] Wh.
  static int _step(int top) {
    for (final step in const [
      50,
      100,
      200,
      250,
      500,
      1000,
      2000,
      2500,
      5000,
      10000,
      20000,
    ]) {
      if (top / step <= 3) return step;
    }
    return 50000;
  }

  /// « 500 Wh », « 1 kWh », « 1,5 kWh ».
  static String _label(int wh) =>
      wh < 1000
          ? '$wh Wh'
          : '${tvNumber(wh / 1000, decimals: wh % 1000 == 0 ? 0 : 1)} kWh';

  @override
  void paint(Canvas canvas, Size size) {
    // La consommation monte au-dessus de l'axe, l'injection descend
    // dessous : les deux gardent la même échelle, et l'axe se place selon
    // la part de chacune.
    // La ligne du budget fixe aussi l'échelle : elle doit rester visible
    // quand la consommation est faible.
    final up = math.max(
      samples.fold<int>(1, (m, s) => math.max(m, s.wh)),
      ((budgetWh ?? 0) * 1.15).round(),
    );
    final down = samples.fold<int>(0, (m, s) => math.max(m, s.productionWh));
    final scale = size.height / (up + down);
    final axis = up * scale;

    // Deux ou trois graduations rondes, dans une gouttière à gauche.
    final left = gutter(textSize);
    final step = _step(up);
    final grid =
        Paint()
          ..color = TvColors.muted.withValues(alpha: 0.18)
          ..strokeWidth = 1;
    for (var value = step; value <= up; value += step) {
      final y = axis - value * scale;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), grid);
      final label = TextPainter(
        text: TextSpan(
          text: _label(value),
          style: TextStyle(fontSize: textSize - 2, color: TvColors.muted),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: left - 2);
      label.paint(canvas, Offset(left - 4 - label.width, y - label.height / 2));
    }

    canvas.save();
    canvas.translate(left, 0);
    final plot = Size(size.width - left, size.height);
    final slot = plot.width / samples.length;
    final width = slot * 0.62;

    if (down > 0) {
      canvas.drawLine(
        Offset(0, axis),
        Offset(size.width, axis),
        Paint()
          ..color = TvColors.muted.withValues(alpha: 0.35)
          ..strokeWidth = 1,
      );
    }

    // La barre choisie sur un fond clair, les autres en retrait.
    if (selected case final chosen?) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(chosen * slot, 0, slot, size.height),
          const Radius.circular(4),
        ),
        Paint()..color = TvColors.text.withValues(alpha: 0.08),
      );
    }

    for (final (i, s) in samples.indexed) {
      final current =
          selected == null ? i == samples.length - 1 : i == selected;
      final faded = selected != null && i != selected;
      final x = i * slot + (slot - width) / 2;

      // Les parts de l'heure, de l'axe vers le haut. Ce que le détail ne
      // couvre pas — un relevé plus ancien, sans détail — reste dans la
      // couleur d'origine, pour que la barre garde sa hauteur.
      final parts = <(Color, int)>[
        for (final entry in series)
          if (entry.wh(s) > 0) (entry.color, entry.wh(s)),
      ];
      final covered = parts.fold<int>(0, (sum, p) => sum + p.$2);
      if (s.wh > covered) parts.add((TvColors.focus, s.wh - covered));

      final total = math.min(math.max(s.wh, covered), up) * scale;
      canvas.save();
      canvas.clipRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, axis - total, width, total),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
      );
      var bottom = axis;
      for (final (color, wh) in parts) {
        final h = wh * scale;
        canvas.drawRect(
          Rect.fromLTWH(x, bottom - h, width, h),
          Paint()
            ..color = color.withValues(
              alpha: current ? 1 : (faded ? 0.4 : 0.72),
            ),
        );
        bottom -= h;
      }
      canvas.restore();

      if (s.productionWh > 0) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x, axis, width, s.productionWh * scale),
            bottomLeft: const Radius.circular(3),
            bottomRight: const Radius.circular(3),
          ),
          Paint()
            ..color = TvColors.solar.withValues(
              alpha: current ? 1 : (faded ? 0.4 : 0.7),
            ),
        );
      }
    }

    canvas.restore();

    final budget = budgetWh;
    if (budget != null && budget > 0) {
      final y = axis - budget * scale;
      final line =
          Paint()
            ..color = TvColors.warn
            ..strokeWidth = 1.5;
      for (var x = gutter(textSize); x < size.width; x += 10) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 6, size.width), y),
          line,
        );
      }
      final label = TextPainter(
        text: TextSpan(
          text: 'Budget',
          style: TextStyle(
            fontSize: textSize - 2,
            color: TvColors.warn,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(size.width - label.width, math.max(0, y - label.height - 2)),
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.samples != samples ||
      old.series.length != series.length ||
      old.budgetWh != budgetWh ||
      old.selected != selected;
}

/// Le compteur de gaz ou d'eau : son total sur 24 h, son coût, et ses
/// heures en petites barres.
class TvUtilityTile extends StatelessWidget {
  final UtilityMeter meter;

  /// Corps du total ; le libellé et l'icône en découlent.
  final double size;

  /// Largeur fixe du bloc de texte, pour aligner les petites barres sur
  /// le graphe de l'électricité quand les tuiles occupent toute la largeur.
  final double? textWidth;

  /// Une touche ouvre le graphe en plein écran.
  final bool expandable;

  const TvUtilityTile({
    super.key,
    required this.meter,
    this.size = 20,
    this.textWidth,
    this.expandable = false,
  });

  /// Couleur du gaz ou de l'eau, sur les tuiles et en plein écran.
  static Color colorOf(UtilityKind kind) =>
      kind == UtilityKind.gas ? _gas : _water;

  Widget _textBox(Widget child) =>
      textWidth == null
          ? Flexible(flex: 3, child: child)
          : SizedBox(width: textWidth, child: child);

  static const _gas = Color(0xFFE67E22);
  static const _water = Color(0xFF3498DB);

  @override
  Widget build(BuildContext context) {
    final gas = meter.kind == UtilityKind.gas;
    final color = gas ? _gas : _water;
    final total = meter.dailyTotal;
    final cost = meter.dailyCostEur;
    final tile = Container(
      padding: EdgeInsets.symmetric(
        horizontal: size * 0.6,
        vertical: size * 0.3,
      ),
      decoration: BoxDecoration(
        color: TvColors.panelHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            gas ? Icons.local_fire_department : Icons.water_drop,
            color: color,
            size: size * 1.3,
          ),
          SizedBox(width: size * 0.4),
          _textBox(
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    gas ? 'Gaz · 24 h' : 'Eau · 24 h',
                    style: TextStyle(
                      fontSize: size * 0.6,
                      color: TvColors.muted,
                    ),
                  ),
                  Text(
                    total == null
                        ? 'Aucun relevé'
                        : cost == null
                        ? amount(total)
                        : '${amount(total)} · ${tvNumber(cost, decimals: 2)} €',
                    style: TextStyle(
                      fontSize: total == null ? size * 0.75 : size,
                      fontWeight:
                          total == null ? FontWeight.w400 : FontWeight.w700,
                      color: total == null ? TvColors.muted : TvColors.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(width: size * 0.6),
          Expanded(
            flex: 2,
            child:
                total == null
                    ? const SizedBox()
                    : CustomPaint(
                      size: Size.infinite,
                      painter: _SparkPainter(
                        meter.hourly,
                        color,
                        // En pleine largeur, la gouttière du graphe de
                        // l'électricité, avec ses graduations.
                        axisTextSize: textWidth == null ? null : 12,
                        label: tick,
                      ),
                    ),
          ),
        ],
      ),
    );
    if (!expandable || total == null) return tile;
    // L'icône en surimpression, dans le coin : les barres restent alignées
    // sur celles de l'électricité.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => PanelUtilityDetail.open(context, meter),
      child: Stack(
        children: [
          tile,
          Positioned(
            top: 6,
            right: 6,
            child: Icon(
              Icons.open_in_full,
              size: size * 0.65,
              color: TvColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  /// Une graduation, dans l'unité du compteur.
  String tick(double value) {
    switch (meter.unit.toLowerCase()) {
      case 'wh':
        return value >= 1000
            ? '${tvNumber(value / 1000, decimals: value % 1000 == 0 ? 0 : 1)} kWh'
            : '${tvNumber(value)} Wh';
      case 'm3':
        return '${tvNumber(value, decimals: value < 1 ? 2 : (value < 10 ? 1 : 0))} m³';
      default:
        return '${tvNumber(value, decimals: value < 10 && value % 1 != 0 ? 1 : 0)} ${meter.unit}';
    }
  }

  /// La quantité dans son unité, avec assez de décimales pour une petite
  /// valeur ; les Wh passent en kWh.
  String amount(double value) {
    // L'unité est saisie à la main sur la box, sur deux caractères jusqu'en
    // v2.25 : « wH », « kW » (pour kWh coupé) ou « M3 » se rencontrent.
    var unit = meter.unit;
    switch (unit.toLowerCase()) {
      case 'wh':
        value /= 1000;
        unit = 'kWh';
      case 'kw' || 'kwh':
        unit = 'kWh';
      case 'm3':
        unit = 'm³';
    }
    final decimals = value < 10 ? 2 : (value < 100 ? 1 : 0);
    return '${tvNumber(value, decimals: decimals)} $unit';
  }
}

/// Le graphe du gaz ou de l'eau en grand : graduations, heures sous
/// l'axe, et une barre qu'on choisit du doigt.
class TvUtilityChart extends StatelessWidget {
  final UtilityMeter meter;
  final int? selected;
  final ValueChanged<int>? onSelect;
  final double textSize;
  final int hourMarks;

  const TvUtilityChart({
    super.key,
    required this.meter,
    this.selected,
    this.onSelect,
    this.textSize = 14,
    this.hourMarks = 7,
  });

  @override
  Widget build(BuildContext context) {
    final samples = meter.hourly;
    final tile = TvUtilityTile(meter: meter);
    final count = hourMarks.clamp(2, samples.length);
    final marks = [
      for (var i = 0; i < count; i++)
        (i * (samples.length - 1) / (count - 1)).round(),
    ];
    final left = _BarsPainter.gutter(textSize);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final chart = CustomPaint(
                size: Size.infinite,
                painter: _SparkPainter(
                  samples,
                  TvUtilityTile.colorOf(meter.kind),
                  axisTextSize: textSize,
                  label: tile.tick,
                  selected: selected,
                ),
              );
              final select = onSelect;
              if (select == null) return chart;
              void pick(Offset at) {
                final slot = (constraints.maxWidth - left) / samples.length;
                if (slot <= 0) return;
                select(
                  ((at.dx - left) / slot).floor().clamp(0, samples.length - 1),
                );
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => pick(d.localPosition),
                onHorizontalDragUpdate: (d) => pick(d.localPosition),
                child: chart,
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: EdgeInsets.only(left: left),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final (i, index) in marks.indexed)
                Text(
                  '${samples[index].hour}h',
                  style: TextStyle(
                    fontSize: textSize,
                    color:
                        i == marks.length - 1 ? TvColors.focus : TvColors.muted,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<UtilitySample> samples;
  final Color color;

  /// Corps des graduations ; `null` : pas de graduation, toute la largeur
  /// pour les barres.
  final double? axisTextSize;
  final String Function(double value) label;

  /// Barre mise en avant, les autres pâlissent.
  final int? selected;

  _SparkPainter(
    this.samples,
    this.color, {
    this.axisTextSize,
    required this.label,
    this.selected,
  });

  /// Un pas rond, quelle que soit l'unité, qui donne une ou deux
  /// graduations sous [top].
  static double _step(double top) {
    final raw = top / 2;
    final magnitude = math.pow(10, (math.log(raw) / math.ln10).floor());
    for (final factor in const [1, 2, 2.5, 5, 10]) {
      final step = factor * magnitude;
      if (step >= raw) return step.toDouble();
    }
    return (10 * magnitude).toDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final peak = samples.fold<double>(0, (m, s) => math.max(m, s.value));
    if (peak <= 0) return;
    final text = axisTextSize;
    final left = text == null ? 0.0 : _BarsPainter.gutter(text);
    if (text != null) {
      final step = _step(peak);
      final grid =
          Paint()
            ..color = TvColors.muted.withValues(alpha: 0.18)
            ..strokeWidth = 1;
      for (var value = step; value <= peak * 1.0001; value += step) {
        final y = size.height - size.height * value / peak;
        canvas.drawLine(Offset(left, y), Offset(size.width, y), grid);
        final painter = TextPainter(
          text: TextSpan(
            text: label(value),
            style: TextStyle(fontSize: text - 2, color: TvColors.muted),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: left - 2);
        painter.paint(
          canvas,
          Offset(
            left - 4 - painter.width,
            (y - painter.height / 2).clamp(0, size.height - painter.height),
          ),
        );
      }
    }
    final slot = (size.width - left) / samples.length;
    if (selected case final chosen?) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left + chosen * slot, 0, slot, size.height),
          const Radius.circular(4),
        ),
        Paint()..color = TvColors.text.withValues(alpha: 0.08),
      );
    }
    for (final (i, s) in samples.indexed) {
      final h = size.height * s.value / peak;
      final strong = selected == null ? i == samples.length - 1 : i == selected;
      canvas.drawRect(
        Rect.fromLTWH(
          left + i * slot + slot * 0.19,
          size.height - h,
          slot * 0.62,
          h,
        ),
        Paint()
          ..color = color.withValues(
            alpha: strong ? 1 : (selected == null ? 0.7 : 0.4),
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.samples != samples || old.selected != selected;
}

// ---------------------------------------------------------------------------
// Appareils
// ---------------------------------------------------------------------------

/// Noms d'action des gabarits, traduits pour l'écran.
String tvActionLabel(String name) => switch (name.toUpperCase()) {
  'UP' || 'OPEN' => 'Monter',
  'DOWN' || 'CLOSE' => 'Descendre',
  'STOP' => 'Stop',
  'ON' => 'Allumer',
  'OFF' => 'Éteindre',
  'TOGGLE' => 'Basculer',
  _ => name,
};

String tvReadingLabel(String name) => switch (name) {
  'current_position' => 'Position',
  'temperature' || 'Temperature' || 'local_temperature' => 'Température',
  'humidity' || 'Humidity' => 'Humidité',
  'battery' || 'Bat' => 'Batterie',
  _ => name
      .replaceAll('_', ' ')
      .replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase()),
};

/// Valeur mise en forme, avec « ouvert » et « fermé » aux deux bouts d'un
/// volet, à un point près : les modules s'arrêtent souvent à 99 ou 1 %.
String tvReadingValue(DeviceReading r) {
  final v = r.value;
  if (v == null) return '—';
  final text = v == v.roundToDouble() ? tvNumber(v) : tvNumber(v, decimals: 1);
  final unit = r.unit ?? (r.name == 'current_position' ? '%' : '');
  final spaced = unit.isEmpty ? text : '$text $unit';
  if (r.name == 'current_position') {
    if (v >= 99) return '$spaced · ouvert';
    if (v <= 1) return '$spaced · fermé';
  }
  return spaced;
}

/// Lectures qui valent la peine d'être montrées : une valeur, et pas un
/// réglage du module (« Window covering type », « Config status »).
List<DeviceReading> tvShownReadings(DeviceSnapshot d) =>
    d.readings.where((r) => r.value != null).toList();

/// Grandeurs qu'on comprend sans leur nom, à leur unité.
const tvSelfExplanatory = {
  'current_position',
  'temperature',
  'Temperature',
  'local_temperature',
};

/// Le compteur Linky a son propre onglet : le répéter ici n'apporte que des
/// libellés bruts.
bool tvIsMeter(DeviceSnapshot d) =>
    d.model.toLowerCase().startsWith('zlinky') ||
    d.label.toLowerCase().startsWith('zlinky');

class TvDevicesTab extends StatefulWidget {
  final BoxDevice box;
  final List<DeviceSnapshot> devices;
  final ValueChanged<List<DeviceSnapshot>> onChanged;

  const TvDevicesTab({
    super.key,
    required this.box,
    required this.devices,
    required this.onChanged,
  });

  @override
  State<TvDevicesTab> createState() => _TvDevicesTabState();
}

class _TvDevicesTabState extends State<TvDevicesTab> {
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

  /// Les commandes s'ouvrent dans un panneau : dans la tuile, elles la
  /// faisaient déborder, et Retour y quittait l'écran au lieu de les fermer.
  Future<void> _openActions(DeviceSnapshot device) {
    return showDialog<void>(
      context: context,
      builder:
          (dialogContext) => _ActionsDialog(
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
      clipBehavior: Clip.none,
      padding: const EdgeInsets.all(6),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 18,
        crossAxisSpacing: 18,
        mainAxisExtent: 172,
      ),
      itemCount: devices.length,
      itemBuilder: (context, i) {
        final device = devices[i];
        return TvFocusable(
          onSelect: device.actions.isEmpty ? null : () => _openActions(device),
          child: _DeviceSummary(device: device, status: _status[device.key]),
        );
      },
    );
  }
}

/// Nom, grandeur principale, une lecture secondaire : ce qui tient dans une
/// tuile lue de loin.
class _DeviceSummary extends StatelessWidget {
  final DeviceSnapshot device;
  final String? status;
  final bool large;

  const _DeviceSummary({required this.device, this.status, this.large = false});

  @override
  Widget build(BuildContext context) {
    final readings = tvShownReadings(device);
    final primary = readings.isEmpty ? null : readings.first;
    final secondary = readings.skip(1).take(large ? 3 : 1);
    final isPosition = primary?.name == 'current_position';
    final count = device.actions.length;

    return Column(
      mainAxisSize: large ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          device.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: large ? 24 : 19,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            primary == null
                ? 'Pas de mesure'
                // Position et température se lisent d'elles-mêmes ; une
                // batterie seule à « 100 % » ne dirait pas de quoi il s'agit.
                : tvSelfExplanatory.contains(primary.name)
                ? tvReadingValue(primary)
                : '${tvReadingLabel(primary.name)} ${tvReadingValue(primary)}',
            style: TextStyle(
              fontSize: primary == null ? 18 : (large ? 34 : 27),
              fontWeight: FontWeight.w700,
              color: primary == null ? TvColors.muted : TvColors.text,
            ),
          ),
        ),
        if (isPosition) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: (primary!.value! / 100).clamp(0, 1).toDouble(),
              minHeight: 6,
              backgroundColor: TvColors.panelHigh,
              color: TvColors.focus,
            ),
          ),
        ],
        for (final r in secondary)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${tvReadingLabel(r.name)} ${tvReadingValue(r)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: TvColors.muted),
            ),
          ),
        if (!large) ...[
          const Spacer(),
          Text(
            status ??
                (count == 0 ? '' : '$count commande${count > 1 ? 's' : ''}'),
            maxLines: 1,
            style: TextStyle(
              fontSize: 14,
              color: status == null ? TvColors.muted : TvColors.focus,
            ),
          ),
        ],
      ],
    );
  }
}

/// Panneau des commandes d'un appareil. Il se redessine chaque seconde pour
/// suivre la relecture en cours : un volet qui monte voit sa position bouger.
class _ActionsDialog extends StatefulWidget {
  final String deviceKey;
  final List<DeviceSnapshot> Function() devices;
  final String? Function() status;
  final ValueChanged<DeviceAction> onAction;

  const _ActionsDialog({
    required this.deviceKey,
    required this.devices,
    required this.status,
    required this.onAction,
  });

  @override
  State<_ActionsDialog> createState() => _ActionsDialogState();
}

class _ActionsDialogState extends State<_ActionsDialog> {
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
    final status = widget.status();
    return Dialog(
      backgroundColor: TvColors.panel,
      insetPadding: const EdgeInsets.symmetric(horizontal: 160, vertical: 60),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DeviceSummary(device: device, large: true),
            const SizedBox(height: 22),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final (i, action) in device.buttons.indexed)
                  TvFocusable(
                    autofocus: i == 0,
                    focusScale: 1.06,
                    color: TvColors.panelHigh,
                    focusedColor: TvColors.focus.withValues(alpha: 0.35),
                    radius: BorderRadius.circular(12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 12,
                    ),
                    onSelect: () => widget.onAction(action),
                    child: Text(
                      tvActionLabel(action.name),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            if (device.positionAction case final position?) ...[
              const SizedBox(height: 14),
              _TvPosition(
                key: ValueKey(
                  '${device.key}@${tvShownReadings(device).firstOrNull?.value}',
                ),
                initial:
                    tvShownReadings(device).firstOrNull?.name ==
                            'current_position'
                        ? tvShownReadings(device).firstOrNull?.value
                        : null,
                onChosen:
                    (percent) => widget.onAction(position.withValue(percent)),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              status ?? 'OK envoie la commande · Retour ferme',
              style: TextStyle(
                fontSize: 15,
                color: status == null ? TvColors.muted : TvColors.focus,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Position d'un volet à la télécommande : gauche et droite règlent le
/// pourcentage par pas de 5, OK l'envoie.
class _TvPosition extends StatefulWidget {
  final double? initial;
  final ValueChanged<int> onChosen;

  const _TvPosition({super.key, this.initial, required this.onChosen});

  @override
  State<_TvPosition> createState() => _TvPositionState();
}

class _TvPositionState extends State<_TvPosition> {
  late int _value = (widget.initial ?? 50).clamp(0, 100).round();

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final step =
        event.logicalKey == LogicalKeyboardKey.arrowRight
            ? 5
            : event.logicalKey == LogicalKeyboardKey.arrowLeft
            ? -5
            : 0;
    if (step == 0) return KeyEventResult.ignored;
    setState(() => _value = (_value + step).clamp(0, 100));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusScale: 1,
      color: TvColors.panelHigh,
      onKey: _onKey,
      onSelect: () => widget.onChosen(_value),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      child: Row(
        children: [
          const Text('Position', style: TextStyle(fontSize: 18)),
          const SizedBox(width: 18),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: _value / 100,
                minHeight: 8,
                backgroundColor: TvColors.panel,
                color: TvColors.focus,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Icon(Icons.chevron_left, color: TvColors.muted, size: 28),
          SizedBox(
            width: 76,
            child: Text(
              '$_value %',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          const Icon(Icons.chevron_right, color: TvColors.muted, size: 28),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Groupes d'actions
// ---------------------------------------------------------------------------

class TvGroupsTab extends StatefulWidget {
  final BoxDevice box;
  final List<ActionGroup> groups;

  const TvGroupsTab({super.key, required this.box, required this.groups});

  @override
  State<TvGroupsTab> createState() => _TvGroupsTabState();
}

class _TvGroupsTabState extends State<TvGroupsTab> {
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

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      clipBehavior: Clip.none,
      padding: const EdgeInsets.all(6),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 20,
        crossAxisSpacing: 20,
        mainAxisExtent: 210,
      ),
      itemCount: widget.groups.length,
      itemBuilder: (context, i) {
        final group = widget.groups[i];
        final tint = _parseColor(group.color) ?? TvColors.focus;
        final status = _status[group.key];
        return TvFocusable(
          onSelect: group.enabled ? () => _run(group) : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child:
                    group.iconPath != null
                        ? CustomPaint(
                          painter: TvIconPainter(group.iconPath!, tint),
                        )
                        : Center(
                          child: Text(
                            group.icon.isEmpty ? '▶' : group.icon,
                            style: TextStyle(fontSize: 40, color: tint),
                          ),
                        ),
              ),
              const SizedBox(height: 12),
              Text(
                group.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                status ??
                    (group.enabled
                        ? '${group.actionCount} action${group.actionCount > 1 ? 's' : ''}'
                        : 'Désactivé'),
                style: TextStyle(
                  fontSize: 14,
                  color: status == null ? TvColors.muted : TvColors.focus,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Color? _parseColor(String hex) {
    final clean = hex.replaceFirst('#', '');
    if (clean.length != 6) return null;
    final value = int.tryParse(clean, radix: 16);
    return value == null ? null : Color(0xFF000000 | value);
  }
}

/// Icône Material Design Icons, tracée depuis son chemin SVG (grille 24×24).
class TvIconPainter extends CustomPainter {
  final String data;
  final Color color;

  TvIconPainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    try {
      final path = parseSvgPathData(data);
      canvas.scale(size.width / 24, size.height / 24);
      canvas.drawPath(path, Paint()..color = color);
    } catch (_) {
      // Tracé illisible : la tuile garde son nom, sans icône.
    }
  }

  @override
  bool shouldRepaint(TvIconPainter old) =>
      old.data != data || old.color != color;
}

// ---------------------------------------------------------------------------
// Thermostats
// ---------------------------------------------------------------------------

class TvThermostatsTab extends StatelessWidget {
  final BoxDevice box;
  final List<ThermostatZone> zones;
  final ValueChanged<List<ThermostatZone>> onChanged;

  const TvThermostatsTab({
    super.key,
    required this.box,
    required this.zones,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      clipBehavior: Clip.none,
      padding: const EdgeInsets.all(6),
      itemCount: zones.length,
      separatorBuilder: (_, __) => const SizedBox(height: 24),
      itemBuilder:
          (context, i) =>
              _ZoneCard(box: box, zone: zones[i], onChanged: onChanged),
    );
  }
}

class _ZoneCard extends StatefulWidget {
  final BoxDevice box;
  final ThermostatZone zone;
  final ValueChanged<List<ThermostatZone>> onChanged;

  const _ZoneCard({
    required this.box,
    required this.zone,
    required this.onChanged,
  });

  @override
  State<_ZoneCard> createState() => _ZoneCardState();
}

class _ZoneCardState extends State<_ZoneCard> {
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

  KeyEventResult _onSetpointKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final step =
        event.logicalKey == LogicalKeyboardKey.arrowRight
            ? 0.5
            : event.logicalKey == LogicalKeyboardKey.arrowLeft
            ? -0.5
            : 0.0;
    if (step == 0) return KeyEventResult.ignored;
    setState(() => _pending += step);
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), _sendSetpoint);
    return KeyEventResult.handled;
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

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: TvColors.panel,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 230,
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
          const SizedBox(width: 40),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      z.name,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 16),
                    TvPill(stateLabel, stateColor),
                    if (z.frost) ...[
                      const SizedBox(width: 8),
                      const TvPill('Hors-gel', TvColors.cool),
                    ],
                    if (_busy) ...[
                      const SizedBox(width: 16),
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: TvColors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 18),
                TvFocusable(
                  autofocus: false,
                  focusScale: 1,
                  color: TvColors.panelHigh,
                  onKey: _onSetpointKey,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      const Text('Consigne', style: TextStyle(fontSize: 18)),
                      const Spacer(),
                      const Icon(
                        Icons.chevron_left,
                        color: TvColors.muted,
                        size: 32,
                      ),
                      Text(
                        '${tvNumber(_shownSetpoint, decimals: 1)} °C',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        color: TvColors.muted,
                        size: 32,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final (mode, label) in const [
                      (0, 'Auto'),
                      (1, 'Marche'),
                      (2, 'Arrêt'),
                    ])
                      _modeChip(
                        label,
                        selected: z.forceMode == mode,
                        onSelect:
                            () => _command(
                              () => ThermostatService.command(
                                widget.box,
                                z.name,
                                forceMode: mode,
                                mdnsResolver: resolveMdnsIP,
                              ),
                            ),
                      ),
                    if (z.reversible)
                      _modeChip(
                        z.heating ? 'Passer en froid' : 'Passer en chaud',
                        selected: false,
                        onSelect:
                            () => _command(
                              () => ThermostatService.command(
                                widget.box,
                                z.name,
                                heat: !z.heating,
                                mdnsResolver: resolveMdnsIP,
                              ),
                            ),
                      ),
                    _modeChip(
                      'Hors-gel',
                      selected: z.frost,
                      onSelect:
                          () => _command(
                            () => ThermostatService.command(
                              widget.box,
                              z.name,
                              toggleFrost: true,
                              mdnsResolver: resolveMdnsIP,
                            ),
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const TvHints([
                  (
                    '← →',
                    'Consigne ±0,5 °C, envoyée 1 s après le dernier appui',
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeChip(
    String label, {
    required bool selected,
    required VoidCallback onSelect,
  }) {
    return TvFocusable(
      focusScale: 1.06,
      color: selected ? TvColors.text : TvColors.panelHigh,
      radius: BorderRadius.circular(10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      onSelect: _busy ? null : onSelect,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: selected ? TvColors.background : TvColors.text,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Interface web
// ---------------------------------------------------------------------------

class TvWebTab extends StatefulWidget {
  final TvBox box;

  const TvWebTab({super.key, required this.box});

  @override
  State<TvWebTab> createState() => _TvWebTabState();
}

class _TvWebTabState extends State<TvWebTab> {
  bool _opening = false;
  String? _error;

  Future<void> _open() async {
    setState(() {
      _opening = true;
      _error = null;
    });
    final found = await TvData.reachableRoute(widget.box.device);
    if (!mounted) return;
    setState(() => _opening = false);
    if (found == null) {
      setState(() => _error = 'La box ne répond pas.');
      return;
    }
    final (candidate, route) = found;
    final device = widget.box.device;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => WebViewDeviceScreen(
              deviceEntry: widget.box.entry,
              url: route.baseUrl,
              isFallback: candidate != device.primaryUrl,
              hasFallback: device.fallbackUrl?.isNotEmpty ?? false,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Pour la configuration avancée de la box. Les flèches passent '
              'd\'un bouton ou d\'un champ au suivant ; OK maintenu bascule '
              'sur un pointeur libre.',
              style: TextStyle(fontSize: 18, color: TvColors.muted),
            ),
            const SizedBox(height: 24),
            TvFocusable(
              onSelect: _opening ? null : _open,
              color: TvColors.focus.withValues(alpha: 0.2),
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _opening
                      ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                      : const Icon(Icons.open_in_browser, size: 26),
                  const SizedBox(width: 14),
                  const Text(
                    'Ouvrir l\'interface web',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: const TextStyle(fontSize: 16, color: TvColors.bad),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

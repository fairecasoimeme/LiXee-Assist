import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/energy_advice.dart';
import '../services/energy_detail_service.dart';
import '../services/widget_data_service.dart';
import '../tv/tv_tabs.dart';
import '../tv/tv_theme.dart';

/// Comment passer d'une heure à l'autre : au doigt, ou aux flèches de la
/// télécommande sur une TV.
Widget _hint(bool remote) => Text(
  remote
      ? 'Flèches gauche et droite pour voir une autre heure, Retour pour '
          'fermer.'
      : 'Touche une barre, ou glisse le doigt, pour voir une autre heure.',
  style: const TextStyle(fontSize: 12, color: TvColors.muted),
);

/// Le graphe des 24 dernières heures en plein écran : une barre touchée
/// (ou choisie aux flèches de la télécommande) se détaille, tarif par
/// tarif, sous-compteur par sous-compteur, comparée à l'heure habituelle
/// et au budget.
class PanelChartDetail extends StatefulWidget {
  final LinkySnapshot snapshot;
  final EnergyExtras? extras;

  /// Ouverte depuis la TV : on la parcourt à la télécommande.
  final bool remote;

  const PanelChartDetail({
    super.key,
    required this.snapshot,
    this.extras,
    this.remote = false,
  });

  /// Ouvre la page par-dessus le kiosque.
  static Future<void> open(
    BuildContext context,
    LinkySnapshot snapshot,
    EnergyExtras? extras, {
    bool remote = false,
  }) {
    if (snapshot.hourly.isEmpty) return Future.value();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder:
            (_) => PanelChartDetail(
              snapshot: snapshot,
              extras: extras,
              remote: remote,
            ),
      ),
    );
  }

  @override
  State<PanelChartDetail> createState() => _PanelChartDetailState();
}

class _PanelChartDetailState extends State<PanelChartDetail> {
  /// La dernière heure complète au départ : l'heure en cours vient à
  /// peine de commencer.
  late int _selected = (widget.snapshot.hourly.length - 2).clamp(
    0,
    widget.snapshot.hourly.length - 1,
  );

  List<HourlySample> get _hours => widget.snapshot.hourly;

  void _move(int step) => setState(
    () => _selected = (_selected + step).clamp(0, _hours.length - 1),
  );

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final budget = EnergyAdvice.hourlyBudgetWh(s, widget.extras);
    final chart = TvHourlyChart(
      samples: _hours,
      contract: s.contract,
      subMeterColors: widget.extras?.subMeterColors ?? const {},
      legendSize: 14,
      budgetWh: budget,
      selected: _selected,
      onSelect: (i) => setState(() => _selected = i),
      hourMarks: 7,
    );
    final detail = _HourDetail(
      hours: _hours,
      index: _selected,
      contract: s.contract,
      subMeterColors: widget.extras?.subMeterColors ?? const {},
      budgetWh: budget,
      remote: widget.remote,
    );

    return Scaffold(
      backgroundColor: TvColors.background,
      body: SafeArea(
        child: Focus(
          autofocus: true,
          // Les flèches de la télécommande ou du clavier passent d'une
          // heure à l'autre.
          onKeyEvent: (_, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              _move(-1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _move(1);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth > constraints.maxHeight;
                final header = _header(context);
                if (wide) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header,
                      const SizedBox(height: 8),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 3, child: _panel(chart)),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: _panel(
                                SingleChildScrollView(child: detail),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    const SizedBox(height: 8),
                    Expanded(flex: 5, child: _panel(chart)),
                    const SizedBox(height: 12),
                    Expanded(
                      flex: 4,
                      child: _panel(SingleChildScrollView(child: detail)),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel(Widget child) => Container(
    padding: const EdgeInsets.fromLTRB(12, 14, 14, 10),
    decoration: BoxDecoration(
      color: TvColors.panel,
      borderRadius: BorderRadius.circular(14),
    ),
    child: child,
  );

  Widget _header(BuildContext context) {
    final s = widget.snapshot;
    final total = s.dailyTotalWh;
    final parts = [
      if (total != null) '${tvNumber(total / 1000, decimals: 2)} kWh',
      if (s.dailyCostEur != null) '${tvNumber(s.dailyCostEur!, decimals: 2)} €',
      if (s.dailyProductionWh != null)
        'produit ${tvNumber(s.dailyProductionWh! / 1000, decimals: 2)} kWh',
    ];
    return Row(
      children: [
        IconButton(
          tooltip: 'Fermer',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        const Icon(Icons.bolt, color: TvColors.focus, size: 26),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ta consommation, heure par heure',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              Text(
                '24 dernières heures${parts.isEmpty ? '' : ' · ${parts.join(' · ')}'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: TvColors.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Le détail d'une heure : ce qu'elle a consommé et coûté, par tarif et par
/// sous-compteur, et comment elle se situe.
class _HourDetail extends StatelessWidget {
  final List<HourlySample> hours;
  final int index;
  final String? contract;
  final Map<String, int> subMeterColors;
  final double? budgetWh;
  final bool remote;

  const _HourDetail({
    required this.hours,
    required this.index,
    required this.contract,
    required this.subMeterColors,
    required this.budgetWh,
    this.remote = false,
  });

  static String _kwh(int wh) =>
      wh < 1000
          ? '$wh Wh'
          : '${tvNumber(wh / 1000, decimals: wh < 10000 ? 2 : 1)} kWh';

  @override
  Widget build(BuildContext context) {
    final s = hours[index];
    final current = index == hours.length - 1;
    final end = (s.hour + 1) % 24;

    // Les parts de l'heure, dans les couleurs du graphe ; ce que le détail
    // ne couvre pas reste « autre ».
    final series = tvEnergySeries(
      hours,
      contract: contract,
      subMeterColors: subMeterColors,
    );
    final parts = [
      for (final entry in series)
        if (entry.wh(s) > 0) (entry.color, entry.label, entry.wh(s)),
    ];
    final covered = parts.fold<int>(0, (sum, p) => sum + p.$3);
    if (parts.isNotEmpty && s.wh > covered) {
      parts.add((TvColors.focus, 'Autre', s.wh - covered));
    }

    // L'heure habituelle : la moyenne des heures complètes.
    final complete = hours.sublist(0, hours.length - 1);
    final usual =
        complete.isEmpty
            ? null
            : complete.fold<int>(0, (sum, h) => sum + h.wh) / complete.length;
    final calmest =
        complete.isEmpty
            ? null
            : complete.map((h) => h.wh).reduce((a, b) => a < b ? a : b);

    final notes = <(IconData, Color, String)>[];
    if (current) {
      notes.add((
        Icons.schedule,
        TvColors.muted,
        'Heure en cours : elle n\'est pas finie, sa barre va encore monter.',
      ));
    } else if (usual != null && usual > 0) {
      final change = (s.wh - usual) / usual * 100;
      if (change >= 15) {
        notes.add((
          Icons.trending_up,
          TvColors.warn,
          '${change.round()} % de plus que ton heure moyenne '
              '(${_kwh(usual.round())}).',
        ));
      } else if (change <= -15) {
        notes.add((
          Icons.trending_down,
          TvColors.ok,
          '${(-change).round()} % de moins que ton heure moyenne '
              '(${_kwh(usual.round())}).',
        ));
      } else {
        notes.add((
          Icons.trending_flat,
          TvColors.muted,
          'Proche de ton heure moyenne (${_kwh(usual.round())}).',
        ));
      }
    }
    if (!current && calmest != null && s.wh == calmest && s.productionWh == 0) {
      notes.add((
        Icons.power_outlined,
        TvColors.focus,
        'Ton heure la plus calme : c\'est ce que ta maison consomme même '
            'quand rien ne semble allumé.',
      ));
    }
    if (budgetWh case final budget? when budget > 0 && !current) {
      notes.add(
        s.wh > budget
            ? (
              Icons.savings_outlined,
              TvColors.warn,
              'Au-dessus de ton budget, qui permet ${_kwh(budget.round())} '
                  'par heure en moyenne.',
            )
            : (
              Icons.savings_outlined,
              TvColors.ok,
              'Dans ton budget de ${_kwh(budget.round())} par heure.',
            ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'De ${s.hour} h à $end h${current ? ' · en cours' : ''}',
          style: const TextStyle(fontSize: 15, color: TvColors.muted),
        ),
        const SizedBox(height: 2),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: _kwh(s.wh),
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (s.costEur > 0)
                TextSpan(
                  text: '   ${tvNumber(s.costEur, decimals: 2)} €',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ),
        if (s.productionWh > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Injecté sur le réseau : ${_kwh(s.productionWh)}'
              '${s.revenueEur > 0 ? ' · +${tvNumber(s.revenueEur, decimals: 2)} €' : ''}',
              style: const TextStyle(fontSize: 14, color: TvColors.solar),
            ),
          ),
        if (parts.length > 1) ...[
          const SizedBox(height: 10),
          for (final (color, label, wh) in parts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(label, style: const TextStyle(fontSize: 14)),
                  ),
                  Text(
                    _kwh(wh),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      s.wh > 0 ? '${(wh * 100 / s.wh).round()} %' : '',
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        fontSize: 13,
                        color: TvColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (notes.isNotEmpty) const SizedBox(height: 8),
        for (final (icon, color, text) in notes)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(fontSize: 13.5, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        _hint(remote),
        ..._day(series),
      ],
    );
  }

  /// Les 24 heures d'un coup d'œil : l'heure la plus chargée, la plus
  /// calme, et la part de chaque tarif ou sous-compteur.
  List<Widget> _day(List<TvEnergySeries> series) {
    final complete = hours.sublist(0, hours.length - 1);
    if (complete.isEmpty) return const [];
    final total = hours.fold<int>(0, (sum, h) => sum + h.wh);
    final busiest = complete.reduce((a, b) => b.wh > a.wh ? b : a);
    final quiet = complete.where((h) => h.productionWh == 0).toList();
    final calmest =
        quiet.isEmpty ? null : quiet.reduce((a, b) => b.wh < a.wh ? b : a);
    String span(HourlySample h) => '${h.hour} h – ${(h.hour + 1) % 24} h';

    Widget row(
      Color? color,
      String label,
      String value, [
      String? share,
    ]) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          if (color != null) ...[
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          if (share != null)
            SizedBox(
              width: 52,
              child: Text(
                share,
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 13, color: TvColors.muted),
              ),
            ),
        ],
      ),
    );

    final shares =
        [
          for (final entry in series)
            (entry, hours.fold<int>(0, (sum, h) => sum + entry.wh(h))),
        ].where((e) => e.$2 > 0).toList();

    return [
      const SizedBox(height: 14),
      const Divider(height: 1, color: TvColors.panelHigh),
      const SizedBox(height: 10),
      const Text(
        'Sur ces 24 heures',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 4),
      row(
        TvColors.warn,
        'Heure la plus chargée · ${span(busiest)}',
        _kwh(busiest.wh),
      ),
      if (calmest != null)
        row(
          TvColors.ok,
          'Heure la plus calme · ${span(calmest)}',
          _kwh(calmest.wh),
        ),
      if (shares.length > 1)
        for (final (entry, wh) in shares)
          row(
            entry.color,
            entry.label,
            _kwh(wh),
            total > 0 ? '${(wh * 100 / total).round()} %' : null,
          ),
    ];
  }
}

/// Le graphe du gaz ou de l'eau en plein écran : chaque heure se détaille
/// d'une touche, avec son coût et sa place dans la journée.
class PanelUtilityDetail extends StatefulWidget {
  final UtilityMeter meter;

  /// Ouverte depuis la TV : on la parcourt à la télécommande.
  final bool remote;

  const PanelUtilityDetail({
    super.key,
    required this.meter,
    this.remote = false,
  });

  static Future<void> open(
    BuildContext context,
    UtilityMeter meter, {
    bool remote = false,
  }) {
    if (meter.hourly.isEmpty) return Future.value();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => PanelUtilityDetail(meter: meter, remote: remote),
      ),
    );
  }

  @override
  State<PanelUtilityDetail> createState() => _PanelUtilityDetailState();
}

class _PanelUtilityDetailState extends State<PanelUtilityDetail> {
  late int _selected = (widget.meter.hourly.length - 2).clamp(
    0,
    widget.meter.hourly.length - 1,
  );

  UtilityMeter get _meter => widget.meter;
  bool get _gas => _meter.kind == UtilityKind.gas;

  void _move(int step) => setState(
    () => _selected = (_selected + step).clamp(0, _meter.hourly.length - 1),
  );

  /// Coût d'une quantité ; `null` sans prix saisi. Le prix du gaz compté
  /// en Wh est celui du kWh, comme sur la box.
  double? _cost(double value) {
    if (_meter.price <= 0) return null;
    return (_meter.unit.toLowerCase() == 'wh' ? value / 1000 : value) *
        _meter.price;
  }

  @override
  Widget build(BuildContext context) {
    final tile = TvUtilityTile(meter: _meter);
    final color = TvUtilityTile.colorOf(_meter.kind);
    final total = _meter.dailyTotal ?? 0;
    final totalCost = _meter.dailyCostEur;
    final chart = TvUtilityChart(
      meter: _meter,
      selected: _selected,
      onSelect: (i) => setState(() => _selected = i),
    );
    final detail = _detail(tile, color);

    return Scaffold(
      backgroundColor: TvColors.background,
      body: SafeArea(
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              _move(-1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _move(1);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth > constraints.maxHeight;
                final header = Row(
                  children: [
                    IconButton(
                      tooltip: 'Fermer',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Icon(
                      _gas ? Icons.local_fire_department : Icons.water_drop,
                      color: color,
                      size: 26,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _gas
                                ? 'Ton gaz, heure par heure'
                                : 'Ton eau, heure par heure',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            '24 dernières heures · ${tile.amount(total)}'
                            '${totalCost == null ? '' : ' · ${tvNumber(totalCost, decimals: 2)} €'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: TvColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
                Widget panel(Widget child) => Container(
                  padding: const EdgeInsets.fromLTRB(12, 14, 14, 10),
                  decoration: BoxDecoration(
                    color: TvColors.panel,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: child,
                );
                if (wide) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header,
                      const SizedBox(height: 8),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 3, child: panel(chart)),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: panel(
                                SingleChildScrollView(child: detail),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    const SizedBox(height: 8),
                    Expanded(flex: 5, child: panel(chart)),
                    const SizedBox(height: 12),
                    Expanded(
                      flex: 4,
                      child: panel(SingleChildScrollView(child: detail)),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _detail(TvUtilityTile tile, Color color) {
    final hours = _meter.hourly;
    final s = hours[_selected];
    final current = _selected == hours.length - 1;
    final cost = _cost(s.value);
    final complete = hours.sublist(0, hours.length - 1);
    final usual =
        complete.isEmpty
            ? 0.0
            : complete.fold<double>(0, (sum, h) => sum + h.value) /
                complete.length;
    final busiest =
        complete.isEmpty
            ? null
            : complete.reduce((a, b) => b.value > a.value ? b : a);
    final idle = complete.where((h) => h.value <= 0).length;

    final notes = <(IconData, Color, String)>[];
    if (current) {
      notes.add((
        Icons.schedule,
        TvColors.muted,
        'Heure en cours : elle n\'est pas finie, sa barre va encore monter.',
      ));
    } else if (s.value <= 0) {
      notes.add((
        Icons.check_circle_outline,
        TvColors.ok,
        _gas
            ? 'Aucun gaz consommé pendant cette heure.'
            : 'Aucune eau '
                'consommée pendant cette heure.',
      ));
    } else if (usual > 0) {
      final change = (s.value - usual) / usual * 100;
      notes.add(
        change >= 15
            ? (
              Icons.trending_up,
              TvColors.warn,
              '${change.round()} % de plus que ton heure moyenne '
                  '(${tile.amount(usual)}).',
            )
            : change <= -15
            ? (
              Icons.trending_down,
              TvColors.ok,
              '${(-change).round()} % de moins que ton heure moyenne '
                  '(${tile.amount(usual)}).',
            )
            : (
              Icons.trending_flat,
              TvColors.muted,
              'Proche de ton heure moyenne (${tile.amount(usual)}).',
            ),
      );
    }

    TextStyle bold(double size) =>
        TextStyle(fontSize: size, fontWeight: FontWeight.w700);
    Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
          Text(value, style: bold(14)),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'De ${s.hour} h à ${(s.hour + 1) % 24} h${current ? ' · en cours' : ''}',
          style: const TextStyle(fontSize: 15, color: TvColors.muted),
        ),
        const SizedBox(height: 2),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: tile.amount(s.value),
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (cost != null && cost > 0)
                TextSpan(
                  text: '   ${tvNumber(cost, decimals: 2)} €',
                  style: bold(20),
                ),
            ],
          ),
        ),
        for (final (icon, c, text) in notes)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 18, color: c),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(fontSize: 13.5, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        _hint(widget.remote),
        if (busiest != null) ...[
          const SizedBox(height: 14),
          const Divider(height: 1, color: TvColors.panelHigh),
          const SizedBox(height: 10),
          const Text(
            'Sur ces 24 heures',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          line(
            'Heure la plus chargée · ${busiest.hour} h – ${(busiest.hour + 1) % 24} h',
            tile.amount(busiest.value),
          ),
          line('Heure moyenne', tile.amount(usual)),
          line('Heures sans consommation', '$idle sur ${complete.length}'),
          // De l'eau qui coule à toute heure : souvent une chasse d'eau ou
          // un robinet qui fuit.
          if (!_gas && idle == 0 && complete.length >= 12)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber,
                    size: 18,
                    color: TvColors.warn,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'L\'eau n\'a pas cessé de couler une seule heure. Si '
                      'personne n\'en utilise la nuit, vérifie la chasse '
                      'd\'eau et les robinets : une petite fuite coûte cher '
                      'sur l\'année.',
                      style: TextStyle(fontSize: 13.5, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

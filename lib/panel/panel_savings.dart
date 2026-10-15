import 'package:flutter/material.dart';

import '../services/energy_advice.dart';
import '../services/energy_detail_service.dart';
import '../services/tariff_compare.dart';
import '../services/widget_data_service.dart';
import '../tv/tv_theme.dart';
import 'panel_minicharts.dart';

/// Carte du kiosque, au fond des autres vues.
Widget _card({required Widget child, EdgeInsetsGeometry? padding}) => Container(
  padding: padding ?? const EdgeInsets.fromLTRB(14, 12, 14, 12),
  decoration: BoxDecoration(
    color: TvColors.panel,
    borderRadius: BorderRadius.circular(14),
  ),
  child: child,
);

/// Titre de carte, avec son icône.
Widget _title(IconData icon, String text, {Color color = TvColors.focus}) =>
    Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );

Widget _body(String text) => Padding(
  padding: const EdgeInsets.only(top: 6),
  child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.3)),
);

/// Le mois en cours : ce qui est consommé, ce que ça donnera au rythme
/// actuel, et l'objectif s'il y en a un. En euros si la box connaît ses
/// prix, sinon en kWh.
class PanelMonthCard extends StatelessWidget {
  final MonthOutlook month;

  /// Budget du mois réglé sur la box, en euros ; 0 sans budget.
  final int budget;

  /// Version courte, pour une tuile : sans l'aide pour fixer le budget.
  final bool compact;

  /// Les jours du mois écoulés, aujourd'hui compris : en barres dans la
  /// version complète.
  final List<DailySample> days;

  const PanelMonthCard({
    super.key,
    required this.month,
    this.budget = 0,
    this.compact = false,
    this.days = const [],
  });

  /// La carte, ou `null` si l'historique ne couvre pas encore le mois.
  /// Le budget est celui de la box (Config → Notifications), qui sert déjà
  /// à son alerte de dépassement ; il ne vaut qu'en euros.
  static Widget? of(
    EnergyExtras? extras, {
    bool compact = false,
    bool withDays = false,
  }) {
    final month = EnergyAdvice.month(extras, DateTime.now());
    if (month == null) return null;
    final budget = extras?.thresholds.monthBudgetEur;
    final now = DateTime.now();
    return PanelMonthCard(
      month: month,
      budget: month.euros && budget != null ? budget : 0,
      compact: compact,
      days: [
        if (withDays)
          for (final d in extras?.daily ?? const <DailySample>[])
            if (d.month == now.month && d.day <= now.day) d,
      ],
    );
  }

  String _amount(double value) =>
      month.euros
          ? '${tvNumber(value, decimals: value < 100 ? 2 : 0)} €'
          : '${tvNumber(value, decimals: value < 100 ? 1 : 0)} kWh';

  double _value(DailySample d) => month.euros ? d.costEur : d.wh / 1000;

  /// Chaque jour du mois, aujourd'hui en cours à droite, et ce que le
  /// budget permet par jour.
  List<Widget> _days() {
    final now = DateTime.now();
    final length = DateTime(now.year, now.month + 1, 0).day;
    final past = days.sublist(0, days.length - 1);
    final average =
        past.fold<double>(0, (sum, d) => sum + _value(d)) / past.length;
    final yesterday = _value(past.last);
    return [
      const SizedBox(height: 10),
      PanelMiniBars(
        values: [for (final d in days) _value(d)],
        highlight: days.length - 1,
        line: budget > 0 ? budget / length : null,
        lineLabel: budget > 0 ? 'Budget par jour' : null,
        labels: ['${days.first.day}/${days.first.month}', "aujourd'hui"],
      ),
      const SizedBox(height: 6),
      Text(
        'Ta journée moyenne ce mois-ci : ${_amount(average)} · '
        'hier : ${_amount(yesterday)}',
        style: const TextStyle(fontSize: 12.5, color: TvColors.muted),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final goal = budget;
    final over = goal > 0 && month.projected > goal;
    final color =
        goal == 0 ? TvColors.focus : (over ? TvColors.warn : TvColors.ok);
    final String note;
    if (goal == 0) {
      note =
          compact
              ? 'Prévu ≈ ${_amount(month.projected)}'
              : 'À ce rythme : ≈ ${_amount(month.projected)} sur le mois';
      // Sans budget, on dit où le fixer : c'est la box qui le porte.
    } else if (over) {
      note =
          'À ce rythme, tu dépasseras ton budget de '
          '${_amount(month.projected - goal)}';
    } else {
      note = 'À ce rythme, tu tiens ton budget de ${_amount(goal.toDouble())}';
    }
    return _card(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              const Text(
                'Ce mois-ci',
                style: TextStyle(fontSize: 13, color: TvColors.muted),
              ),
              const SizedBox(width: 10),
              Text(
                _amount(month.soFar),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (goal > 0)
                Text(
                  'Budget ${_amount(goal.toDouble())}',
                  style: const TextStyle(fontSize: 13, color: TvColors.muted),
                ),
            ],
          ),
          if (goal > 0) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: (month.soFar / goal).clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: TvColors.panelHigh,
                color: color,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: goal == 0 ? TvColors.muted : color,
            ),
          ),
          if (!compact && days.length >= 2) ..._days(),
          // Le budget se règle sur la box, où il sert aussi à son alerte
          // de dépassement : on dit où le trouver.
          if (goal == 0 && month.euros && !compact)
            const Text(
              'Fixe ton budget du mois dans la box : Config, Notifications, '
              'rubrique Consommation.',
              style: TextStyle(fontSize: 12, color: TvColors.muted),
            ),
        ],
      ),
    );
  }
}

/// Bouton « Rallumer » du délestage : la box exécute la demande au tour
/// suivant, d'où l'attente affichée.
class _RestoreButton extends StatefulWidget {
  final Future<void> Function() onRestore;

  const _RestoreButton({required this.onRestore});

  @override
  State<_RestoreButton> createState() => _RestoreButtonState();
}

class _RestoreButtonState extends State<_RestoreButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: TvColors.panelHigh,
          foregroundColor: TvColors.text,
          minimumSize: const Size.fromHeight(46),
        ),
        icon:
            _busy
                ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(Icons.power_settings_new),
        label: Text(_busy ? 'Rallumage…' : 'Rallumer maintenant'),
        onPressed:
            _busy
                ? null
                : () async {
                  setState(() => _busy = true);
                  await widget.onRestore();
                  if (mounted) setState(() => _busy = false);
                },
      ),
    );
  }
}

/// Vue « Économies » : ce qui se décide une fois et rapporte longtemps.
/// Le mois et son objectif, ce qui tourne en permanence, l'abonnement, et
/// la protection anti-coupure.
class PanelSavingsView extends StatelessWidget {
  final LinkySnapshot snapshot;
  final EnergyExtras? extras;
  final String box;

  /// Nom des appareils de la box, par adresse IEEE.
  final Map<String, String> deviceNames;

  /// Rallume les appareils coupés par le délestage ; `null` si la box ne
  /// le permet pas.
  final Future<void> Function()? onRestoreShedding;

  /// Sur une TV, les cartes se rangent sur deux colonnes : on ne fait pas
  /// défiler une liste à la télécommande.
  final bool twoColumns;

  const PanelSavingsView({
    super.key,
    required this.snapshot,
    required this.box,
    this.extras,
    this.deviceNames = const {},
    this.onRestoreShedding,
    this.twoColumns = false,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, int>>(
      future: PowerPeaks.load(box),
      builder: (context, peaks) {
        final cards = <Widget>[
          _source(),
          if (PanelMonthCard.of(extras, withDays: true) case final month?)
            month,
          if (_floor() case final floor?) floor,
          if (_subscription(peaks.data ?? const {}) case final card?) card,
          _TariffCard(snapshot: snapshot, extras: extras),
          _shedding(),
        ];
        final landscape =
            MediaQuery.sizeOf(context).width >
            MediaQuery.sizeOf(context).height * 1.25;
        if (twoColumns || landscape) {
          Widget column(Iterable<Widget> items) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, card) in items.indexed) ...[
                if (i > 0) const SizedBox(height: 12),
                card,
              ],
            ],
          );
          final half = (cards.length + 1) ~/ 2;
          return SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: column(cards.take(half))),
                const SizedBox(width: 16),
                Expanded(child: column(cards.skip(half))),
              ],
            ),
          );
        }
        return ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: cards.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, i) => cards[i],
        );
      },
    );
  }

  /// D'où viennent les chiffres : ceux de la maison, pas des moyennes.
  Widget _source() => _card(
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
    child: Row(
      children: [
        const Icon(Icons.home_outlined, color: TvColors.focus, size: 26),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Ces conseils sont calculés sur ta consommation réelle, relevée '
            'par ta box « $box » (${tvAge(snapshot.timestamp)}) : ce sont les '
            'chiffres de ta maison, pas des moyennes.',
            style: const TextStyle(fontSize: 13, height: 1.3),
          ),
        ),
      ],
    ),
  );

  /// Ce qui tourne en permanence, et comment le faire baisser.
  Widget? _floor() {
    final load = EnergyAdvice.baseLoad(snapshot, extras);
    if (load == null) return null;
    final yearly =
        load.yearlyEur != null
            ? '≈ ${tvNumber(load.yearlyEur!)} € par an'
            : '≈ ${tvNumber(load.yearlyKWh)} kWh par an';
    // Les heures complètes des dernières 24 h, la plus calme en avant.
    final hours =
        snapshot.hourly.length > 1
            ? snapshot.hourly.sublist(0, snapshot.hourly.length - 1)
            : snapshot.hourly;
    final calmest = hours.indexWhere(
      (h) => h.hour == load.hour && h.wh == load.watts,
    );
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(Icons.power_outlined, 'Ce qui ne s\'arrête jamais chez toi'),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${tvNumber(load.watts)} W',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(
                  text: '  en continu, $yearly',
                  style: const TextStyle(fontSize: 14, color: TvColors.muted),
                ),
              ],
            ),
          ),
          if (hours.length >= 12 && calmest >= 0) ...[
            const SizedBox(height: 10),
            PanelMiniBars(
              values: [for (final h in hours) h.wh.toDouble()],
              highlight: calmest,
              highlightColor: TvColors.ok,
              color: TvColors.muted,
              labels: ['${hours.first.hour} h', '${hours.last.hour + 1} h'],
            ),
            const SizedBox(height: 6),
            Text(
              'Ton heure la plus calme des dernières 24 h : de '
              '${load.hour} h à ${(load.hour! + 1) % 24} h, '
              '${tvNumber(load.watts)} W en moyenne.',
              style: const TextStyle(fontSize: 12.5, color: TvColors.muted),
            ),
          ],
          _body(
            'Même quand tout semble éteint, ta maison consomme : frigo, '
            'congélateur, box internet, appareils en veille. Pour faire '
            'baisser ce plancher : une multiprise à interrupteur pour la '
            'télé et l\'ordinateur, débrancher les chargeurs, vérifier le '
            'vieux congélateur.',
          ),
        ],
      ),
    );
  }

  /// L'abonnement comparé aux pics réellement atteints.
  Widget? _subscription(Map<String, int> peaks) {
    final check = EnergyAdvice.subscription(
      snapshot,
      peaks,
      summary: extras?.power,
    );
    if (check == null) return null;
    // En triphasé, le pic qui compte est celui de la phase la plus chargée.
    final phase = check.phasePeakVA;
    final peak =
        phase != null
            ? '${tvNumber(phase / 1000, decimals: 1)} kVA sur la phase la '
                'plus chargée, pour ${tvNumber(check.phaseLimitVA! / 1000, decimals: 1)} '
                'possibles'
            : '${tvNumber(check.peakVA / 1000, decimals: 1)} kVA';
    final often = switch (check.days30Over80) {
      final days? when days > 0 =>
        ' Ce mois-ci, $days ${days > 1 ? 'jours' : 'jour'} au-dessus de 80 %.',
      _ => '',
    };
    final limitVA =
        phase != null ? check.phaseLimitVA! : check.subscribedKVA * 1000;
    final peakVA = phase ?? check.peakVA;
    final meter = PanelPeakMeter(
      ratio: limitVA > 0 ? peakVA / limitVA : 0,
      leftLabel:
          '${phase != null ? 'Ta phase la plus chargée' : 'Ton pic'} : '
          '${tvNumber(peakVA / 1000, decimals: 1)} kVA',
      rightLabel:
          phase != null
              ? 'max ${tvNumber(limitVA / 1000, decimals: 1)} kVA par phase'
              : 'max ${check.subscribedKVA} kVA',
    );
    // Les pics jour par jour que le kiosque a relevés (monophasé : en
    // triphasé, ils portent sur le total, pas sur une phase).
    final days = (peaks.keys.toList()..sort());
    final recent = days.length > 30 ? days.sublist(days.length - 30) : days;
    final daily =
        phase == null && recent.length >= 5
            ? PanelMiniBars(
              values: [for (final d in recent) peaks[d]!.toDouble()],
              highlight: recent.length - 1,
              line: check.subscribedKVA * 1000.0,
              lineLabel: 'Ton abonnement',
              lineColor: TvColors.bad,
              labels: [
                '${recent.first.substring(8)}/${recent.first.substring(5, 7)}',
                "aujourd'hui",
              ],
            )
            : null;
    final String text;
    final Color color;
    if (check.tight) {
      color = TvColors.warn;
      text =
          'Ton abonnement est juste : ta consommation frôle souvent le '
          'maximum ($peak sur une minute).$often Évite d\'allumer en même '
          'temps les gros appareils (four, plaques, radiateurs), ou active la '
          'protection anti-coupure.';
    } else if (check.suggestedKVA case final suggested?) {
      color = TvColors.ok;
      text =
          'En ${check.days} jours, ta consommation n\'a jamais dépassé '
          '$peak. Un abonnement de $suggested kVA suffirait et coûterait '
          'moins cher : renseigne-toi auprès de ton fournisseur.';
    } else if (!check.measured) {
      color = TvColors.focus;
      text =
          'Ton compteur ne donne pas sa puissance maximale : le plus fort '
          "appel relevé quand l'écran tourne est de $peak. Ce n'est "
          'pas assez sûr pour te conseiller un abonnement plus petit.';
    } else if (check.days < SubscriptionCheck.minDays) {
      color = TvColors.focus;
      text =
          'Ton plus fort pic : $peak en ${check.days} '
          '${check.days > 1 ? 'jours' : 'jour'}. Le bilan sera prêt dans '
          '${SubscriptionCheck.minDays - check.days} jours : il dira si ton '
          'abonnement est bien taillé.';
    } else {
      color = TvColors.focus;
      text =
          'Ton plus fort pic : $peak en ${check.days} jours. Ton '
          'abonnement est bien taillé pour ta maison.';
    }
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(
            Icons.electric_meter_outlined,
            'Ton abonnement : ${check.subscribedKVA} kVA',
            color: color,
          ),
          const SizedBox(height: 10),
          meter,
          if (daily != null) ...[
            const SizedBox(height: 10),
            const Text(
              'Ton pic de puissance, jour par jour',
              style: TextStyle(fontSize: 12.5, color: TvColors.muted),
            ),
            const SizedBox(height: 4),
            daily,
          ],
          _body(text),
        ],
      ),
    );
  }

  /// La protection anti-coupure : le délestage, expliqué sans jargon.
  Widget _shedding() {
    final shedding = extras?.shedding;
    final devices = shedding?.devices ?? const <String>[];
    String name(String ieee) =>
        shedding?.names[ieee] ?? deviceNames[ieee] ?? ieee;
    final names = [for (final ieee in devices) name(ieee)];
    final active = devices.isNotEmpty;
    final cutting = shedding?.active == true;
    final cut = [
      for (final ieee in shedding?.cut ?? const <String>{}) name(ieee),
    ];
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(
            Icons.shield_outlined,
            active
                ? 'Protection anti-coupure : activée'
                : 'Protection anti-coupure : désactivée',
            color: active ? TvColors.ok : TvColors.muted,
          ),
          _body(
            'Quand tu allumes trop d\'appareils à la fois, le disjoncteur '
            'saute. La box peut l\'éviter : juste avant, elle éteint '
            'd\'elle-même un gros appareil qui peut attendre, comme un '
            'radiateur ou le chauffe-eau.',
          ),
          if (cutting) ...[
            _body(
              'En ce moment, la box a coupé '
              '${cut.isEmpty ? 'des appareils' : cut.join(', ')} pour que le '
              'disjoncteur ne saute pas.'
              '${(shedding?.restoreMinutes ?? 0) > 0 ? ' Elle les rallumera d\'elle-même quand la consommation aura baissé.' : ''}',
            ),
            if (onRestoreShedding != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _RestoreButton(onRestore: onRestoreShedding!),
              ),
          ] else if (active) ...[
            _body('Appareils concernés : ${names.join(', ')}.'),
            if (shedding?.lastAt case final at?)
              _body(
                shedding?.active == null
                    ? 'Dernière fois : $at. Les appareils coupés restent '
                        'éteints : pense à les rallumer.'
                    : 'Dernière fois : $at.',
              ),
          ] else
            _body(
              'Pour l\'activer, choisis ces appareils dans la box : menu '
              'Config, puis Linky, rubrique Délestage.',
            ),
        ],
      ),
    );
  }
}

/// Le tarif réglementé dans ses trois options, appliqué à la consommation
/// réelle de la maison : ce que chacune aurait coûté, et sur un an.
class _TariffCard extends StatelessWidget {
  final LinkySnapshot snapshot;
  final EnergyExtras? extras;

  const _TariffCard({required this.snapshot, this.extras});

  static String _eur(double value) =>
      '${tvNumber(value, decimals: value.abs() < 100 ? 2 : 0)} €';

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<DateTime, TempoColor>>(
      future: TempoCalendar.load(),
      builder: (context, colors) {
        final today = DateTime.now();
        final season = TempoCalendar.seasonCounts(
          colors.data ?? const {},
          TempoCalendar.seasonOf(DateTime(today.year - 1, today.month, 15)),
        );
        final result = TariffCompare.compare(
          snapshot: snapshot,
          daily: extras?.daily ?? const [],
          colors: colors.data ?? const {},
          season: season,
        );
        if (result == null) {
          return _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _title(Icons.compare_arrows, 'Et avec un autre tarif ?'),
                _body(
                  colors.connectionState == ConnectionState.waiting
                      ? 'Calcul en cours…'
                      : 'Il faut au moins une semaine de relevés, et la '
                          'puissance de ton abonnement, pour comparer les '
                          'tarifs.',
                ),
              ],
            ),
          );
        }
        return _comparison(result);
      },
    );
  }

  Widget _comparison(TariffComparison r) {
    final current = r.current;
    final mine = current == null ? null : r.costOf(current);
    final best = r.cheapest;
    final yearMine = current == null ? null : r.costOf(current, yearly: true);
    final yearBest = r.costOf(best.option, yearly: true);
    final paid = (extras?.daily ?? const <DailySample>[])
        .take((extras?.daily.length ?? 1) - 1)
        .fold<double>(0, (sum, d) => sum + d.costEur);

    final String verdict;
    final Color color;
    if (mine == null) {
      color = TvColors.focus;
      verdict =
          'Sur un an, l\'option la moins chère pour toi serait '
          '${best.option.label}, ≈ ${_eur(yearBest!.totalEur)}.';
    } else if (best.option == current || mine.totalEur - best.totalEur < 0.5) {
      color = TvColors.ok;
      verdict =
          'Ton option, ${current!.label}, est déjà la moins chère pour ta '
          'consommation.';
    } else {
      color = TvColors.warn;
      final saving = yearMine!.totalEur - yearBest!.totalEur;
      verdict =
          saving > 0
              ? r.offPeakSource == OffPeakSource.daily
                  ? 'Avec ${best.option.label}, tu paierais ≈ ${_eur(saving)} '
                      'de moins par an.'
                  // En Base, les heures sont supposées : une piste, pas
                  // une certitude.
                  : 'Avec ${best.option.label}, tu pourrais payer de l\'ordre '
                      'de ${_eur(saving)} de moins par an : une estimation, à '
                      'confirmer.'
              : 'Sur ces jours, ${best.option.label} aurait coûté moins '
                  'cher ; sur un an, avec l\'hiver, ce n\'est pas sûr.';
    }

    Widget row(OptionCost cost) {
      final isMine = cost.option == current;
      final isBest = cost.option == best.option;
      final diff = mine == null ? null : cost.totalEur - mine.totalEur;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              isBest ? Icons.star_rounded : Icons.circle,
              size: isBest ? 18 : 8,
              color: isBest ? TvColors.ok : TvColors.muted,
            ),
            SizedBox(width: isBest ? 6 : 11),
            Expanded(
              child: Text(
                '${cost.option.label}${isMine ? ' · ton option' : ''}'
                '${cost.kva != (snapshot.subscribedPowerVA! / 1000).round() ? ' (${cost.kva} kVA)' : ''}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isMine ? FontWeight.w800 : FontWeight.w400,
                ),
              ),
            ),
            Text(
              _eur(cost.totalEur),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            SizedBox(
              width: 74,
              child: Text(
                diff == null || isMine || diff.abs() < 0.01
                    ? ''
                    : '${diff > 0 ? '+' : '−'}${_eur(diff.abs())}',
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 13,
                  color: diff != null && diff < 0 ? TvColors.ok : TvColors.bad,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final notes = <String>[
      switch (r.offPeakSource) {
        OffPeakSource.daily =>
          'Tes heures creuses : ${(r.offPeakShare * 100).round()} % de ta '
              'consommation, d\'après les totaux de chaque jour.',
        OffPeakSource.lastDay =>
          'Tes heures creuses : ${(r.offPeakShare * 100).round()} % de ta '
              'consommation, mesurées sur les dernières 24 heures seulement.',
        OffPeakSource.assumed =>
          'En Base, ta box ne garde pas l\'heure de ta consommation : la part '
              'des heures creuses (${(r.offPeakShare * 100).round()} %) est '
              'estimée sur les dernières 24 heures, de 22 h à 6 h. Heures '
              'creuses et Tempo sont donc des estimations.',
      },
      if (r.redDays == 0)
        'Aucun jour rouge sur ces ${r.days} jours : le calcul sur un an en '
            'compte 22, l\'hiver. Si tu te chauffes à l\'électricité, ils '
            'coûteront plus que ça.'
      else
        'Sur ces jours : ${r.redDays} jour${r.redDays > 1 ? 's' : ''} rouge'
            '${r.redDays > 1 ? 's' : ''} et ${r.whiteDays} blanc'
            '${r.whiteDays > 1 ? 's' : ''} en Tempo.',
      if (r.costOf(TariffOption.base) == null)
        'L\'option Base n\'existe plus au-delà de 15 kVA.',
    ];

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(
            Icons.compare_arrows,
            'Et avec un autre tarif ?',
            color: color,
          ),
          _body(
            'Le tarif réglementé d\'EDF (Tarif Bleu) appliqué à ta '
            'consommation des ${r.days} derniers jours, abonnement compris :',
          ),
          const SizedBox(height: 6),
          for (final cost in r.period) row(cost),
          if (paid > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Avec les prix saisis dans ta box : ${_eur(paid)}.',
                style: const TextStyle(fontSize: 12.5, color: TvColors.muted),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            verdict,
            style: TextStyle(
              fontSize: 14,
              height: 1.3,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                note,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  color: TvColors.muted,
                ),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            'Grille du ${RegulatedTariffs.validFrom.day}er août '
            '${RegulatedTariffs.validFrom.year}, TTC · couleurs Tempo : RTE.',
            style: const TextStyle(fontSize: 11, color: TvColors.muted),
          ),
        ],
      ),
    );
  }
}

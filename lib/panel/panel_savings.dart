import 'package:flutter/material.dart';

import '../services/energy_advice.dart';
import '../services/energy_detail_service.dart';
import '../services/widget_data_service.dart';
import '../tv/tv_theme.dart';

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

  const PanelMonthCard({
    super.key,
    required this.month,
    this.budget = 0,
    this.compact = false,
  });

  /// La carte, ou `null` si l'historique ne couvre pas encore le mois.
  /// Le budget est celui de la box (Config → Notifications), qui sert déjà
  /// à son alerte de dépassement ; il ne vaut qu'en euros.
  static Widget? of(EnergyExtras? extras, {bool compact = false}) {
    final month = EnergyAdvice.month(extras, DateTime.now());
    if (month == null) return null;
    final budget = extras?.thresholds.monthBudgetEur;
    return PanelMonthCard(
      month: month,
      budget: month.euros && budget != null ? budget : 0,
      compact: compact,
    );
  }

  String _amount(double value) =>
      month.euros
          ? '${tvNumber(value, decimals: value < 100 ? 2 : 0)} €'
          : '${tvNumber(value, decimals: value < 100 ? 1 : 0)} kWh';

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
          if (PanelMonthCard.of(extras) case final month?) month,
          if (_floor() case final floor?) floor,
          if (_subscription(peaks.data ?? const {}) case final card?) card,
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

  /// Ce qui tourne en permanence, et comment le faire baisser.
  Widget? _floor() {
    final load = EnergyAdvice.baseLoad(snapshot, extras);
    if (load == null) return null;
    final yearly =
        load.yearlyEur != null
            ? '≈ ${tvNumber(load.yearlyEur!)} € par an'
            : '≈ ${tvNumber(load.yearlyKWh)} kWh par an';
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(Icons.nightlight_round, 'Ce qui ne s\'arrête jamais'),
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
    final peak = tvNumber(check.peakVA / 1000, decimals: 1);
    final String text;
    final Color color;
    if (check.tight) {
      color = TvColors.warn;
      text =
          'Ton abonnement est juste : ta consommation frôle souvent le '
          'maximum ($peak kVA sur une minute). Évite d\'allumer en même '
          'temps les gros appareils (four, plaques, radiateurs), ou active la '
          'protection anti-coupure.';
    } else if (check.suggestedKVA case final suggested?) {
      color = TvColors.ok;
      text =
          'En ${check.days} jours, ta consommation n\'a jamais dépassé '
          '$peak kVA. Un abonnement de $suggested kVA suffirait et coûterait '
          'moins cher : renseigne-toi auprès de ton fournisseur.';
    } else if (!check.measured) {
      color = TvColors.focus;
      text =
          'Ton compteur ne donne pas sa puissance maximale : le plus fort '
          "appel relevé quand l'écran tourne est de $peak kVA. Ce n'est "
          'pas assez sûr pour te conseiller un abonnement plus petit.';
    } else if (check.days < SubscriptionCheck.minDays) {
      color = TvColors.focus;
      text =
          'Ton plus fort pic : $peak kVA en ${check.days} '
          '${check.days > 1 ? 'jours' : 'jour'}. Le bilan sera prêt dans '
          '${SubscriptionCheck.minDays - check.days} jours : il dira si ton '
          'abonnement est bien taillé.';
    } else {
      color = TvColors.focus;
      text =
          'Ton plus fort pic : $peak kVA en ${check.days} jours. Ton '
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

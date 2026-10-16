import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'energy_detail_service.dart';
import 'widget_data_service.dart';

/// Les options du tarif réglementé (Tarif Bleu d'EDF).
enum TariffOption { base, offPeak, tempo }

extension TariffOptionLabel on TariffOption {
  String get label => switch (this) {
    TariffOption.base => 'Base',
    TariffOption.offPeak => 'Heures creuses',
    TariffOption.tempo => 'Tempo',
  };
}

/// La grille du Tarif Bleu, TTC, en vigueur depuis le 1er août 2026
/// (délibération de la CRE du 15 juillet 2026). Elle change le 1er février
/// et le 1er août : à mettre à jour à chaque fois, avec [validFrom].
class RegulatedTariffs {
  RegulatedTariffs._();

  static final validFrom = DateTime(2026, 8, 1);

  /// Abonnement annuel TTC, par puissance en kVA. L'option Base n'existe
  /// plus au-delà de 15 kVA, et Tempo pas en 3 kVA.
  static const baseYearly = {
    3: 145.76,
    6: 190.81,
    9: 239.84,
    12: 286.86,
    15: 330.57,
  };
  static const offPeakYearly = {
    3: 145.76,
    6: 190.81,
    9: 239.84,
    12: 286.86,
    15: 330.57,
    18: 375.80,
    24: 473.16,
    30: 561.43,
    36: 650.69,
  };
  static const tempoYearly = {
    6: 189.98,
    9: 237.34,
    12: 283.21,
    15: 325.28,
    18: 369.49,
    24: 460.41,
    30: 552.48,
    36: 649.02,
  };

  /// Prix du kWh TTC en Base : un peu moins cher à partir de 9 kVA.
  static double basePrice(int kva) => kva <= 6 ? 0.2001 : 0.1985;
  static const offPeakHigh = 0.2142;
  static const offPeakLow = 0.1589;

  /// Tempo : heures creuses puis heures pleines, par couleur.
  static const tempoPrices = {
    TempoColor.blue: (0.1356, 0.1654),
    TempoColor.white: (0.1536, 0.1921),
    TempoColor.red: (0.1615, 0.7295),
  };

  static Map<int, double> yearly(TariffOption option) => switch (option) {
    TariffOption.base => baseYearly,
    TariffOption.offPeak => offPeakYearly,
    TariffOption.tempo => tempoYearly,
  };
}

/// Ce qu'une option aurait coûté sur la période.
class OptionCost {
  final TariffOption option;

  /// Puissance retenue, en kVA : celle de l'abonnement, ou la plus proche
  /// au-dessus que l'option propose.
  final int kva;
  final double energyEur;
  final double subscriptionEur;

  const OptionCost(this.option, this.kva, this.energyEur, this.subscriptionEur);

  double get totalEur => energyEur + subscriptionEur;
}

/// D'où vient la part des heures creuses.
enum OffPeakSource {
  /// Des totaux HC et HP de chaque jour (contrat HC ou Tempo) : exacte.
  daily,

  /// Des index des dernières 24 heures seulement.
  lastDay,

  /// Supposée de 22 h à 6 h sur les dernières 24 heures (contrat Base) :
  /// la box ne garde pas l'heure de la consommation au-delà.
  assumed,
}

/// La comparaison : les options sur les jours relevés, et sur un an.
class TariffComparison {
  /// Option du contrat actuel ; `null` si le compteur ne la dit pas (EJP,
  /// offre de marché à index particuliers…).
  final TariffOption? current;

  /// Jours complets comparés.
  final int days;

  /// Part de la consommation en heures creuses sur la période, et d'où
  /// elle vient.
  final double offPeakShare;
  final OffPeakSource offPeakSource;

  /// Jours rouges et blancs de la période.
  final int redDays;
  final int whiteDays;

  /// Sur la période relevée, puis ramenée à une année.
  final List<OptionCost> period;
  final List<OptionCost> year;

  const TariffComparison({
    required this.current,
    required this.days,
    required this.offPeakShare,
    required this.offPeakSource,
    required this.redDays,
    required this.whiteDays,
    required this.period,
    required this.year,
  });

  OptionCost get cheapest =>
      period.reduce((a, b) => b.totalEur < a.totalEur ? b : a);

  OptionCost? costOf(TariffOption option, {bool yearly = false}) =>
      (yearly ? year : period).where((c) => c.option == option).firstOrNull;
}

/// Compare les options du tarif réglementé sur la consommation réelle de
/// la maison.
class TariffCompare {
  TariffCompare._();

  /// L'option du contrat, d'après le libellé du compteur (OPTARIF en mode
  /// historique, NGTF en standard).
  static TariffOption? optionOf(String? contract) {
    final c = (contract ?? '').toUpperCase();
    if (c.contains('BBR') || c.contains('TEMPO')) return TariffOption.tempo;
    if (c.contains('EJP')) return null;
    if (c.startsWith('HC') || c.contains('CREUSE')) {
      return TariffOption.offPeak;
    }
    if (c.startsWith('BASE')) return TariffOption.base;
    return null;
  }

  /// Part des heures creuses dans les dernières 24 heures. Avec un contrat
  /// à heures creuses, la box range déjà chaque heure sous son index
  /// (256 = creuses, 258 = pleines ; en Tempo, les index pairs de rang
  /// pair) ; sinon, on suppose les heures creuses de 22 h à 6 h, les plus
  /// courantes.
  @visibleForTesting
  static ({double share, bool measured}) offPeakShare(
    List<HourlySample> hourly,
    TariffOption? current,
  ) {
    final complete =
        hourly.length > 1 ? hourly.sublist(0, hourly.length - 1) : hourly;
    final total = complete.fold<int>(0, (sum, h) => sum + h.wh);
    if (total <= 0) return (share: 1 / 3, measured: false);
    if (current == TariffOption.offPeak || current == TariffOption.tempo) {
      // Les index des heures creuses : 256, puis 260, 264 en Tempo.
      var low = 0;
      var split = 0;
      for (final h in complete) {
        for (final MapEntry(:key, :value) in h.tariffs.entries) {
          split += value;
          if (((key - 256) ~/ 2).isEven) low += value;
        }
      }
      if (split > total * 0.8) return (share: low / split, measured: true);
    }
    final low = complete
        .where((h) => h.hour >= 22 || h.hour < 6)
        .fold<int>(0, (sum, h) => sum + h.wh);
    return (share: low / total, measured: false);
  }

  /// La puissance que l'option propose pour [kva] : la même, ou la plus
  /// proche au-dessus ; `null` si l'option n'existe pas à cette puissance.
  static int? _tier(TariffOption option, int kva) {
    final tiers = RegulatedTariffs.yearly(option).keys.toList()..sort();
    for (final tier in tiers) {
      if (tier >= kva) return tier;
    }
    return null;
  }

  /// Compare sur les jours complets de [daily] (le dernier, aujourd'hui,
  /// est écarté). [colors] donne la couleur Tempo de chaque jour ; un jour
  /// inconnu est compté bleu. [season] compte les jours rouges et blancs
  /// d'une saison entière, pour l'estimation sur un an.
  static TariffComparison? compare({
    required LinkySnapshot snapshot,
    required List<DailySample> daily,
    required Map<DateTime, TempoColor> colors,
    ({int red, int white})? season,
    DateTime? now,
  }) {
    final subscribed = snapshot.subscribedPowerVA;
    if (subscribed == null || subscribed <= 0 || daily.length < 8) {
      return null;
    }
    final kva = (subscribed / 1000).round();
    final today = now ?? DateTime.now();
    final current = optionOf(snapshot.contract);
    final split = offPeakShare(snapshot.hourly, current);

    // Les jours complets, datés à rebours depuis hier. Avec un contrat HC
    // ou Tempo, chaque jour porte ses totaux HC et HP : sa part d'heures
    // creuses est alors la sienne ; sinon, celle des dernières 24 heures.
    final complete = daily.sublist(0, daily.length - 1);
    double? dayShare(DailySample d) {
      if (current != TariffOption.offPeak && current != TariffOption.tempo) {
        return null;
      }
      final indexed = d.tariffs.values.fold<int>(0, (sum, v) => sum + v);
      if (indexed <= 0 || indexed < d.wh * 0.5) return null;
      final low = d.tariffs.entries
          .where((e) => ((e.key - 256) ~/ 2).isEven)
          .fold<int>(0, (sum, e) => sum + e.value);
      return low / indexed;
    }

    final days = <(DateTime, double, double)>[
      for (final (i, d) in complete.indexed)
        (
          DateTime(today.year, today.month, today.day - (complete.length - i)),
          d.wh / 1000,
          dayShare(d) ?? split.share,
        ),
    ];
    final kwh = days.fold<double>(0, (sum, d) => sum + d.$2);
    if (kwh <= 0) return null;
    final measuredDays = complete.where((d) => dayShare(d) != null).length;
    final source =
        measuredDays >= complete.length / 2
            ? OffPeakSource.daily
            : (split.measured ? OffPeakSource.lastDay : OffPeakSource.assumed);
    // La part de la période, pondérée par la consommation de chaque jour :
    // le coût en heures creuses étant linéaire, elle donne le même total
    // que jour par jour, et sert à l'estimation sur un an.
    final low = days.fold<double>(0, (sum, d) => sum + d.$2 * d.$3) / kwh;

    TempoColor colorOf(DateTime day) =>
        colors[DateTime(day.year, day.month, day.day)] ?? TempoColor.blue;
    var red = 0;
    var white = 0;
    for (final (day, _, _) in days) {
      switch (colorOf(day)) {
        case TempoColor.red:
          red++;
        case TempoColor.white:
          white++;
        case TempoColor.blue:
          break;
      }
    }

    double tempoEnergy(Iterable<(TempoColor, double, double)> spans) =>
        spans.fold(0, (sum, s) {
          final (lowPrice, highPrice) = RegulatedTariffs.tempoPrices[s.$1]!;
          return sum + s.$2 * (s.$3 * lowPrice + (1 - s.$3) * highPrice);
        });

    List<OptionCost> costs({
      required double energy,
      required double share,
      required double Function() tempo,
    }) => [
      for (final option in TariffOption.values)
        if (_tier(option, kva) case final tier?)
          OptionCost(option, tier, switch (option) {
            TariffOption.base => energy * RegulatedTariffs.basePrice(tier),
            TariffOption.offPeak =>
              energy *
                  (low * RegulatedTariffs.offPeakLow +
                      (1 - low) * RegulatedTariffs.offPeakHigh),
            TariffOption.tempo => tempo(),
          }, RegulatedTariffs.yearly(option)[tier]! * share),
    ];

    final period = costs(
      energy: kwh,
      share: days.length / 365,
      tempo:
          () =>
              tempoEnergy([for (final d in days) (colorOf(d.$1), d.$2, d.$3)]),
    );

    // Sur un an : la consommation moyenne d'un jour, répartie sur les
    // couleurs d'une saison entière (300 bleus, 43 blancs, 22 rouges).
    final average = kwh / days.length;
    final redYear = season?.red ?? 22;
    final whiteYear = season?.white ?? 43;
    final year = costs(
      energy: average * 365,
      share: 1,
      tempo:
          () => tempoEnergy([
            (TempoColor.red, average * redYear, low),
            (TempoColor.white, average * whiteYear, low),
            (TempoColor.blue, average * (365 - redYear - whiteYear), low),
          ]),
    );

    return TariffComparison(
      current: current,
      days: days.length,
      offPeakShare: low,
      offPeakSource: source,
      redDays: red,
      whiteDays: white,
      period: period,
      year: year,
    );
  }
}

/// Les couleurs Tempo passées, d'après l'API publique api-couleur-tempo.fr
/// (données RTE, sans clé). Un jour passé ne change plus : elles sont
/// gardées, et seule la saison en cours est relue, une fois par jour.
class TempoCalendar {
  TempoCalendar._();

  static const _prefsKey = 'tempo_calendar';
  static const _host = 'https://www.api-couleur-tempo.fr';

  static Map<DateTime, TempoColor>? _memory;
  static DateTime? _fetchedAt;

  /// Saison Tempo d'un jour : du 1er septembre au 31 août.
  static String seasonOf(DateTime day) {
    final start = day.month >= 9 ? day.year : day.year - 1;
    return '$start-${start + 1}';
  }

  @visibleForTesting
  static Map<DateTime, TempoColor> parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! List) return const {};
    final days = <DateTime, TempoColor>{};
    for (final d in decoded) {
      if (d is! Map) continue;
      final date = DateTime.tryParse('${d['dateJour']}');
      final color = switch (d['codeJour']) {
        1 => TempoColor.blue,
        2 => TempoColor.white,
        3 => TempoColor.red,
        _ => null,
      };
      if (date != null && color != null) {
        days[DateTime(date.year, date.month, date.day)] = color;
      }
    }
    return days;
  }

  /// Rouges et blancs d'une saison complète.
  static ({int red, int white})? seasonCounts(
    Map<DateTime, TempoColor> days,
    String season,
  ) {
    final start = int.parse(season.substring(0, 4));
    final inSeason = days.entries.where(
      (e) =>
          !e.key.isBefore(DateTime(start, 9, 1)) &&
          e.key.isBefore(DateTime(start + 1, 9, 1)),
    );
    if (inSeason.length < 300) return null;
    return (
      red: inSeason.where((e) => e.value == TempoColor.red).length,
      white: inSeason.where((e) => e.value == TempoColor.white).length,
    );
  }

  /// La saison en cours et la précédente, complète ; ce qui est connu si
  /// le réseau manque.
  static Future<Map<DateTime, TempoColor>> load({DateTime? now}) async {
    final today = now ?? DateTime.now();
    final memory = _memory ??= await _restore();
    final fresh =
        _fetchedAt != null &&
        today.difference(_fetchedAt!) < const Duration(hours: 6);
    if (fresh) return memory;

    final current = seasonOf(today);
    final previous = seasonOf(DateTime(today.year - 1, today.month, 15));
    final seasons = [
      current,
      // La saison passée ne change plus : une fois complète, on la garde.
      if (seasonCounts(memory, previous) == null) previous,
    ];
    for (final season in seasons) {
      final body = await _get('/api/joursTempo?periode=$season');
      if (body != null) memory.addAll(parse(body));
    }
    _fetchedAt = today;
    await _save(memory);
    return memory;
  }

  static Future<String?> _get(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse('$_host$path'));
      request.headers.set('Accept', 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await response.transform(utf8.decoder).join();
      return response.statusCode == 200 ? body : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<DateTime, TempoColor>> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (DateTime.tryParse(key) case final day?)
            if (TempoColor.values.asNameMap()['$value'] case final color?)
              day: color,
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _save(Map<DateTime, TempoColor> days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        for (final e in days.entries)
          '${e.key.year}-${e.key.month.toString().padLeft(2, '0')}-${e.key.day.toString().padLeft(2, '0')}':
              e.value.name,
      }),
    );
  }
}

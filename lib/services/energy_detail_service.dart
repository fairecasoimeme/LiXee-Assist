import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'box_client.dart';

/// Un compteur à impulsions suivi par la box en plus du Linky.
enum UtilityKind { gas, water }

/// Consommation d'une heure d'un compteur de gaz ou d'eau, dans son unité.
class UtilitySample {
  /// Heure de début, de 0 à 23.
  final int hour;
  final double value;

  const UtilitySample(this.hour, this.value);

  Map<String, dynamic> toJson() => {'h': hour, 'v': value};

  factory UtilitySample.fromJson(Map<String, dynamic> json) => UtilitySample(
    json['h'] as int? ?? 0,
    (json['v'] as num?)?.toDouble() ?? 0,
  );
}

/// Le compteur de gaz ou d'eau d'une box, avec ses 24 dernières heures.
class UtilityMeter {
  final UtilityKind kind;

  /// Unité saisie sur la box : `m3`, `L` ou `Wh`.
  final String unit;

  /// Prix d'une unité, en euros — du kWh quand l'unité est le Wh, comme la
  /// box le compte. Zéro si aucun prix n'est saisi.
  final double price;

  /// Vide tant que la box n'a rien relevé.
  final List<UtilitySample> hourly;

  const UtilityMeter({
    required this.kind,
    required this.unit,
    this.price = 0,
    this.hourly = const [],
  });

  /// Total des 24 heures, dans l'unité du compteur. `null` sans relevé.
  double? get dailyTotal =>
      hourly.isEmpty ? null : hourly.fold<double>(0, (sum, s) => sum + s.value);

  /// Coût des 24 heures. `null` sans relevé ou sans prix.
  double? get dailyCostEur {
    final total = dailyTotal;
    if (total == null || price <= 0) return null;
    return (unit == 'Wh' ? total / 1000 : total) * price;
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'unit': unit,
    'price': price,
    'hourly': hourly.map((s) => s.toJson()).toList(),
  };

  factory UtilityMeter.fromJson(Map<String, dynamic> json) => UtilityMeter(
    kind: json['kind'] == 'water' ? UtilityKind.water : UtilityKind.gas,
    unit: json['unit'] as String? ?? '',
    price: (json['price'] as num?)?.toDouble() ?? 0,
    hourly:
        (json['hourly'] as List?)
            ?.map((e) => UtilitySample.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}

/// Ce que la vue Énergie montre en plus du relevé Linky : la couleur des
/// sous-compteurs, et les compteurs de gaz et d'eau.
class EnergyExtras {
  /// Couleur choisie sur la box pour chaque sous-compteur, par son nom,
  /// en 0xRRGGBB.
  final Map<String, int> subMeterColors;

  final List<UtilityMeter> utilities;

  const EnergyExtras({
    this.subMeterColors = const {},
    this.utilities = const [],
  });

  Map<String, dynamic> toJson() => {
    'subMeterColors': subMeterColors,
    'utilities': utilities.map((u) => u.toJson()).toList(),
  };

  factory EnergyExtras.fromJson(Map<String, dynamic> json) => EnergyExtras(
    subMeterColors: {
      for (final MapEntry(:key, :value)
          in (json['subMeterColors'] as Map?)?.entries ?? const <MapEntry>[])
        '$key': (value as num?)?.toInt() ?? 0,
    },
    utilities:
        (json['utilities'] as List?)
            ?.map((e) => UtilityMeter.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}

/// Nom d'un index tarifaire pour l'abonné, d'après son contrat (OPTARIF).
///
/// La box ne connaît les index que par leur libellé TIC, commun à tous les
/// contrats : « HC / EJPHN / BBRHCJB / EASF01 ». Le contrat dit lequel de ces
/// sens s'applique.
String tariffLabel(int attribute, String? contract) {
  final c = (contract ?? '').toUpperCase();
  final rank = (attribute - 256) ~/ 2;
  if (c.contains('BBR') || c.contains('TEMPO')) {
    const tempo = [
      'HC Bleu',
      'HP Bleu',
      'HC Blanc',
      'HP Blanc',
      'HC Rouge',
      'HP Rouge',
    ];
    if (rank >= 0 && rank < tempo.length) return tempo[rank];
  } else if (c.contains('EJP')) {
    if (attribute == 256) return 'Heures normales';
    if (attribute == 258) return 'Pointe mobile';
  } else if (c.startsWith('BASE')) {
    if (attribute == 256) return 'Base';
  } else if (c.startsWith('HC') || c.contains('CREUSE')) {
    if (attribute == 256) return 'Heures creuses';
    if (attribute == 258) return 'Heures pleines';
  }
  return 'Index ${rank + 1}';
}

/// Relève ce que la vue Énergie affiche au-delà du Linky.
///
/// Trois ou quatre petites requêtes, espacées de dix minutes : les couleurs
/// des sous-compteurs, les réglages gaz et eau, puis l'historique de chaque
/// compteur configuré.
class EnergyDetailService {
  static const _prefsPrefix = 'energy_extras_';
  static const _interval = Duration(minutes: 10);

  static final Map<String, DateTime> _lastFetch = {};

  /// Dernier relevé connu, sans réseau.
  static Future<EnergyExtras?> read(String deviceName) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsPrefix + deviceName);
    if (raw == null) return null;
    try {
      return EnergyExtras.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Relève la box si le dernier relevé a plus de dix minutes ; `null` sinon,
  /// ou si elle n'a pas répondu. [route] n'est appelé que si c'est le moment.
  static Future<EnergyExtras?> refreshIfDue(
    BoxDevice device,
    Future<BoxRoute?> Function() route,
  ) async {
    final last = _lastFetch[device.key];
    if (last != null && DateTime.now().difference(last) < _interval) {
      return null;
    }
    final reached = await route();
    if (reached == null) return null;
    try {
      final extras = await fetch(reached);
      _lastFetch[device.key] = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsPrefix + device.name,
        jsonEncode(extras.toJson()),
      );
      return extras;
    } catch (e) {
      print('[ENERGY] Détail indisponible: $e');
      return null;
    }
  }

  /// Relève les sous-compteurs, puis les compteurs de gaz et d'eau.
  ///
  /// Chaque partie est facultative : un firmware qui ne connaît pas une
  /// route, ou une box sans compteur, donne simplement une partie vide.
  static Future<EnergyExtras> fetch(BoxRoute route) async {
    var colors = const <String, int>{};
    try {
      final body = await BoxClient.get(route, '/getSubMeters');
      if (body != null) colors = parseSubMeterColors(body);
    } catch (e) {
      print('[ENERGY] /getSubMeters: $e');
    }

    final utilities = <UtilityMeter>[];
    try {
      // Les réglages gaz et eau n'ont pas de route à eux : ils sont dans le
      // fichier de configuration générale, qui porte aussi des mots de
      // passe. Seules les clés utiles en sont lues, et son contenu n'est ni
      // journalisé ni conservé.
      final config = await BoxClient.get(
        route,
        '/readFile?rep=config&file=configGeneral.json',
      );
      for (final meter
          in config == null ? const <UtilityConfig>[] : parseUtilityConfig(config)) {
        var hourly = const <UtilitySample>[];
        try {
          final chart = await BoxClient.get(
            route,
            '/loadEnergyChart?IEEE=${meter.ieee}&time=hour',
          );
          if (chart != null) hourly = parseUtilityChart(chart, meter.coefficient);
        } catch (e) {
          print('[ENERGY] /loadEnergyChart ${meter.kind.name}: $e');
        }
        utilities.add(
          UtilityMeter(
            kind: meter.kind,
            unit: meter.unit,
            price: meter.price,
            hourly: hourly,
          ),
        );
      }
    } catch (e) {
      print('[ENERGY] Réglages gaz et eau: ${e.runtimeType}');
    }

    return EnergyExtras(subMeterColors: colors, utilities: utilities);
  }

  /// Couleur de chaque sous-compteur actif, d'après `/getSubMeters`.
  @visibleForTesting
  static Map<String, int> parseSubMeterColors(String body) {
    final decoded = jsonDecode(body);
    final list = decoded is Map ? decoded['subMeters'] : null;
    if (list is! List) return const {};
    final colors = <String, int>{};
    for (final (rank, meter) in list.indexed) {
      if (meter is! Map || meter['enabled'] == false) continue;
      final index = (meter['index'] as num?)?.toInt() ?? rank;
      var alias = meter['alias']?.toString().trim() ?? '';
      // Sans nom, l'export horaire l'appelle « Sous-compteur n ».
      if (alias.isEmpty) alias = 'Sous-compteur ${index + 1}';
      final color = int.tryParse(
        (meter['color']?.toString() ?? '').replaceFirst('#', ''),
        radix: 16,
      );
      if (color != null) colors[alias] = color;
    }
    return colors;
  }

  /// Les compteurs de gaz et d'eau déclarés dans la configuration générale.
  @visibleForTesting
  static List<UtilityConfig> parseUtilityConfig(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const [];
    final meters = <UtilityConfig>[];
    for (final (kind, device, suffix, defaultUnit) in const [
      (UtilityKind.gas, 'Gaz', 'Gaz', 'm3'),
      (UtilityKind.water, 'Water', 'Water', 'L'),
    ]) {
      final ieee = decoded[device]?.toString().trim() ?? '';
      // Une adresse IEEE : seize chiffres hexadécimaux. Elle part dans une
      // URL, autant ne rien y laisser passer d'autre.
      if (!RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(ieee)) continue;
      final coefficient = _number(decoded['coeff$suffix']);
      final unit = decoded['unit$suffix']?.toString().trim() ?? '';
      meters.add(
        UtilityConfig(
          kind: kind,
          ieee: ieee,
          unit: unit.isEmpty ? defaultUnit : unit,
          // Un coefficient absent ou nul effacerait toute la série.
          coefficient: coefficient > 0 ? coefficient : 1,
          price: _number(decoded['tarif$suffix']),
        ),
      );
    }
    return meters;
  }

  /// L'historique horaire d'un compteur, d'après `/loadEnergyChart`.
  ///
  /// La box renvoie une entrée par heure, `{"y":"15H","0":12}`, et omet la
  /// clé quand rien n'a été compté. Si aucune heure n'a de valeur, la série
  /// est vide : le compteur n'a pas d'historique, ce qui n'est pas la même
  /// chose qu'une consommation nulle.
  @visibleForTesting
  static List<UtilitySample> parseUtilityChart(String body, double coefficient) {
    final decoded = jsonDecode(body);
    if (decoded is! List) return const [];
    final samples = <UtilitySample>[];
    var seen = false;
    for (final row in decoded) {
      if (row is! Map) continue;
      final hour = int.tryParse(
        (row['y']?.toString() ?? '').replaceAll(RegExp(r'[^0-9]'), ''),
      );
      if (hour == null) continue;
      if (row.containsKey('0')) seen = true;
      samples.add(UtilitySample(hour, _number(row['0']) * coefficient));
    }
    return seen ? samples : const [];
  }

  /// La configuration enregistre ses nombres en chaînes, parfois à virgule.
  static double _number(Object? raw) {
    if (raw is num) return raw.toDouble();
    return double.tryParse(raw?.toString().trim().replaceAll(',', '.') ?? '') ??
        0;
  }
}

/// Réglages d'un compteur de gaz ou d'eau, tels que saisis sur la box.
class UtilityConfig {
  final UtilityKind kind;
  final String ieee;
  final String unit;
  final double coefficient;
  final double price;

  const UtilityConfig({
    required this.kind,
    required this.ieee,
    required this.unit,
    required this.coefficient,
    required this.price,
  });
}

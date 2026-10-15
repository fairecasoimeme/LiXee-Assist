import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'box_client.dart';
import 'box_energy_api.dart';
import 'widget_data_service.dart';

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
    return (unit.toLowerCase() == 'wh' ? total / 1000 : total) * price;
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

/// Consommation d'une journée, d'après l'export jour par jour de la box.
class DailySample {
  final int day;
  final int month;
  final int wh;

  /// Coût de la journée, abonnement compris ; 0 sans prix saisi.
  final double costEur;

  const DailySample(this.day, this.month, this.wh, [this.costEur = 0]);

  Map<String, dynamic> toJson() => {
    'd': day,
    'm': month,
    'wh': wh,
    'c': costEur,
  };

  factory DailySample.fromJson(Map<String, dynamic> json) => DailySample(
    json['d'] as int? ?? 0,
    json['m'] as int? ?? 0,
    json['wh'] as int? ?? 0,
    (json['c'] as num?)?.toDouble() ?? 0,
  );
}

/// Ce que la vue Énergie montre en plus du relevé Linky : la couleur des
/// sous-compteurs, et les compteurs de gaz et d'eau.
class EnergyExtras {
  /// Couleur choisie sur la box pour chaque sous-compteur, par son nom,
  /// en 0xRRGGBB.
  final Map<String, int> subMeterColors;

  final List<UtilityMeter> utilities;

  /// Prix du kWh saisi sur la box pour chaque index tarifaire, indexé par
  /// l'attribut Metering (256, 258…). Vide si aucun prix n'est saisi.
  final Map<int, double> prices;

  /// Le tarif en cours, et la couleur Tempo du jour et du lendemain.
  final TariffNow? tariff;

  /// Les trente derniers jours, du plus ancien à aujourd'hui (incomplet).
  final List<DailySample> daily;

  /// La protection anti-coupure (délestage) réglée sur la box.
  final Shedding? shedding;

  /// Les seuils des alertes de la box.
  final BoxThresholds thresholds;

  /// Pics de puissance mesurés par la box (v2.26), pour l'abonnement.
  final PowerSummary? power;

  /// Plancher nocturne calculé par la box (v2.26), en W.
  final int? floorW;

  /// Dernières alertes de la box (v2.26), lues sans les retirer de sa file.
  final List<BoxAlert> boxAlerts;

  /// La box a-t-elle les routes v2.26 ? Elle a alors une moyenne sur une
  /// minute à relire à chaque relevé.
  final bool modern;

  /// Puissance moyenne de la dernière minute, en VA, et l'heure du relevé.
  final int? minuteVA;
  final DateTime? minuteAt;

  /// Charge de la dernière minute en % de la limite (la phase la plus
  /// chargée en triphasé), relevée en même temps.
  final int? minuteLoad;

  const EnergyExtras({
    this.subMeterColors = const {},
    this.utilities = const [],
    this.prices = const {},
    this.tariff,
    this.daily = const [],
    this.shedding,
    this.thresholds = const BoxThresholds(),
    this.power,
    this.floorW,
    this.boxAlerts = const [],
    this.modern = false,
    this.minuteVA,
    this.minuteAt,
    this.minuteLoad,
  });

  /// La moyenne sur une minute, si elle a moins de deux minutes.
  int? get freshMinuteVA {
    final at = minuteAt;
    if (minuteVA == null || at == null) return null;
    return DateTime.now().difference(at) < const Duration(minutes: 2)
        ? minuteVA
        : null;
  }

  /// La charge de la dernière minute, si elle a moins de deux minutes.
  int? get freshMinuteLoad {
    final at = minuteAt;
    if (minuteLoad == null || at == null) return null;
    return DateTime.now().difference(at) < const Duration(minutes: 2)
        ? minuteLoad
        : null;
  }

  /// La même chose, avec une nouvelle moyenne sur une minute et l'état du
  /// délestage qui l'accompagne.
  EnergyExtras withMinute(int? va, int? load, Shedding? shedding) =>
      EnergyExtras(
        subMeterColors: subMeterColors,
        utilities: utilities,
        prices: prices,
        tariff: tariff,
        daily: daily,
        shedding: shedding ?? this.shedding,
        thresholds: thresholds,
        power: power,
        floorW: floorW,
        boxAlerts: boxAlerts,
        modern: modern,
        minuteVA: va,
        minuteAt: DateTime.now(),
        minuteLoad: load,
      );

  /// Ce relevé, complété par [known] là où il est revenu vide : une
  /// requête qui échoue par le tunnel ne doit pas effacer ce qui était
  /// connu. Une box sans compteur de gaz ni prix garde ainsi des parties
  /// vides, et une box qui en a ne les perd pas sur un relevé raté.
  EnergyExtras keeping(EnergyExtras? known) {
    if (known == null) return this;
    return EnergyExtras(
      subMeterColors:
          subMeterColors.isEmpty ? known.subMeterColors : subMeterColors,
      utilities: utilities.isEmpty ? known.utilities : utilities,
      prices: prices.isEmpty ? known.prices : prices,
      tariff: tariff ?? known.tariff,
      daily: daily.isEmpty ? known.daily : daily,
      shedding: shedding ?? known.shedding,
      thresholds:
          thresholds.monthBudgetEur == null &&
                  thresholds.overPowerW == null &&
                  thresholds.nightWaterLitres == null &&
                  known.thresholds.monthBudgetEur != null
              ? known.thresholds
              : thresholds,
      power: power ?? known.power,
      floorW: floorW ?? known.floorW,
      boxAlerts: boxAlerts.isEmpty ? known.boxAlerts : boxAlerts,
      modern: modern || known.modern,
      minuteVA: minuteVA ?? known.minuteVA,
      minuteAt: minuteAt ?? known.minuteAt,
      minuteLoad: minuteLoad ?? known.minuteLoad,
    );
  }

  EnergyExtras withTariff(TariffNow? tariff) => EnergyExtras(
    subMeterColors: subMeterColors,
    utilities: utilities,
    prices: prices,
    tariff: tariff,
    daily: daily,
    shedding: shedding,
    thresholds: thresholds,
    power: power,
    floorW: floorW,
    boxAlerts: boxAlerts,
    modern: modern,
    minuteVA: minuteVA,
    minuteAt: minuteAt,
    minuteLoad: minuteLoad,
  );

  Map<String, dynamic> toJson() => {
    'subMeterColors': subMeterColors,
    'utilities': utilities.map((u) => u.toJson()).toList(),
    'prices': {for (final e in prices.entries) '${e.key}': e.value},
    if (tariff != null) 'tariff': tariff!.toJson(),
    'daily': daily.map((d) => d.toJson()).toList(),
    if (shedding != null) 'shedding': shedding!.toJson(),
    'thresholds': thresholds.toJson(),
    if (power != null) 'power': power!.toJson(),
    if (floorW != null) 'floorW': floorW,
    'boxAlerts': boxAlerts.map((a) => a.toJson()).toList(),
    'modern': modern,
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
    prices: {
      for (final MapEntry(:key, :value)
          in (json['prices'] as Map?)?.entries ?? const <MapEntry>[])
        if (int.tryParse('$key') case final attribute?)
          attribute: (value as num?)?.toDouble() ?? 0,
    },
    tariff:
        json['tariff'] is Map
            ? TariffNow.fromJson(json['tariff'] as Map<String, dynamic>)
            : null,
    daily:
        (json['daily'] as List?)
            ?.map((e) => DailySample.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
    shedding:
        json['shedding'] is Map
            ? Shedding.fromJson(json['shedding'] as Map<String, dynamic>)
            : null,
    thresholds:
        json['thresholds'] is Map
            ? BoxThresholds.fromJson(json['thresholds'] as Map<String, dynamic>)
            : const BoxThresholds(),
    power:
        json['power'] is Map
            ? PowerSummary.fromJson(json['power'] as Map<String, dynamic>)
            : null,
    floorW: json['floorW'] as int?,
    boxAlerts:
        (json['boxAlerts'] as List?)
            ?.map((e) => BoxAlert.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
    modern: json['modern'] == true,
  );
}

/// Les seuils réglés sur la box, dans Config → Notifications. Ce sont ceux
/// de ses propres alertes : le kiosque parle le même langage qu'elles.
class BoxThresholds {
  /// Budget du mois, en euros ; `null` s'il n'est pas fixé.
  final int? monthBudgetEur;

  /// Seuil de surpuissance, en watts, si l'alerte est activée.
  final int? overPowerW;

  /// Écart, en %, au-delà duquel une journée est anormale.
  final int anomalyPercent;

  /// Litres d'eau entre minuit et 5 h au-delà desquels on soupçonne une
  /// fuite, si l'alerte est activée.
  final int? nightWaterLitres;

  const BoxThresholds({
    this.monthBudgetEur,
    this.overPowerW,
    this.anomalyPercent = 30,
    this.nightWaterLitres,
  });

  Map<String, dynamic> toJson() => {
    if (monthBudgetEur != null) 'budget': monthBudgetEur,
    if (overPowerW != null) 'overPower': overPowerW,
    'anomaly': anomalyPercent,
    if (nightWaterLitres != null) 'nightWater': nightWaterLitres,
  };

  factory BoxThresholds.fromJson(Map<String, dynamic> json) => BoxThresholds(
    monthBudgetEur: json['budget'] as int?,
    overPowerW: json['overPower'] as int?,
    anomalyPercent: json['anomaly'] as int? ?? 30,
    nightWaterLitres: json['nightWater'] as int?,
  );
}

/// La protection anti-coupure de la box (délestage) : quand le compteur
/// signale que la puissance souscrite est dépassée, la box éteint
/// elle-même ces appareils pour que le disjoncteur ne saute pas.
class Shedding {
  /// Adresses IEEE des appareils que la box peut éteindre.
  final List<String> devices;

  /// Date du dernier déclenchement, telle que la box l'a notée
  /// (« JJ/MM/AAAA HH:MM »), ou `null` s'il n'y en a jamais eu.
  final String? lastAt;

  /// Délestage en cours, d'après la box ; `null` si elle ne le dit pas
  /// (firmware antérieur à la v2.26).
  final bool? active;

  /// Nom des appareils, par adresse IEEE, quand la box les donne.
  final Map<String, String> names;

  /// Appareils coupés par le délestage en cours.
  final Set<String> cut;

  /// Minutes sous le seuil avant que la box rallume d'elle-même ; 0 si
  /// elle ne le fait pas.
  final int restoreMinutes;

  const Shedding(
    this.devices, {
    this.lastAt,
    this.active,
    this.names = const {},
    this.cut = const {},
    this.restoreMinutes = 0,
  });

  Map<String, dynamic> toJson() => {
    'devices': devices,
    if (lastAt != null) 'lastAt': lastAt,
    if (active != null) 'active': active,
    'names': names,
    'cut': cut.toList(),
    'restoreMinutes': restoreMinutes,
  };

  factory Shedding.fromJson(Map<String, dynamic> json) => Shedding(
    [for (final d in (json['devices'] as List?) ?? const []) '$d'],
    lastAt: json['lastAt'] as String?,
    active: json['active'] as bool?,
    names: {
      for (final MapEntry(:key, :value)
          in (json['names'] as Map? ?? const {}).entries)
        '$key': '$value',
    },
    cut: {for (final d in (json['cut'] as List?) ?? const []) '$d'},
    restoreMinutes: json['restoreMinutes'] as int? ?? 0,
  );
}

/// Couleur d'un jour Tempo.
enum TempoColor { blue, white, red }

/// Le tarif en cours, tel que la box l'affiche dans son tableau de bord
/// (`/api/tariff`).
class TariffNow {
  /// Nom du tarif : « Heures Creuses », « HP Rouge », « Base »… En mode
  /// standard, le libellé brut du compteur.
  final String label;
  final bool isTempo;
  final TempoColor? today;
  final TempoColor? tomorrow;

  /// Index en cours, prix du kWh et heure du prochain changement
  /// (« 22:00 »), quand la box les donne (v2.26).
  final int? index;
  final double? price;
  final String? nextChange;

  const TariffNow({
    required this.label,
    this.isTempo = false,
    this.today,
    this.tomorrow,
    this.index,
    this.price,
    this.nextChange,
  });

  /// Heures pleines, ou pointe mobile en EJP.
  bool get isPeakHours {
    final l = label.toUpperCase();
    return l.contains('HP') || l.contains('PLEINE') || l.contains('POINTE');
  }

  bool get isBase {
    final l = label.toUpperCase();
    return l.startsWith('BASE') || l.startsWith('TH');
  }

  bool get isEjpPeak => label.toUpperCase().contains('POINTE');

  /// L'index tarifaire en cours, en attribut Metering : 256 en heures
  /// creuses ou en base, 258 en heures pleines, puis 260 à 266 pour les
  /// jours blancs et rouges de Tempo.
  int get attribute {
    if (index case final known? when known >= 256) return known;
    final day = isTempo && today != null ? today!.index : 0;
    return 256 + day * 4 + (isPeakHours ? 2 : 0);
  }

  Map<String, dynamic> toJson() => {
    'label': label,
    'isTempo': isTempo,
    if (today != null) 'today': today!.name,
    if (tomorrow != null) 'tomorrow': tomorrow!.name,
    if (index != null) 'index': index,
    if (price != null) 'price': price,
    if (nextChange != null) 'nextChange': nextChange,
  };

  factory TariffNow.fromJson(Map<String, dynamic> json) => TariffNow(
    label: json['label'] as String? ?? '',
    isTempo: json['isTempo'] == true,
    today: TempoColor.values.asNameMap()[json['today']],
    tomorrow: TempoColor.values.asNameMap()[json['tomorrow']],
    index: json['index'] as int?,
    price: (json['price'] as num?)?.toDouble(),
    nextChange: json['nextChange'] as String?,
  );

  /// Lit la réponse de `/api/tariff`. `null` si la box n'a pas de ZLinky
  /// ou ne connaît pas encore le tarif.
  static TariffNow? parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['show'] != true) return null;
    final label = decoded['tariff']?.toString().trim() ?? '';
    if (label.isEmpty || label == '---') return null;
    TempoColor? color(Object? day) => switch ((day as Map?)?['class']) {
      'tempo-bleu' => TempoColor.blue,
      'tempo-blanc' => TempoColor.white,
      'tempo-rouge' => TempoColor.red,
      _ => null,
    };
    final next = decoded['nextChange']?.toString() ?? '';
    return TariffNow(
      label: label,
      isTempo: decoded['isTempo'] == true,
      today: color(decoded['today']),
      tomorrow: color(decoded['tomorrow']),
      index: (decoded['index'] as num?)?.toInt(),
      price: (decoded['price'] as num?)?.toDouble(),
      nextChange: RegExp(r'^\d{1,2}:\d{2}$').hasMatch(next) ? next : null,
    );
  }
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

  /// Le tarif change aux heures creuses : il est relu plus souvent que le
  /// reste.
  static const _tariffInterval = Duration(minutes: 2);

  static final Map<String, DateTime> _lastFetch = {};
  static final Map<String, DateTime> _lastTariff = {};

  /// Force le prochain relevé complet, après une action qui en change le
  /// résultat (rallumage du délestage).
  static void forget(BoxDevice device) => _lastFetch.remove(device.key);

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

  /// Relève la box si c'est le moment : le tarif toutes les deux minutes,
  /// le reste toutes les dix. `null` si rien n'était dû, ou si la box n'a
  /// pas répondu. [route] n'est appelé que si un relevé est dû.
  static Future<EnergyExtras?> refreshIfDue(
    BoxDevice device,
    EnergyExtras? previous,
    Future<BoxRoute?> Function() route,
  ) async {
    bool due(Map<String, DateTime> last, Duration interval) {
      final at = last[device.key];
      return at == null || DateTime.now().difference(at) >= interval;
    }

    final full = due(_lastFetch, _interval);
    if (!full && !due(_lastTariff, _tariffInterval)) return null;
    final reached = await route();
    if (reached == null) return null;
    try {
      final known = previous ?? await read(device.name);
      var extras =
          full
              ? (await fetch(reached)).keeping(known)
              : (known ?? const EnergyExtras());
      if (full) _lastFetch[device.key] = DateTime.now();
      try {
        final body = await BoxClient.get(reached, '/api/tariff');
        // Une réponse vide ou illisible — le tunnel coupe parfois — garde le
        // tarif connu : sans cela, le bandeau du tarif apparaissait puis
        // disparaissait au gré des relevés.
        final tariff = body == null ? null : TariffNow.parse(body);
        if (tariff != null) {
          extras = extras.withTariff(tariff);
          _lastTariff[device.key] = DateTime.now();
        }
      } catch (e) {
        print('[ENERGY] /api/tariff: ${e.runtimeType}');
      }
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
    // Firmware v2.26 et suivants : une route de configuration sans secrets,
    // et les mesures de puissance calculées par la box.
    try {
      final body = await BoxClient.get(route, '/api/energy/config');
      final config = body == null ? null : ApiEnergyConfig.parse(body);
      if (config != null) {
        return await _fetchV226(route, config);
      }
    } catch (e) {
      print('[ENERGY] /api/energy/config: ${e.runtimeType}');
    }
    return _fetchLegacy(route);
  }

  /// Box v2.26 : tout vient de routes dédiées.
  static Future<EnergyExtras> _fetchV226(
    BoxRoute route,
    ApiEnergyConfig config,
  ) async {
    Future<String?> get(String path) async {
      try {
        return await BoxClient.get(route, path);
      } catch (e) {
        print('[ENERGY] $path: ${e.runtimeType}');
        return null;
      }
    }

    // Le premier firmware v2.26 emploie « water » deux fois, et l'adresse
    // du compteur d'eau s'y perd. En attendant sa correction, l'adresse
    // manquante est relue dans l'ancienne configuration ; seule elle en est
    // retenue.
    List<UtilityConfig>? legacy;
    Future<String?> address(UtilityKind kind) async {
      legacy ??= await () async {
        final body = await get('/readFile?rep=config&file=configGeneral.json');
        try {
          return body == null
              ? const <UtilityConfig>[]
              : parseUtilityConfig(body);
        } catch (_) {
          return const <UtilityConfig>[];
        }
      }();
      return legacy!.where((m) => m.kind == kind).firstOrNull?.ieee;
    }

    final utilities = <UtilityMeter>[];
    for (final (kind, found) in [
      (UtilityKind.gas, config.gas),
      (UtilityKind.water, config.water),
    ]) {
      var meter = found;
      if (meter == null) continue;
      if (meter.ieee.isEmpty) {
        final ieee = await address(kind);
        if (ieee == null) continue;
        meter = ApiMeter(ieee, meter.price, meter.coefficient, meter.unit);
      }
      final chart = await get('/loadEnergyChart?IEEE=${meter.ieee}&time=hour');
      utilities.add(
        UtilityMeter(
          kind: kind,
          unit: meter.unit,
          price: meter.price,
          hourly:
              chart == null
                  ? const []
                  : parseUtilityChart(chart, meter.coefficient),
        ),
      );
    }

    final daily =
        config.zlinky == null
            ? const <DailySample>[]
            : await _fetchDailyFor(route, config.zlinky!);

    Shedding shedding = Shedding(config.sheddingDevices);
    int? minuteVA;
    int? minuteLoad;
    final state = await get('/api/delestage');
    if (state != null) {
      if (ApiShedding.parse(state) case final s?) {
        shedding = _shedding(s);
        minuteVA = s.minuteVA;
        minuteLoad = s.minuteLoadPercent;
      }
    }

    final summary = await get('/api/power/summary');
    final alerts = await get('/api/alerts?since=0');

    return EnergyExtras(
      subMeterColors: config.subMeterColors,
      utilities: utilities,
      prices: config.prices,
      daily: daily,
      shedding: shedding,
      thresholds: BoxThresholds(
        monthBudgetEur: config.monthBudgetEur,
        overPowerW: config.overPowerW,
        anomalyPercent: config.anomalyPercent,
        nightWaterLitres: config.nightWaterLitres,
      ),
      power: summary == null ? null : PowerSummary.parse(summary),
      boxAlerts:
          alerts == null ? const [] : (BoxAlert.parse(alerts) ?? const []),
      modern: true,
      minuteVA: minuteVA,
      minuteAt: minuteVA == null && minuteLoad == null ? null : DateTime.now(),
      minuteLoad: minuteLoad,
    );
  }

  /// Convertit l'état de délestage de la box en celui du kiosque.
  static Shedding _shedding(ApiShedding s) => Shedding(
    [for (final d in s.devices) d.ieee],
    lastAt: s.active ? s.since : s.lastEnd,
    active: s.active,
    names: {for (final d in s.devices) d.ieee: d.name},
    cut: {
      for (final d in s.devices)
        if (d.cut) d.ieee,
    },
    restoreMinutes: s.restoreMinutes,
  );

  /// Relit la moyenne sur une minute et l'état du délestage (v2.26) : à
  /// chaque relevé, car le risque de coupure se joue à la minute. `null`
  /// si la box n'a pas répondu.
  static Future<EnergyExtras?> refreshMinute(
    BoxRoute route,
    EnergyExtras extras,
  ) async {
    try {
      final body = await BoxClient.get(route, '/api/delestage');
      final state = body == null ? null : ApiShedding.parse(body);
      if (state == null) return null;
      return extras.withMinute(
        state.minuteVA,
        state.minuteLoadPercent,
        _shedding(state),
      );
    } catch (e) {
      print('[ENERGY] /api/delestage: ${e.runtimeType}');
      return null;
    }
  }

  /// Box antérieure à la v2.26 : configuration générale et calculs locaux.
  static Future<EnergyExtras> _fetchLegacy(BoxRoute route) async {
    var colors = const <String, int>{};
    try {
      final body = await BoxClient.get(route, '/getSubMeters');
      if (body != null) colors = parseSubMeterColors(body);
    } catch (e) {
      print('[ENERGY] /getSubMeters: $e');
    }

    final utilities = <UtilityMeter>[];
    var prices = const <int, double>{};
    var daily = const <DailySample>[];
    Shedding? shedding;
    var thresholds = const BoxThresholds();
    try {
      // Les réglages gaz et eau n'ont pas de route à eux : ils sont dans le
      // fichier de configuration générale, qui porte aussi des mots de
      // passe. Seules les clés utiles en sont lues, et son contenu n'est ni
      // journalisé ni conservé.
      final config = await BoxClient.get(
        route,
        '/readFile?rep=config&file=configGeneral.json',
      );
      if (config != null) {
        prices = parsePrices(config);
        daily = await _fetchDaily(route, config);
        shedding = await _fetchShedding(route, config);
        thresholds = parseThresholds(config);
      }
      for (final meter
          in config == null
              ? const <UtilityConfig>[]
              : parseUtilityConfig(config)) {
        var hourly = const <UtilitySample>[];
        try {
          final chart = await BoxClient.get(
            route,
            '/loadEnergyChart?IEEE=${meter.ieee}&time=hour',
          );
          if (chart != null)
            hourly = parseUtilityChart(chart, meter.coefficient);
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

    return EnergyExtras(
      subMeterColors: colors,
      utilities: utilities,
      prices: prices,
      daily: daily,
      shedding: shedding,
      thresholds: thresholds,
    );
  }

  /// Les seuils de Config → Notifications. Une alerte désactivée laisse son
  /// seuil de côté : le kiosque reprend alors ses propres règles.
  @visibleForTesting
  static BoxThresholds parseThresholds(String config) {
    final decoded = jsonDecode(config);
    if (decoded is! Map) return const BoxThresholds();
    bool on(String key) => _number(decoded[key]) != 0;
    int? positive(String key) {
      final value = _number(decoded[key]).round();
      return value > 0 ? value : null;
    }

    final anomaly = positive('DailyAnomalyPercent');
    return BoxThresholds(
      monthBudgetEur: positive('OverBudgetThreshold'),
      overPowerW: on('OverPower') ? positive('OverPowerThreshold') : null,
      anomalyPercent: on('DailyAnomaly') && anomaly != null ? anomaly : 30,
      nightWaterLitres:
          on('NightWaterLeak')
              ? (positive('NightWaterLeakThreshold') ?? 1)
              : null,
    );
  }

  /// Les appareils du délestage, et son dernier déclenchement.
  static Future<Shedding?> _fetchShedding(BoxRoute route, String config) async {
    final devices = parseSheddingDevices(config);
    String? lastAt;
    try {
      // La box note dans ce fichier l'état d'avant chaque délestage.
      final state = await BoxClient.get(
        route,
        '/readFile?rep=config&file=delestage.json',
      );
      if (state != null) lastAt = parseSheddingLastAt(state);
    } catch (_) {
      // Jamais déclenché, ou firmware sans ce fichier.
    }
    return Shedding(devices, lastAt: lastAt);
  }

  /// Les appareils que la box éteint en cas de dépassement : la clé
  /// `delestage` de la configuration, une liste d'IEEE séparées par des
  /// virgules.
  @visibleForTesting
  static List<String> parseSheddingDevices(String config) {
    final decoded = jsonDecode(config);
    final raw = decoded is Map ? decoded['delestage']?.toString() ?? '' : '';
    return [
      for (final id in raw.split(','))
        if (RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(id.trim())) id.trim(),
    ];
  }

  /// Date du dernier délestage, d'après `delestage.json`.
  @visibleForTesting
  static String? parseSheddingLastAt(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map || '${decoded['state']}' != '1') return null;
    final at = decoded['dateOn']?.toString().trim() ?? '';
    return at.isEmpty ? null : at;
  }

  /// Les trente derniers jours d'un ZLinky.
  static Future<List<DailySample>> _fetchDailyFor(
    BoxRoute route,
    String ieee,
  ) async {
    try {
      final csv = await BoxClient.get(
        route,
        '/exportEnergyChart?IEEE=$ieee&time=day',
      );
      return csv == null ? const [] : parseDailyCsv(csv);
    } catch (e) {
      print('[ENERGY] Historique par jour: ${e.runtimeType}');
      return const [];
    }
  }

  /// Rallume les appareils coupés par le délestage (v2.26). `true` si la
  /// box a pris la demande ; elle l'exécute au tour de boucle suivant.
  static Future<bool> restoreShedding(BoxRoute route) async {
    try {
      final body = await BoxClient.post(route, '/api/delestage/restore', {});
      return body != null;
    } catch (e) {
      print('[ENERGY] /api/delestage/restore: ${e.runtimeType}');
      return false;
    }
  }

  /// Les trente derniers jours du ZLinky déclaré dans la configuration.
  static Future<List<DailySample>> _fetchDaily(
    BoxRoute route,
    String config,
  ) async {
    try {
      final decoded = jsonDecode(config);
      final ieee = decoded is Map ? decoded['ZLinky']?.toString().trim() : null;
      if (ieee == null || !RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(ieee)) {
        return const [];
      }
      final csv = await BoxClient.get(
        route,
        '/exportEnergyChart?IEEE=$ieee&time=day',
      );
      return csv == null ? const [] : parseDailyCsv(csv);
    } catch (e) {
      print('[ENERGY] Historique par jour: ${e.runtimeType}');
      return const [];
    }
  }

  /// Décode l'export jour par jour : une ligne par jour, « 05/10 » en tête,
  /// les mêmes colonnes que l'export horaire.
  @visibleForTesting
  static List<DailySample> parseDailyCsv(String csv) {
    final lines =
        csv
            .replaceFirst('\uFEFF', '')
            .split(RegExp(r'\r?\n'))
            .where((l) => l.trim().isNotEmpty)
            .toList();
    if (lines.length < 2) return const [];
    final header = lines.first.split(';').map((h) => h.toLowerCase()).toList();
    final total = header.indexWhere((h) => h.contains('consommation totale'));
    final cost = header.indexWhere((h) => h.contains('cout total'));
    if (total < 0) return const [];
    final samples = <DailySample>[];
    for (final line in lines.skip(1)) {
      final cells = line.split(';');
      final date = RegExp(r'(\d{1,2})/(\d{1,2})').firstMatch(cells.first);
      if (date == null || cells.length <= total) continue;
      final wh = int.tryParse(cells[total].trim());
      if (wh == null) continue;
      samples.add(
        DailySample(
          int.parse(date.group(1)!),
          int.parse(date.group(2)!),
          wh,
          cost < 0 || cells.length <= cost
              ? 0
              : _number(cells[cost].replaceAll(',', '.')),
        ),
      );
    }
    return samples;
  }

  /// Prix du kWh saisis sur la box (onglet Linky), par index tarifaire.
  ///
  /// `tarifIdx2` est le prix de l'attribut 256, `tarifIdx3` celui du 258,
  /// et ainsi de suite jusqu'à `tarifIdx10` pour le 272. Un prix nul ou
  /// absent n'est pas retenu : il ne dit pas que l'électricité est gratuite.
  @visibleForTesting
  static Map<int, double> parsePrices(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const {};
    return {
      for (var n = 2; n <= 10; n++)
        if (_number(decoded['tarifIdx$n']) case final price when price > 0)
          256 + (n - 2) * 2: price,
    };
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
  static List<UtilitySample> parseUtilityChart(
    String body,
    double coefficient,
  ) {
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

/// La puissance maximale de chaque jour, gardée sur l'appareil : le
/// compteur ne publie que celle du jour et de la veille, et le bilan
/// d'abonnement a besoin de plusieurs semaines.
class PowerPeaks {
  PowerPeaks._();

  static const _prefsPrefix = 'power_peaks_';
  static const _keepDays = 90;

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Les pics connus, par jour (« AAAA-MM-JJ »), en VA.
  static Future<Map<String, int>> load(String box) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsPrefix + box);
    if (raw == null) return {};
    try {
      return {
        for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries)
          '$key': (value as num).toInt(),
      };
    } catch (_) {
      return {};
    }
  }

  /// Note le pic du jour d'après un relevé, et celui de la veille quand le
  /// compteur le donne. Sans PMAX publié, la puissance de l'instant sert de
  /// minimum : le pic réel ne peut qu'être plus haut.
  static Future<Map<String, int>> record(
    String box,
    LinkySnapshot snapshot, {
    DateTime? now,
  }) async {
    final today = now ?? DateTime.now();
    final peaks = await load(box);
    void keep(DateTime day, int? va) {
      if (va == null || va <= 0) return;
      final key = _day(day);
      if ((peaks[key] ?? 0) < va) peaks[key] = va;
    }

    keep(today, snapshot.maxPowerTodayVA ?? snapshot.apparentPowerVA);
    keep(today.subtract(const Duration(days: 1)), snapshot.maxPowerYesterdayVA);

    final oldest = _day(today.subtract(const Duration(days: _keepDays)));
    peaks.removeWhere((day, _) => day.compareTo(oldest) < 0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsPrefix + box, jsonEncode(peaks));
    return peaks;
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

import 'dart:convert';

/// Les routes énergie du firmware LiXee-Box v2.26 : configuration sans
/// secrets, pics et plancher de puissance, alertes, délestage.
///
/// Une box plus ancienne répond 404 à toutes : l'application garde alors
/// ses contournements (lecture de la configuration générale, calculs à
/// partir des relevés). Ces fonctions ne font que décoder ; elles rendent
/// `null` sur une réponse qu'elles ne reconnaissent pas.

/// Un nombre JSON, ou une chaîne qui en contient un.
double? _num(Object? raw) {
  if (raw is num) return raw.toDouble();
  return double.tryParse(raw?.toString().trim().replaceAll(',', '.') ?? '');
}

int? _int(Object? raw) => _num(raw)?.round();

final _ieee = RegExp(r'^[0-9a-fA-F]{16}$');

String? _device(Object? raw) {
  final id = raw?.toString().trim() ?? '';
  return _ieee.hasMatch(id) ? id : null;
}

/// Un compteur de gaz ou d'eau, tel que `/api/energy/config` le décrit.
class ApiMeter {
  final String ieee;
  final double price;
  final double coefficient;
  final String unit;

  const ApiMeter(this.ieee, this.price, this.coefficient, this.unit);
}

/// `GET /api/energy/config`.
class ApiEnergyConfig {
  final String? zlinky;
  final Map<int, double> prices;
  final ApiMeter? gas;
  final ApiMeter? water;

  /// Couleur des sous-compteurs actifs, par nom, en 0xRRGGBB.
  final Map<String, int> subMeterColors;

  /// Budget du mois en euros, s'il est activé.
  final int? monthBudgetEur;
  final int? overPowerW;
  final int anomalyPercent;
  final int? nightWaterLitres;
  final List<String> sheddingDevices;

  const ApiEnergyConfig({
    this.zlinky,
    this.prices = const {},
    this.gas,
    this.water,
    this.subMeterColors = const {},
    this.monthBudgetEur,
    this.overPowerW,
    this.anomalyPercent = 30,
    this.nightWaterLitres,
    this.sheddingDevices = const [],
  });

  static ApiEnergyConfig? parse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    // Une page de connexion ou un 404 habillé ne portent pas ces clés.
    if (decoded is! Map || !decoded.containsKey('prices')) return null;

    // Un compteur décrit sans adresse garde ses réglages, avec une adresse
    // vide : l'application la retrouve ailleurs (voir EnergyDetailService).
    ApiMeter? meter(
      Object? section,
      Object? ieee,
      String defaultUnit, {
      bool allowMissing = false,
    }) {
      final id = _device(ieee) ?? (allowMissing && section is Map ? '' : null);
      if (id == null || section is! Map) return null;
      final coefficient = _num(section['coeff']) ?? 1;
      final unit = section['unit']?.toString().trim() ?? '';
      return ApiMeter(
        id,
        _num(section['price']) ?? 0,
        coefficient > 0 ? coefficient : 1,
        unit.isEmpty ? defaultUnit : unit,
      );
    }

    final thresholds = decoded['thresholds'];
    Map? rule(String name) =>
        thresholds is Map && thresholds[name] is Map
            ? thresholds[name] as Map
            : null;
    int? enabled(String name, String field) {
      final r = rule(name);
      if (r == null || r['enabled'] != true) return null;
      final value = _int(r[field]);
      return value != null && value > 0 ? value : null;
    }

    return ApiEnergyConfig(
      zlinky: _device(decoded['zlinky']),
      prices: {
        for (final MapEntry(:key, :value)
            in (decoded['prices'] as Map? ?? const {}).entries)
          if (int.tryParse('$key') case final attribute?)
            if (_num(value) case final price? when price > 0) attribute: price,
      },
      gas: meter(
        decoded['gas'],
        decoded['gaz'] ?? _inner(decoded['gas'], 'ieee'),
        'm3',
      ),
      // L'exemple de la v2.26 emploie « water » deux fois, pour l'adresse et
      // pour les réglages : en JSON, la seconde écrase la première. On
      // accepte donc l'adresse sous « waterIeee » ou dans les réglages.
      water: meter(
        decoded['water'],
        decoded['waterIeee'] ?? _inner(decoded['water'], 'ieee'),
        'L',
        // Seule l'eau souffre de la clé en double.
        allowMissing: true,
      ),
      subMeterColors: {
        for (final m in (decoded['subMeters'] as List? ?? const []))
          if (m is Map && m['enabled'] != false)
            if (int.tryParse(
                  (m['color']?.toString() ?? '').replaceFirst('#', ''),
                  radix: 16,
                )
                case final color?)
              _alias(m): color,
      },
      monthBudgetEur: enabled('budget', 'monthEur'),
      overPowerW: enabled('overPower', 'w'),
      anomalyPercent: enabled('dailyAnomaly', 'percent') ?? 30,
      nightWaterLitres:
          rule('nightWaterLeak')?['enabled'] == true
              ? (_int(rule('nightWaterLeak')!['litres']) ?? 1)
              : null,
      sheddingDevices: [
        for (final d in (decoded['delestage'] as List? ?? const []))
          if (_device(d) case final id?) id,
      ],
    );
  }

  static Object? _inner(Object? section, String key) =>
      section is Map ? section[key] : null;

  static String _alias(Map m) {
    final alias = m['alias']?.toString().trim() ?? '';
    return alias.isEmpty
        ? 'Sous-compteur ${(_int(m['index']) ?? 0) + 1}'
        : alias;
  }
}

/// `GET /api/delestage` : la protection anti-coupure en ce moment.
class ApiShedding {
  final bool active;
  final String? since;
  final String? lastEnd;

  /// Minutes sous le seuil avant le rallumage automatique ; 0 = jamais.
  final int restoreMinutes;

  /// Puissance moyenne de la dernière minute, en VA ; `null` si inconnue.
  /// C'est elle qui fait couper le compteur, pas un pic d'une seconde.
  final int? minuteVA;

  /// Charge de la dernière minute, en % de la limite : du total en
  /// monophasé, de la phase la plus chargée en triphasé ; `null` si
  /// inconnue. C'est elle que la box compare pour délester.
  final int? minuteLoadPercent;
  final List<({String ieee, String name, bool cut})> devices;

  const ApiShedding({
    required this.active,
    this.since,
    this.lastEnd,
    this.restoreMinutes = 0,
    this.minuteVA,
    this.minuteLoadPercent,
    this.devices = const [],
  });

  static ApiShedding? parse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map || decoded['active'] is! bool) return null;
    String? text(Object? raw) {
      final s = raw?.toString().trim() ?? '';
      return s.isEmpty || s == 'null' ? null : s;
    }

    return ApiShedding(
      active: decoded['active'] as bool,
      since: text(decoded['since']),
      lastEnd: text(decoded['lastEnd']),
      restoreMinutes: _int(decoded['restoreMinutes']) ?? 0,
      minuteVA: switch (_int(decoded['minuteVA'])) {
        final va? when va >= 0 => va,
        _ => null,
      },
      minuteLoadPercent: switch (_int(decoded['minuteLoadPercent'])) {
        final percent? when percent >= 0 => percent,
        _ => null,
      },
      devices: [
        for (final d in (decoded['devices'] as List? ?? const []))
          if (d is Map)
            if (_device(d['ieee']) case final ieee?)
              (
                ieee: ieee,
                name: text(d['name']) ?? ieee,
                cut: d['cut'] == true,
              ),
      ],
    );
  }
}

/// Fréquence à laquelle une tranche de puissance est atteinte.
enum PeakRate { daily, weekly, monthly, rare, never, unknown }

/// `GET /api/power/summary` : de quoi juger l'abonnement.
class PowerSummary {
  final int subscribedVA;

  /// Pire moyenne sur 1 min, et pire plateau sur 10 min, sur toute la
  /// période connue (jusqu'à 24 mois).
  final int? worstVa1m;
  final int? worstVa10m;

  /// Jours observés, au plus 90.
  final int observedDays;

  /// Fréquence de chaque tranche, en % de la puissance souscrite (de la
  /// limite de chaque phase en triphasé).
  final Map<int, PeakRate> rates;

  /// Jours des 30 derniers où la moyenne sur 1 min a atteint 80 %.
  final int? days30Over80;

  /// Triphasé : chaque phase coupe à sa propre limite, un tiers de
  /// l'abonnement. Le pire de la phase la plus chargée compte alors, pas
  /// celui du total.
  final bool threePhase;
  final int? worstPhaseVa1m;

  const PowerSummary({
    required this.subscribedVA,
    this.worstVa1m,
    this.worstVa10m,
    this.observedDays = 0,
    this.rates = const {},
    this.days30Over80,
    this.threePhase = false,
    this.worstPhaseVa1m,
  });

  /// Limite d'une phase, en VA.
  int get phaseLimitVA => (subscribedVA / 3).round();

  Map<String, dynamic> toJson() => {
    'subscribedVA': subscribedVA,
    if (worstVa1m != null) 'va1m': worstVa1m,
    if (worstVa10m != null) 'va10m': worstVa10m,
    'observedDays': observedDays,
    'rates': {for (final e in rates.entries) '${e.key}': e.value.name},
    if (days30Over80 != null) 'days30Over80': days30Over80,
    if (threePhase) 'threePhase': true,
    if (worstPhaseVa1m != null) 'phaseVa1m': worstPhaseVa1m,
  };

  factory PowerSummary.fromJson(Map<String, dynamic> json) => PowerSummary(
    subscribedVA: json['subscribedVA'] as int? ?? 0,
    worstVa1m: json['va1m'] as int?,
    worstVa10m: json['va10m'] as int?,
    observedDays: json['observedDays'] as int? ?? 0,
    days30Over80: json['days30Over80'] as int?,
    threePhase: json['threePhase'] == true,
    worstPhaseVa1m: json['phaseVa1m'] as int?,
    rates: {
      for (final MapEntry(:key, :value)
          in (json['rates'] as Map? ?? const {}).entries)
        if (int.tryParse('$key') case final band?)
          band: PeakRate.values.asNameMap()['$value'] ?? PeakRate.unknown,
    },
  );

  static PowerSummary? parse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final Map root = decoded;
    final subscribed = _int(root['subscribedVA']);
    if (subscribed == null || subscribed <= 0) return null;

    // Le pire des 90 derniers jours, et celui de chaque mois connu : une
    // charge d'hiver ne doit pas être oubliée en été.
    int? worst(String field) {
      int? best;
      void take(Object? raw) {
        final v = _int(raw);
        if (v != null && v > 0 && (best == null || v > best!)) best = v;
      }

      final w = root['worst'];
      if (w is Map && w[field] is Map) take((w[field] as Map)['va']);
      for (final m in (root['months'] as List? ?? const [])) {
        if (m is Map) take(m[field]);
      }
      return best;
    }

    // Triphasé : le pire de chaque phase, sur 90 jours et par mois.
    int? worstPhase(String field) {
      int? best;
      void take(Object? phases) {
        for (final p in (phases is List ? phases : const [])) {
          if (p is! Map) continue;
          final raw = p[field];
          final v = _int(raw is Map ? raw['va'] : raw);
          if (v != null && v > 0 && (best == null || v > best!)) best = v;
        }
      }

      final w = root['worst'];
      if (w is Map) take(w['phases']);
      for (final m in (root['months'] as List? ?? const [])) {
        if (m is Map) take(m['phases']);
      }
      return best;
    }

    var observed = 0;
    int? days30Over80;
    final rates = <int, PeakRate>{};
    final frequency = decoded['frequency'];
    if (frequency is Map) {
      for (final MapEntry(:key, :value) in frequency.entries) {
        final band = int.tryParse('$key');
        if (band == null || value is! Map) continue;
        rates[band] =
            PeakRate.values.asNameMap()['${value['rate']}'] ?? PeakRate.unknown;
        final days = _int(value['observedDays']) ?? 0;
        if (days > observed) observed = days;
        if (band == 80) days30Over80 = _int(value['days30']);
      }
    }

    return PowerSummary(
      subscribedVA: subscribed,
      worstVa1m: worst('va1m'),
      worstVa10m: worst('va10m'),
      observedDays: observed,
      rates: rates,
      days30Over80: days30Over80,
      threePhase: root['triphase'] == true,
      worstPhaseVa1m: root['triphase'] == true ? worstPhase('va1m') : null,
    );
  }
}

/// `GET /api/power/floor` : le plancher nocturne le plus récent, en W.
int? parseLatestFloor(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final days = decoded['floor'];
    if (days is! List) return null;
    for (final day in days.reversed) {
      if (day is! Map) continue;
      final w = _int(day['w']);
      if (w != null && w > 0) return w;
    }
  } catch (_) {
    // Réponse illisible : pas de plancher.
  }
  return null;
}

/// Une alerte de la box, lue sans la retirer de sa file (`/api/alerts`).
class BoxAlert {
  final int id;
  final DateTime? at;
  final String type;
  final String title;
  final String message;

  const BoxAlert({
    required this.id,
    required this.type,
    required this.title,
    required this.message,
    this.at,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    if (at != null) 'at': at!.millisecondsSinceEpoch,
    'type': type,
    'title': title,
    'message': message,
  };

  factory BoxAlert.fromJson(Map<String, dynamic> json) => BoxAlert(
    id: json['id'] as int? ?? 0,
    at:
        json['at'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['at'] as int)
            : null,
    type: json['type'] as String? ?? 'info',
    title: json['title'] as String? ?? '',
    message: json['message'] as String? ?? '',
  );

  /// « 14/10/2026 18:42 », l'horodatage de la box.
  static DateTime? _date(Object? raw) {
    final m = RegExp(
      r'(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2})',
    ).firstMatch(raw?.toString() ?? '');
    if (m == null) return null;
    int g(int i) => int.parse(m.group(i)!);
    return DateTime(g(3), g(2), g(1), g(4), g(5));
  }

  static List<BoxAlert>? parse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map || decoded['alerts'] is! List) return null;
    return [
      for (final a in decoded['alerts'] as List)
        if (a is Map)
          BoxAlert(
            id: _int(a['id']) ?? 0,
            at: _date(a['ts']),
            type: a['type']?.toString() ?? 'info',
            // Le titre de la box commence souvent par des émojis : le
            // kiosque a déjà son icône.
            title:
                (a['title']?.toString() ?? '')
                    .replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '')
                    .trim(),
            message: a['message']?.toString().trim() ?? '',
          ),
    ];
  }
}

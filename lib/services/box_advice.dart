import 'dart:convert';

import 'energy_advice.dart';
import 'energy_detail_service.dart';
import 'tariff_compare.dart';

/// Les conseils calculés par la box (`GET /api/energy/advice`, firmware
/// v3.3 et suivants).
///
/// La box est alors la seule source des calculs : la page web, MQTT et
/// l'application affichent le même résultat. Rien n'est recalculé ici, la
/// réponse est seulement décodée dans les classes du kiosque. Une section
/// que la box ne sait pas calculer est absente de sa réponse : elle reste
/// `null`, et le kiosque n'en affiche pas la carte.
///
/// Une box plus ancienne n'a pas cette route : [EnergyAdvice] et
/// [TariffCompare] font alors les calculs eux-mêmes, comme avant.
class BoxAdvice {
  /// La réponse telle que la box l'a donnée, pour la garder entre deux
  /// lancements et la compléter par la météo seule.
  final Map<String, dynamic> raw;

  /// Quand l'application l'a reçue : le risque de coupure n'a de sens que
  /// frais.
  final DateTime receivedAt;

  final ElectricityWeather? weather;

  /// Ce que coûte la consommation de l'instant, en euros par heure.
  final double? costPerHour;
  final CutRisk? cutRisk;
  final BaseLoad? baseLoad;
  final SubscriptionCheck? subscription;
  final MonthOutlook? month;

  /// La ligne du budget sur le graphe heure par heure, en Wh.
  final double? hourlyBudgetWh;

  /// Les alertes, celles de la box comprises, des plus récentes aux plus
  /// anciennes.
  final List<EnergyAlert> alerts;
  final BoxTariffs? tariffs;

  const BoxAdvice._({
    required this.raw,
    required this.receivedAt,
    this.weather,
    this.costPerHour,
    this.cutRisk,
    this.baseLoad,
    this.subscription,
    this.month,
    this.hourlyBudgetWh,
    this.alerts = const [],
    this.tariffs,
  });

  /// Décode la réponse ; `null` si ce n'est pas celle de la route (box
  /// ancienne qui répond 404, page de connexion, corps illisible).
  static BoxAdvice? parse(String body, {DateTime? receivedAt}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map || !decoded.containsKey('at')) return null;
    return fromMap(
      Map<String, dynamic>.from(decoded),
      receivedAt ?? DateTime.now(),
    );
  }

  /// La même chose, avec la météo et le coût de l'instant relus par
  /// `?part=weather` ; le reste ne change pas.
  BoxAdvice withWeather(String body) {
    final part = parse(body);
    if (part == null) return this;
    final merged =
        Map<String, dynamic>.from(raw)
          ..remove('weather')
          ..remove('costPerHour')
          ..addAll({
            for (final key in const ['weather', 'costPerHour'])
              if (part.raw[key] != null) key: part.raw[key],
          });
    return fromMap(merged, receivedAt);
  }

  Map<String, dynamic> toJson() => {
    'raw': raw,
    'receivedAt': receivedAt.millisecondsSinceEpoch,
  };

  static BoxAdvice? fromJson(Map<String, dynamic> json) {
    final raw = json['raw'];
    final at = json['receivedAt'];
    if (raw is! Map || at is! int) return null;
    return fromMap(
      Map<String, dynamic>.from(raw),
      DateTime.fromMillisecondsSinceEpoch(at),
    );
  }

  static BoxAdvice fromMap(Map<String, dynamic> raw, DateTime receivedAt) {
    Map? section(String key) => raw[key] is Map ? raw[key] as Map : null;
    final month = section('month');
    return BoxAdvice._(
      raw: raw,
      receivedAt: receivedAt,
      weather: _weather(section('weather')),
      costPerHour: _num(raw['costPerHour']),
      cutRisk: _cutRisk(section('cutRisk')),
      baseLoad: _baseLoad(section('baseLoad')),
      subscription: _subscription(section('subscription')),
      month: _month(month),
      hourlyBudgetWh: _num(month?['hourlyBudgetWh']),
      alerts: [
        for (final a in raw['alerts'] is List ? raw['alerts'] as List : [])
          if (a is Map)
            EnergyAlert(
              AdviceLevel.values.asNameMap()['${a['level']}'] ??
                  AdviceLevel.info,
              _text(a['title']) ?? '',
              _text(a['text']) ?? '',
            ),
      ],
      tariffs: _tariffs(section('tariffs')),
    );
  }

  static ElectricityWeather? _weather(Map? w) {
    final level = PriceLevel.values.asNameMap()['${w?['level']}'];
    if (w == null || level == null) return null;
    return ElectricityWeather(
      level: level,
      title: _text(w['title']) ?? '',
      advice: _text(w['text']) ?? '',
      pricePerKWh: _num(w['price']),
      tomorrow: TempoColor.values.asNameMap()['${w['tomorrow']}'],
    );
  }

  static CutRisk? _cutRisk(Map? r) {
    final level = RiskLevel.values.asNameMap()['${r?['level']}'];
    final ratio = _num(r?['ratio']);
    if (r == null || level == null || ratio == null) return null;
    return CutRisk(
      ratio,
      level,
      averaged: r['averaged'] == true,
      phase: _int(r['phase']),
      boxLabel: _text(r['label']),
      boxAdvice: _text(r['text']),
    );
  }

  static BaseLoad? _baseLoad(Map? b) {
    final watts = _int(b?['w']);
    if (b == null || watts == null) return null;
    return BaseLoad(
      watts,
      _num(b['eurYear']),
      hour: _int(b['hour']),
      hours: [
        for (final h in b['hours'] is List ? b['hours'] as List : [])
          if (h is List && h.length >= 2)
            if ((_int(h[0]), _int(h[1])) case (final hour?, final wh?))
              (
                hour: hour,
                wh: wh,
                producedWh: h.length > 2 ? _int(h[2]) ?? 0 : 0,
              ),
      ],
      text: _text(b['text']),
    );
  }

  static SubscriptionCheck? _subscription(Map? s) {
    final kva = _int(s?['kva']);
    if (s == null || kva == null) return null;
    return SubscriptionCheck(
      subscribedKVA: kva,
      peakVA: _int(s['peakVA']) ?? 0,
      days: _int(s['days']) ?? 0,
      suggestedKVA: _int(s['suggestedKva']),
      tight: s['tight'] == true,
      phasePeakVA: _int(s['phasePeakVA']),
      phaseLimitVA: _int(s['phaseLimitVA']),
      days30Over80: _int(s['days30Over80']),
      limitVA: _int(s['limitVA']),
      months: [
        for (final m in s['months'] is List ? s['months'] as List : [])
          if (m is List && m.length >= 2)
            if ((_text(m[0]), _int(m[1])) case (final month?, final va?))
              (month: month, va: va),
      ],
      text: _text(s['text']),
    );
  }

  static MonthOutlook? _month(Map? m) {
    final soFar = _num(m?['soFar']);
    final projected = _num(m?['projected']);
    if (m == null || soFar == null || projected == null) return null;
    return MonthOutlook(
      soFar,
      projected,
      euros: m['unit'] == 'EUR',
      budget: _num(m['budget']),
      daily: [
        for (final d in m['daily'] is List ? m['daily'] as List : [])
          _num(d) ?? 0,
      ],
    );
  }

  static BoxTariffs? _tariffs(Map? t) {
    if (t == null) return null;
    // Pas encore prête : la box dit pourquoi, et dans combien de jours.
    if (t.containsKey('needDays')) {
      return BoxTariffs(text: _text(t['text']));
    }
    List<OptionCost> costs(Object? list) => [
      for (final c in list is List ? list : [])
        if (c is Map)
          if (TariffOption.values.asNameMap()['${c['option']}']
              case final option?)
            OptionCost(
              option,
              _int(c['kva']) ?? 0,
              _num(c['energy']) ?? 0,
              _num(c['subscription']) ?? 0,
            ),
    ];
    final period = costs(t['period']);
    final year = costs(t['year']);
    if (period.isEmpty || year.isEmpty) return null;
    return BoxTariffs(
      text: _text(t['text']),
      comparison: TariffComparison(
        current: TariffOption.values.asNameMap()['${t['current']}'],
        days: _int(t['days']) ?? 0,
        offPeakShare: _num(t['offPeakShare']) ?? 0,
        offPeakSource:
            t['offPeakSource'] == 'hours'
                ? OffPeakSource.hours
                : OffPeakSource.daily,
        redDays: _int(t['redDays']) ?? 0,
        whiteDays: _int(t['whiteDays']) ?? 0,
        period: period,
        year: year,
        cheapestOption: TariffOption.values.asNameMap()['${t['cheapest']}'],
        savingYear: _num(t['savingYear']),
        text: _text(t['text']),
        colorsKnown: _int(t['colorsKnown']),
        seasonMeasured: t['seasonMeasured'] == true,
        gridFrom: DateTime.tryParse('${t['gridFrom']}'),
        gridOutdated: t['gridOutdated'] == true,
      ),
    );
  }

  static double? _num(Object? raw) => raw is num ? raw.toDouble() : null;

  static int? _int(Object? raw) => raw is num ? raw.round() : null;

  static String? _text(Object? raw) {
    final s = raw is String ? raw.trim() : '';
    return s.isEmpty ? null : s;
  }
}

/// La comparaison des tarifs selon la box : prête, ou pas encore, avec la
/// raison à afficher à la place du tableau.
class BoxTariffs {
  final TariffComparison? comparison;
  final String? text;

  const BoxTariffs({this.comparison, this.text});
}

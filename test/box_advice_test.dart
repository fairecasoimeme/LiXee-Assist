import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zigpower_connect/services/box_advice.dart';
import 'package:zigpower_connect/services/energy_advice.dart';
import 'package:zigpower_connect/services/energy_detail_service.dart';
import 'package:zigpower_connect/services/tariff_compare.dart';
import 'package:zigpower_connect/services/widget_data_service.dart';

/// La réponse complète de `/api/energy/advice`, d'après le brief du
/// firmware v3.3.
const _full = '''
{
  "at": 1795261176,
  "weather": {
    "code": "weather.expensive", "level": "expensive",
    "title": "Heures pleines · jour blanc",
    "text": "Jour blanc : l'électricité est plus chère.",
    "price": 0.1921, "next": "22:00", "today": "white", "tomorrow": "red"
  },
  "costPerHour": 0.42,
  "cutRisk": {
    "level": "medium", "label": "À surveiller", "ratio": 0.74,
    "averaged": true, "phase": null,
    "text": "Évite d'allumer un autre gros appareil en même temps."
  },
  "baseLoad": {
    "w": 180, "hour": 3, "kwhYear": 1577, "eurYear": 290,
    "hours": [[15, 471, 300], [3, 180, 0]],
    "text": "Même au plus calme, la maison consomme 180 W."
  },
  "subscription": {
    "kva": 9, "peakVA": 5200, "days": 63, "tight": false, "suggestedKva": 6,
    "days30Over80": 0, "basis": "total", "limitVA": 9000,
    "months": [["2026-10", 5200], ["2026-11", 6100]],
    "text": "Ton plus fort appel est de 5.2 kVA."
  },
  "month": {
    "soFar": 41.2, "projected": 63.5, "unit": "EUR", "days": 30,
    "budget": 60, "hourlyBudgetWh": 410, "budgetDay": 2.0,
    "daily": [1.97, 2.17]
  },
  "alerts": [
    { "code": "box.color_tomorrow", "level": "warning", "title": "Demain, jour rouge",
      "text": "Programme les machines ce soir.", "at": 1795258000 },
    { "code": "alert.yesterday_low", "level": "info",
      "title": "Bravo : hier, 18 % de moins", "text": "Continue comme ça." }
  ],
  "tariffs": {
    "current": "tempo", "days": 31, "offPeakShare": 0.41, "offPeakSource": "hours",
    "redDays": 2, "whiteDays": 5, "colorsKnown": 31,
    "gridFrom": "2026-08-01", "gridOutdated": false, "seasonMeasured": true,
    "period": [
      { "option": "base", "label": "Base", "kva": 9, "energy": 95.3, "subscription": 20.37, "total": 115.67 },
      { "option": "tempo", "label": "Tempo", "kva": 9, "energy": 80.1, "subscription": 20.16, "total": 100.26 }
    ],
    "year": [
      { "option": "base", "label": "Base", "kva": 9, "energy": 1100, "subscription": 239.84, "total": 1339.84 },
      { "option": "tempo", "label": "Tempo", "kva": 9, "energy": 1015, "subscription": 237.34, "total": 1252.34 }
    ],
    "cheapest": "tempo",
    "text": "Au tarif réglementé, ton option actuelle (Tempo) est la moins chère."
  }
}
''';

LinkySnapshot _snapshot({int? power, List<HourlySample> hourly = const []}) =>
    LinkySnapshot(
      deviceName: 'maison',
      timestamp: DateTime.now(),
      source: LinkySource.local,
      apparentPowerVA: power,
      subscribedCurrentA: 45,
      hourly: hourly,
    );

void main() {
  group('décodage', () {
    test('réponse complète', () {
      final a = BoxAdvice.parse(_full)!;

      expect(a.weather!.level, PriceLevel.expensive);
      expect(a.weather!.title, 'Heures pleines · jour blanc');
      expect(a.weather!.advice, startsWith('Jour blanc'));
      expect(a.weather!.pricePerKWh, 0.1921);
      expect(a.weather!.tomorrow, TempoColor.red);
      expect(a.costPerHour, 0.42);

      expect(a.cutRisk!.level, RiskLevel.medium);
      expect(a.cutRisk!.ratio, 0.74);
      expect(a.cutRisk!.averaged, isTrue);
      expect(a.cutRisk!.phase, isNull);
      expect(a.cutRisk!.label, 'À surveiller');
      expect(a.cutRisk!.advice, startsWith('Évite'));

      expect(a.baseLoad!.watts, 180);
      expect(a.baseLoad!.hour, 3);
      expect(a.baseLoad!.yearlyEur, 290);
      expect(a.baseLoad!.hours.first, (hour: 15, wh: 471, producedWh: 300));
      expect(a.baseLoad!.text, startsWith('Même au plus calme'));

      final s = a.subscription!;
      expect(s.subscribedKVA, 9);
      expect(s.peakVA, 5200);
      expect(s.days, 63);
      expect(s.suggestedKVA, 6);
      expect(s.tight, isFalse);
      expect(s.measured, isTrue);
      expect(s.limitVA, 9000);
      expect(s.months.last, (month: '2026-11', va: 6100));

      expect(a.month!.soFar, 41.2);
      expect(a.month!.projected, 63.5);
      expect(a.month!.euros, isTrue);
      expect(a.month!.budget, 60);
      expect(a.month!.daily, [1.97, 2.17]);
      expect(a.hourlyBudgetWh, 410);

      expect(a.alerts, hasLength(2));
      expect(a.alerts.first.level, AdviceLevel.warning);
      expect(a.alerts.first.title, 'Demain, jour rouge');
      expect(a.alerts.first.message, 'Programme les machines ce soir.');

      final t = a.tariffs!.comparison!;
      expect(t.current, TariffOption.tempo);
      expect(t.days, 31);
      expect(t.offPeakSource, OffPeakSource.hours);
      expect(t.redDays, 2);
      expect(t.colorsKnown, 31);
      expect(t.seasonMeasured, isTrue);
      expect(t.gridFrom, DateTime(2026, 8, 1));
      expect(t.period, hasLength(2));
      expect(t.costOf(TariffOption.tempo, yearly: true)!.totalEur, 1252.34);
      expect(t.text, startsWith('Au tarif réglementé'));
    });

    test('la moins chère est celle de la box, choisie sur un an', () {
      // Sur la période, Tempo paraît moins cher ; la box retient Base.
      final body = jsonDecode(_full) as Map<String, dynamic>;
      (body['tariffs'] as Map)['cheapest'] = 'base';
      final t = BoxAdvice.parse(jsonEncode(body))!.tariffs!.comparison!;
      expect(t.cheapest.option, TariffOption.base);
    });

    test('sections absentes', () {
      final a = BoxAdvice.parse('{"at": 1795261176, "alerts": []}')!;
      expect(a.weather, isNull);
      expect(a.costPerHour, isNull);
      expect(a.cutRisk, isNull);
      expect(a.baseLoad, isNull);
      expect(a.subscription, isNull);
      expect(a.month, isNull);
      expect(a.tariffs, isNull);
      expect(a.alerts, isEmpty);
    });

    test('comparaison pas encore prête', () {
      final a =
          BoxAdvice.parse(
            '{"at": 1, "alerts": [], "tariffs": {"needDays": 7, "days": 1, '
            '"text": "Comparaison disponible dans 6 jours."}}',
          )!;
      expect(a.tariffs!.comparison, isNull);
      expect(a.tariffs!.text, 'Comparaison disponible dans 6 jours.');
    });

    test('la météo seule complète le reste', () {
      final a = BoxAdvice.parse(_full)!;
      final b = a.withWeather(
        '{"at": 1795261300, "weather": {"level": "cheap", '
        '"title": "Heures creuses · jour blanc", "text": "C\'est le bon moment."}, '
        '"costPerHour": 0.12}',
      );
      expect(b.weather!.level, PriceLevel.cheap);
      expect(b.weather!.pricePerKWh, isNull);
      expect(b.costPerHour, 0.12);
      // Le reste ne bouge pas.
      expect(b.baseLoad!.watts, 180);
      expect(b.alerts, hasLength(2));
      expect(b.receivedAt, a.receivedAt);
    });

    test('box ancienne : 404, page de connexion ou autre JSON', () {
      expect(BoxAdvice.parse('Not found'), isNull);
      expect(BoxAdvice.parse('<html><body>Login</body></html>'), isNull);
      expect(BoxAdvice.parse('{"error": "unknown route"}'), isNull);
      expect(BoxAdvice.parse('[]'), isNull);
    });

    test('gardée entre deux lancements', () {
      final extras = const EnergyExtras().withAdvice(BoxAdvice.parse(_full));
      final back = EnergyExtras.fromJson(
        jsonDecode(jsonEncode(extras.toJson())) as Map<String, dynamic>,
      );
      expect(back.advice!.baseLoad!.watts, 180);
      expect(
        back.advice!.receivedAt.millisecondsSinceEpoch,
        extras.advice!.receivedAt.millisecondsSinceEpoch,
      );
    });
  });

  group('le kiosque affiche la box sans recalculer', () {
    // De quoi faire un calcul local tout différent : heures pleines d'un
    // jour rouge, 30 heures relevées.
    final snapshot = _snapshot(
      power: 8000,
      hourly: [for (var h = 0; h < 30; h++) HourlySample(h % 24, 500 + h, 0)],
    );
    const tariff = TariffNow(
      label: 'HP Rouge',
      isTempo: true,
      today: TempoColor.red,
      price: 0.7295,
    );

    test('avec la route, tout vient de la box', () {
      final extras = const EnergyExtras(
        tariff: tariff,
      ).withAdvice(BoxAdvice.parse(_full));
      expect(
        EnergyAdvice.weather(snapshot, extras)!.level,
        PriceLevel.expensive,
      );
      expect(EnergyAdvice.costPerHour(snapshot, extras), 0.42);
      expect(EnergyAdvice.cutRisk(snapshot, extras)!.ratio, 0.74);
      expect(EnergyAdvice.baseLoad(snapshot, extras)!.watts, 180);
      expect(EnergyAdvice.hourlyBudgetWh(snapshot, extras), 410);
      expect(EnergyAdvice.month(extras, DateTime.now())!.soFar, 41.2);
      expect(EnergyAdvice.yesterday(extras), isNull);
      expect(EnergyAdvice.alerts(snapshot, extras).map((a) => a.title), [
        'Demain, jour rouge',
        'Bravo : hier, 18 % de moins',
      ]);
      expect(
        EnergyAdvice.subscription(
          snapshot,
          const {},
          box: extras.advice,
        )!.suggestedKVA,
        6,
      );
    });

    test('une section absente reste absente', () {
      final extras = const EnergyExtras(
        tariff: tariff,
      ).withAdvice(BoxAdvice.parse('{"at": 1, "alerts": []}'));
      expect(EnergyAdvice.weather(snapshot, extras), isNull);
      expect(EnergyAdvice.baseLoad(snapshot, extras), isNull);
      expect(EnergyAdvice.alerts(snapshot, extras), isEmpty);
    });

    test('un risque de coupure trop vieux cède à la mesure de la minute', () {
      final old = BoxAdvice.parse(
        _full,
        receivedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      final extras = const EnergyExtras().withAdvice(old);
      // Plus de risque de la box, et pas de quoi le calculer ici.
      expect(EnergyAdvice.cutRisk(_snapshot(), extras), isNull);
    });

    test('sans la route, le calcul local reprend', () {
      const extras = EnergyExtras(tariff: tariff);
      final weather = EnergyAdvice.weather(snapshot, extras)!;
      expect(weather.level, PriceLevel.peak);
      expect(weather.pricePerKWh, 0.7295);
      expect(EnergyAdvice.baseLoad(snapshot, extras)!.watts, 500);
    });
  });
}

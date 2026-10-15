import 'package:flutter_test/flutter_test.dart';
import 'package:zigpower_connect/services/energy_advice.dart';
import 'package:zigpower_connect/services/energy_detail_service.dart';
import 'package:zigpower_connect/services/widget_data_service.dart';

LinkySnapshot _snapshot({
  int? power,
  int? subscribedA,
  int? injected,
  int? maxToday,
  List<HourlySample> hourly = const [],
}) => LinkySnapshot(
  deviceName: 'maison',
  timestamp: DateTime.now(),
  source: LinkySource.local,
  apparentPowerVA: power,
  subscribedCurrentA: subscribedA,
  productionPowerVA: injected,
  maxPowerTodayVA: maxToday,
  hourly: hourly,
);

EnergyExtras _extras(
  TariffNow tariff, {
  Map<int, double> prices = const {},
  List<UtilityMeter> utilities = const [],
}) => EnergyExtras(tariff: tariff, prices: prices, utilities: utilities);

void main() {
  group('tarif en cours', () {
    test('lit la réponse de la box', () {
      final t =
          TariffNow.parse(
            '{"show":true,"tariff":"HP Rouge","bgColor":"#c0392b","isTempo":true,'
            '"today":{"class":"tempo-rouge","label":"Jour Rouge","icon":"R"},'
            '"tomorrow":{"class":"tempo-bleu","label":"Jour Bleu","icon":"B"}}',
          )!;
      expect(t.isTempo, isTrue);
      expect(t.today, TempoColor.red);
      expect(t.tomorrow, TempoColor.blue);
      expect(t.attribute, 266);
    });

    test('sans ZLinky, pas de tarif', () {
      expect(TariffNow.parse('{"show":false,"tariff":"---"}'), isNull);
    });

    test('index tarifaire en cours', () {
      expect(const TariffNow(label: 'Base').attribute, 256);
      expect(const TariffNow(label: 'Heures Creuses').attribute, 256);
      expect(const TariffNow(label: 'Heures Pleines').attribute, 258);
      expect(const TariffNow(label: 'Pointe Mobile').attribute, 258);
      expect(
        const TariffNow(
          label: 'HC Blanc',
          isTempo: true,
          today: TempoColor.white,
        ).attribute,
        260,
      );
    });

    test('prix saisis sur la box', () {
      expect(
        EnergyDetailService.parsePrices(
          '{"tarifIdx1":"0","tarifIdx2":"0.1612","tarifIdx3":"0,2068",'
          '"tarifIdx4":"0","passHTTP":"secret"}',
        ),
        {256: 0.1612, 258: 0.2068},
      );
    });

    test('le tarif survit à l\'enregistrement', () {
      const extras = EnergyExtras(
        prices: {256: 0.16},
        tariff: TariffNow(
          label: 'HC Bleu',
          isTempo: true,
          today: TempoColor.blue,
          tomorrow: TempoColor.red,
        ),
      );
      final restored = EnergyExtras.fromJson(extras.toJson());
      expect(restored.prices, {256: 0.16});
      expect(restored.tariff!.tomorrow, TempoColor.red);
    });
  });

  group('météo de l\'électricité', () {
    test('heures creuses : le bon moment, avec le prix', () {
      final w =
          EnergyAdvice.weather(
            _snapshot(),
            _extras(
              const TariffNow(label: 'Heures Creuses'),
              prices: {256: 0.16, 258: 0.21},
            ),
          )!;
      expect(w.level, PriceLevel.cheap);
      expect(w.title, 'Heures creuses');
      expect(w.pricePerKWh, 0.16);
    });

    test('jour rouge en heures pleines : à éviter', () {
      final w =
          EnergyAdvice.weather(
            _snapshot(),
            _extras(
              const TariffNow(
                label: 'HP Rouge',
                isTempo: true,
                today: TempoColor.red,
                tomorrow: TempoColor.white,
              ),
            ),
          )!;
      expect(w.level, PriceLevel.peak);
      expect(w.title, 'Heures pleines · jour rouge');
      expect(w.pricePerKWh, isNull);
      expect(w.tomorrow, TempoColor.white);
    });

    test('le surplus solaire prime, sauf en jour rouge', () {
      final hp =
          EnergyAdvice.weather(
            _snapshot(injected: 800),
            _extras(const TariffNow(label: 'Heures Pleines')),
          )!;
      expect(hp.level, PriceLevel.surplus);

      final red =
          EnergyAdvice.weather(
            _snapshot(injected: 800),
            _extras(
              const TariffNow(
                label: 'HP Rouge',
                isTempo: true,
                today: TempoColor.red,
              ),
            ),
          )!;
      expect(red.level, PriceLevel.peak);
    });

    test('tarif unique', () {
      final w =
          EnergyAdvice.weather(
            _snapshot(),
            _extras(const TariffNow(label: 'Base')),
          )!;
      expect(w.level, PriceLevel.flat);
      expect(w.title, 'Tarif Base');
    });

    test('sans tarif connu, pas de météo', () {
      expect(EnergyAdvice.weather(_snapshot(), null), isNull);
    });
  });

  test('coût à l\'heure, seulement avec un prix', () {
    const tariff = TariffNow(label: 'Heures Pleines');
    expect(
      EnergyAdvice.costPerHour(
        _snapshot(power: 2000),
        _extras(tariff, prices: {258: 0.2}),
      ),
      closeTo(0.4, 1e-9),
    );
    expect(
      EnergyAdvice.costPerHour(_snapshot(power: 2000), _extras(tariff)),
      isNull,
    );
  });

  group('consommation plancher', () {
    final day = [
      for (var h = 0; h < 24; h++) HourlySample(h, h == 4 ? 150 : 600),
      // L'heure en cours, incomplète, ne compte pas.
      const HourlySample(0, 20),
    ];

    test('l\'heure la plus calme, en watts et en euros par an', () {
      final load =
          EnergyAdvice.baseLoad(
            _snapshot(hourly: day),
            _extras(const TariffNow(label: 'Base'), prices: {256: 0.2}),
          )!;
      expect(load.watts, 150);
      expect(load.yearlyKWh, closeTo(1314, 0.1));
      expect(load.yearlyEur, closeTo(262.8, 0.1));
    });

    test('chez un producteur, les heures de production ne comptent pas', () {
      // En journée, le soleil fait tomber le soutirage à 50 Wh : ce n'est
      // pas le plancher de la maison, qui est de 300 W la nuit.
      final load =
          EnergyAdvice.baseLoad(
            _snapshot(
              hourly: [
                for (var h = 0; h < 24; h++)
                  h >= 9 && h <= 17
                      ? HourlySample(h, 50, 0, 1200)
                      : HourlySample(h, h == 3 ? 300 : 700),
                const HourlySample(0, 20),
              ],
            ),
            null,
          )!;
      expect(load.watts, 300);
    });

    test('sans prix, en kWh seulement', () {
      final load = EnergyAdvice.baseLoad(_snapshot(hourly: day), null)!;
      expect(load.yearlyEur, isNull);
    });

    test('pas assez d\'heures', () {
      expect(
        EnergyAdvice.baseLoad(
          _snapshot(hourly: [for (var h = 0; h < 6; h++) HourlySample(h, 100)]),
          null,
        ),
        isNull,
      );
    });
  });

  group('alertes', () {
    test('puissance proche du maximum', () {
      final alerts = EnergyAdvice.alerts(
        _snapshot(power: 8300, subscribedA: 45),
        null,
      );
      expect(alerts.single.level, AdviceLevel.danger);
    });

    test('demain jour rouge', () {
      final alerts = EnergyAdvice.alerts(
        _snapshot(power: 500, subscribedA: 45),
        _extras(
          const TariffNow(
            label: 'HC Bleu',
            isTempo: true,
            today: TempoColor.blue,
            tomorrow: TempoColor.red,
          ),
        ),
      );
      expect(alerts.single.title, 'Demain, jour rouge');
    });

    UtilityMeter water(List<double> values, int firstHour) => UtilityMeter(
      kind: UtilityKind.water,
      unit: 'L',
      hourly: [
        for (final (i, v) in values.indexed)
          UtilitySample((firstHour + i) % 24, v),
      ],
    );

    test('l\'eau qui coule toute la nuit', () {
      final alerts = EnergyAdvice.alerts(
        _snapshot(),
        _extras(
          const TariffNow(label: 'Base'),
          utilities: [
            water([0, 0, 3, 2, 4, 3, 5], 0),
          ],
        ),
      );
      expect(alerts.single.title, "Fuite d'eau possible");
      expect(alerts.single.message, contains('4 heures'));
    });

    test('une douche en journée n\'est pas une fuite', () {
      final alerts = EnergyAdvice.alerts(
        _snapshot(),
        _extras(
          const TariffNow(label: 'Base'),
          utilities: [
            water([0, 40, 30, 20, 25, 0], 14),
          ],
        ),
      );
      expect(alerts, isEmpty);
    });
  });

  group('abonnement', () {
    Map<String, int> peaks(int days, int va) => {
      for (var d = 1; d <= days; d++)
        '2026-10-${d.toString().padLeft(2, '0')}': va,
    };

    test('trop gros : un palier plus bas suffit', () {
      final check =
          EnergyAdvice.subscription(
            _snapshot(subscribedA: 45, maxToday: 4200),
            peaks(20, 4200),
          )!;
      expect(check.subscribedKVA, 9);
      expect(check.suggestedKVA, 6);
    });

    test('sans pic publié par le compteur, aucun conseil à la baisse', () {
      final check =
          EnergyAdvice.subscription(
            _snapshot(subscribedA: 45),
            peaks(20, 4200),
          )!;
      expect(check.measured, isFalse);
      expect(check.suggestedKVA, isNull);
    });

    test('bien taillé : rien à conseiller', () {
      final check =
          EnergyAdvice.subscription(
            _snapshot(subscribedA: 45),
            peaks(20, 7000),
          )!;
      expect(check.suggestedKVA, isNull);
    });

    test('pas de conseil avant deux semaines', () {
      final check =
          EnergyAdvice.subscription(
            _snapshot(subscribedA: 45),
            peaks(5, 2000),
          )!;
      expect(check.days, 5);
      expect(check.suggestedKVA, isNull);
    });
  });

  group('triphasé', () {
    // Relevé réel d'un compteur standard tri de 3 kVA (box « test »).
    final tri = LinkySnapshot.fromLinkyJson(
      {
        '2820_1295': 9,
        '2820_2319': 11,
        '2820_2575': 0,
        '2817_13': 3,
        '65382_768': 3,
      },
      deviceName: 'test',
      source: LinkySource.local,
    );

    test('une puissance par phase, et le total pour la jauge', () {
      expect(tri.threePhase, isTrue);
      expect(tri.phasePowersVA, [9, 11, 0]);
      expect(tri.apparentPowerVA, 20);
    });

    test('en standard, la puissance souscrite est en kVA', () {
      expect(tri.subscribedPowerVA, 3000);
      expect(tri.phaseLimitVA, 1000);
    });

    test('en historique tri, l\'intensité vaut pour chaque phase', () {
      final s = LinkySnapshot.fromLinkyJson(
        {
          '2820_1295': 900,
          '2820_2319': 500,
          '2820_2575': 300,
          '2817_13': 15,
          '65382_768': 2,
        },
        deviceName: 'tri',
        source: LinkySource.local,
      );
      expect(s.subscribedPowerVA, 9000);
      expect(s.phaseLimitVA, 3000);
    });

    test('monophasé : une seule jauge, et l\'historique en ampères', () {
      final s = LinkySnapshot.fromLinkyJson(
        {'2820_1295': 400, '2817_13': 45, '65382_768': 0},
        deviceName: 'mono',
        source: LinkySource.local,
      );
      expect(s.threePhase, isFalse);
      expect(s.apparentPowerVA, 400);
      expect(s.subscribedPowerVA, 9000);
    });

    test('les phases survivent à l\'enregistrement', () {
      final restored = LinkySnapshot.fromJson(tri.toJson());
      expect(restored.phasePowersVA, [9, 11, 0]);
      expect(restored.subscribedPowerVA, 3000);
    });
  });

  group('ligne du budget', () {
    // 24 heures à 500 Wh et 0,10 € : 5 Wh par centime.
    final day = [for (var h = 0; h < 24; h++) HourlySample(h, 500, 0.10)];

    test('budget du mois rapporté à l\'heure, au coût réel', () {
      // 93 € sur octobre (31 jours) : 0,125 € par heure, soit 625 Wh.
      final wh = EnergyAdvice.hourlyBudgetWh(
        _snapshot(hourly: day),
        const EnergyExtras(thresholds: BoxThresholds(monthBudgetEur: 93)),
        now: DateTime(2026, 10, 14),
      );
      expect(wh, closeTo(625, 1e-6));
    });

    test('pas de ligne sans budget', () {
      expect(
        EnergyAdvice.hourlyBudgetWh(_snapshot(hourly: day), const EnergyExtras()),
        isNull,
      );
    });
  });

  test('un relevé raté garde le tarif et les prix connus', () {
    const known = EnergyExtras(
      prices: {256: 0.16},
      tariff: TariffNow(label: 'Heures Creuses'),
      thresholds: BoxThresholds(monthBudgetEur: 80),
    );
    final merged = const EnergyExtras().keeping(known);
    expect(merged.tariff?.label, 'Heures Creuses');
    expect(merged.prices, {256: 0.16});
    expect(merged.thresholds.monthBudgetEur, 80);
  });

  group('seuils de la box', () {
    test('lus dans Config → Notifications', () {
      final t = EnergyDetailService.parseThresholds(
        '{"OverBudget":1,"OverBudgetThreshold":"80","OverPower":0,'
        '"OverPowerThreshold":6000,"DailyAnomaly":1,"DailyAnomalyPercent":50,'
        '"NightWaterLeak":1,"NightWaterLeakThreshold":3,"passHTTP":"secret"}',
      );
      expect(t.monthBudgetEur, 80);
      expect(t.overPowerW, isNull);
      expect(t.anomalyPercent, 50);
      expect(t.nightWaterLitres, 3);
    });

    test('la surpuissance suit le seuil de la box', () {
      final alerts = EnergyAdvice.alerts(
        _snapshot(power: 6200, subscribedA: 60),
        const EnergyExtras(thresholds: BoxThresholds(overPowerW: 6000)),
      );
      expect(alerts.single.level, AdviceLevel.danger);
    });

    test('fuite nocturne au-delà du seuil en litres', () {
      final alerts = EnergyAdvice.alerts(
        _snapshot(),
        EnergyExtras(
          thresholds: const BoxThresholds(nightWaterLitres: 3),
          utilities: [
            UtilityMeter(
              kind: UtilityKind.water,
              unit: 'L',
              hourly: [
                for (var h = 18; h < 24; h++) UtilitySample(h, 20),
                for (var h = 0; h < 5; h++) UtilitySample(h, 1),
                for (var h = 5; h < 18; h++) UtilitySample(h, 10),
              ],
            ),
          ],
        ),
      );
      expect(alerts.single.message, contains('5 litres'));
    });
  });

  group('délestage', () {
    test('appareils réglés sur la box', () {
      expect(
        EnergyDetailService.parseSheddingDevices(
          '{"delestage":"00158d0001020304,bad,00158d0001020305"}',
        ),
        ['00158d0001020304', '00158d0001020305'],
      );
      expect(
        EnergyDetailService.parseSheddingDevices('{"delestage":"null"}'),
        isEmpty,
      );
    });

    test('dernier déclenchement', () {
      expect(
        EnergyDetailService.parseSheddingLastAt(
          '{"state":"1","dateOn":"12/01/2026 18:42","00158d0001020304":"01"}',
        ),
        '12/01/2026 18:42',
      );
      expect(EnergyDetailService.parseSheddingLastAt('{"state":"0"}'), isNull);
    });
  });

  group('jour par jour', () {
    test('lit l\'export de la box', () {
      final days = EnergyDetailService.parseDailyCsv(
        '﻿Periode;HC / EJPHN / BBRHCJB / EASF01 (Wh);'
        'Consommation totale (Wh);Conso - Energie (EUR);'
        'Conso - Abonnement (EUR);Conso - Taxes (EUR);Conso - Cout total (EUR)\r\n'
        '30/09;8100;8100;1,20;0,50;0,10;1,80\r\n'
        '01/10;6000;6000;0,90;0,50;0,08;1,48\r\n',
      );
      expect(days.map((d) => '${d.day}/${d.month}:${d.wh}'), [
        '30/9:8100',
        '1/10:6000',
      ]);
      expect(days.last.costEur, closeTo(1.48, 1e-9));
    });

    EnergyExtras history(List<int> wh, {double euro = 0}) => EnergyExtras(
      daily: [for (final (i, v) in wh.indexed) DailySample(i + 1, 10, v, euro)],
    );

    test('le mois en cours et sa projection', () {
      // Dix jours à 2 € : le 10 à midi, 9,5 jours sont écoulés.
      final month =
          EnergyAdvice.month(
            history(List.filled(10, 5000), euro: 2),
            DateTime(2026, 10, 10, 12),
          )!;
      expect(month.euros, isTrue);
      expect(month.soFar, closeTo(20, 1e-9));
      expect(month.projected, closeTo(20 / 9.5 * 31, 1e-6));
    });

    test('sans prix, le mois se compte en kWh', () {
      final month =
          EnergyAdvice.month(
            history(List.filled(5, 4000)),
            DateTime(2026, 10, 5, 12),
          )!;
      expect(month.euros, isFalse);
      expect(month.soFar, closeTo(20, 1e-9));
    });

    test('hier, bien au-dessus de l\'habitude', () {
      final alert =
          EnergyAdvice.yesterday(
            history([...List.filled(7, 10000), 14000, 3000]),
          )!;
      expect(alert.level, AdviceLevel.warning);
      expect(alert.title, contains('+40 %'));
    });

    test('hier, bien en dessous : on félicite', () {
      final alert =
          EnergyAdvice.yesterday(
            history([...List.filled(7, 10000), 8000, 3000]),
          )!;
      expect(alert.title, startsWith('Bravo'));
    });

    test('un jour ordinaire ne dit rien', () {
      expect(
        EnergyAdvice.yesterday(
          history([...List.filled(7, 10000), 10500, 3000]),
        ),
        isNull,
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:zigpower_connect/services/box_energy_api.dart';
import 'package:zigpower_connect/services/energy_advice.dart';
import 'package:zigpower_connect/services/energy_detail_service.dart';
import 'package:zigpower_connect/services/widget_data_service.dart';

// Exemples tirés de la description des routes du firmware v2.26.
void main() {
  group('/api/energy/config', () {
    const body =
        '{"zlinky":"00158d0001a2b3c4","production":"","gaz":"",'
        '"waterIeee":"00158d0009f8e7d6","linkyMode":1,'
        '"prices":{"256":0.1612,"258":0.2068},'
        '"subscription":{"abo":15.65,"cspe":0.0225,"cta":1.2},'
        '"gas":{"price":0.12,"coeff":10,"unit":"m3"},'
        '"water":{"price":0.004,"coeff":1.5,"unit":"L"},'
        '"subMeters":[{"index":0,"ieee":"a4c1380000000002","alias":"Véhicule",'
        '"color":"#e74c3c","enabled":true}],'
        '"thresholds":{"budget":{"enabled":true,"monthEur":80},'
        '"overPower":{"enabled":false,"w":6000},'
        '"dailyAnomaly":{"enabled":true,"percent":40},'
        '"nightWaterLeak":{"enabled":true,"litres":2},'
        '"waterLeak":{"enabled":false,"litres":5},'
        '"freeze":{"enabled":false,"centiDeg":300,"sensor":""}},'
        '"delestage":["a4c1380000000001"]}';

    test('prix, compteurs, seuils et délestage', () {
      final c = ApiEnergyConfig.parse(body)!;
      expect(c.zlinky, '00158d0001a2b3c4');
      expect(c.prices, {256: 0.1612, 258: 0.2068});
      expect(c.gas, isNull, reason: 'pas de compteur de gaz déclaré');
      expect(c.water!.ieee, '00158d0009f8e7d6');
      expect(c.water!.coefficient, 1.5);
      expect(c.subMeterColors, {'Véhicule': 0xe74c3c});
      expect(c.monthBudgetEur, 80);
      expect(c.overPowerW, isNull, reason: 'alerte désactivée');
      expect(c.anomalyPercent, 40);
      expect(c.nightWaterLitres, 2);
      expect(c.sheddingDevices, ['a4c1380000000001']);
    });

    test('une page de connexion n\'est pas une configuration', () {
      expect(ApiEnergyConfig.parse('<html>login</html>'), isNull);
      expect(ApiEnergyConfig.parse('{"error":"unauthorized"}'), isNull);
    });
  });

  test('/api/delestage', () {
    final s =
        ApiShedding.parse(
          '{"active":true,"since":"14/10/2026 18:42","lastEnd":"13/10/2026 07:15",'
          '"reason":"meter","restoreMinutes":5,"restorePercent":80,'
          '"anticipationPercent":0,"minuteVA":5230,"minuteLoadPercent":58,'
          '"subscribedVA":9000,'
          '"devices":[{"ieee":"a4c1380000000001","name":"Radiateur salon","cut":true}]}',
        )!;
    expect(s.active, isTrue);
    expect(s.since, '14/10/2026 18:42');
    expect(s.restoreMinutes, 5);
    expect(s.devices.single.name, 'Radiateur salon');
    expect(s.devices.single.cut, isTrue);
    expect(s.minuteLoadPercent, 58);
    expect(
      ApiShedding.parse(
        '{"active":false,"minuteLoadPercent":-1}',
      )!.minuteLoadPercent,
      isNull,
    );
  });

  group('risque de coupure à la minute', () {
    LinkySnapshot snap(Map<String, dynamic> json) =>
        LinkySnapshot.fromLinkyJson(
          json,
          deviceName: 'x',
          source: LinkySource.local,
        );
    final now = DateTime.now();

    test("la charge de la box l'emporte sur la puissance de l'instant", () {
      final risk =
          EnergyAdvice.cutRisk(
            snap({'2820_1295': 1000, '2817_13': 9, '65382_768': 1}),
            EnergyExtras(minuteVA: 8000, minuteLoad: 92, minuteAt: now),
          )!;
      expect(risk.ratio, closeTo(0.92, 1e-9));
      expect(risk.level, RiskLevel.high);
      expect(risk.averaged, isTrue);
    });

    test('en triphasé aussi, déjà rapportée à la phase la plus chargée', () {
      final risk =
          EnergyAdvice.cutRisk(
            snap({
              '2820_1295': 900,
              '2820_2319': 100,
              '2820_2575': 0,
              '2817_13': 3,
              '65382_768': 3,
            }),
            EnergyExtras(minuteLoad: 75, minuteAt: now),
          )!;
      expect(risk.ratio, closeTo(0.75, 1e-9));
      expect(risk.level, RiskLevel.medium);
      expect(risk.phase, isNull);
    });

    test('une charge trop ancienne est ignorée', () {
      final risk =
          EnergyAdvice.cutRisk(
            snap({'2820_1295': 900, '2817_13': 9, '65382_768': 1}),
            EnergyExtras(
              minuteLoad: 95,
              minuteAt: now.subtract(const Duration(minutes: 5)),
            ),
          )!;
      expect(risk.ratio, closeTo(0.1, 1e-9));
      expect(risk.averaged, isFalse);
    });
  });

  group('/api/power', () {
    const summary =
        '{"subscribedVA":9000,"bands":[50,60,70,80,90,100],'
        '"worst":{"instVA":{"va":8350,"date":"2026-10-12"},'
        '"va1m":{"va":4100,"date":"2026-10-12"},'
        '"va10m":{"va":3200,"date":"2026-10-12"}},'
        '"frequency":{"80":{"days7":0,"days30":0,"days90":0,"observedDays":88,'
        '"last":null,"rate":"never"},'
        '"90":{"days7":0,"days30":0,"days90":0,"observedDays":88,"last":null,'
        '"rate":"never"}},'
        '"months":[{"month":"2026-01","observedDays":31,"subscribedVA":9000,'
        '"instVA":8000,"va1m":4600,"va10m":3900}]}';

    test('synthèse : le pire de toute la période', () {
      final p = PowerSummary.parse(summary)!;
      expect(p.subscribedVA, 9000);
      // Janvier (4 600 VA) dépasse les 90 derniers jours (4 100 VA).
      expect(p.worstVa1m, 4600);
      expect(p.worstVa10m, 3900);
      expect(p.observedDays, 88);
      expect(p.rates[90], PeakRate.never);
    });

    test('bilan : un palier plus bas suffit', () {
      final check =
          EnergyAdvice.subscription(
            LinkySnapshot(
              deviceName: 'x',
              timestamp: DateTime.now(),
              source: LinkySource.local,
              subscribedCurrentA: 45,
            ),
            const {},
            summary: PowerSummary.parse(summary),
          )!;
      expect(check.tight, isFalse);
      expect(check.suggestedKVA, 6);
    });

    test('bilan : abonnement juste quand on frôle souvent le maximum', () {
      final check =
          EnergyAdvice.subscription(
            LinkySnapshot(
              deviceName: 'x',
              timestamp: DateTime.now(),
              source: LinkySource.local,
              subscribedCurrentA: 45,
            ),
            const {},
            summary: const PowerSummary(
              subscribedVA: 9000,
              worstVa1m: 8700,
              observedDays: 60,
              rates: {90: PeakRate.weekly},
            ),
          )!;
      expect(check.tight, isTrue);
      expect(check.suggestedKVA, isNull);
    });

    group('triphasé', () {
      const tri =
          '{"subscribedVA":12000,"triphase":true,"bands":[50,60,70,80,90,100],'
          '"worst":{"va1m":{"va":7020,"date":"2026-10-12"},'
          '"va10m":{"va":5200,"date":"2026-10-12"},'
          '"phases":[{"phase":1,"va1m":{"va":2100,"date":"2026-10-12"}},'
          '{"phase":2,"va1m":{"va":1500,"date":"2026-10-11"}},'
          '{"phase":3,"va1m":{"va":900,"date":"2026-10-10"}}]},'
          '"frequencyBasis":"phases",'
          '"frequency":{"80":{"days7":0,"days30":0,"days90":0,'
          '"observedDays":40,"last":null,"rate":"never"}},'
          '"months":[{"month":"2026-01","observedDays":31,"subscribedVA":12000,'
          '"va1m":7000,"phases":[{"phase":1,"va1m":2300},{"phase":2,"va1m":1200}]}]}';

      test('le pire de la phase la plus chargée', () {
        final p = PowerSummary.parse(tri)!;
        expect(p.threePhase, isTrue);
        expect(p.phaseLimitVA, 4000);
        expect(p.worstPhaseVa1m, 2300);
        expect(PowerSummary.fromJson(p.toJson()).worstPhaseVa1m, 2300);
      });

      test('le palier se juge sur la phase, pas sur le total', () {
        final check =
            EnergyAdvice.subscription(
              LinkySnapshot(
                deviceName: 'x',
                timestamp: DateTime.now(),
                source: LinkySource.local,
              ),
              const {},
              summary: PowerSummary.parse(tri),
            )!;
        // 2 300 VA sur une phase : 3 × 2 300 × 1,15 ≈ 7,9 kVA, donc 9 kVA,
        // alors que le total (7 020 VA) en aurait proposé autant.
        expect(check.phasePeakVA, 2300);
        expect(check.phaseLimitVA, 4000);
        expect(check.suggestedKVA, 9);
      });
    });

    test('bilan : pas de palier plus bas si 80 % est atteint chaque mois', () {
      final check =
          EnergyAdvice.subscription(
            LinkySnapshot(
              deviceName: 'x',
              timestamp: DateTime.now(),
              source: LinkySource.local,
            ),
            const {},
            summary: const PowerSummary(
              subscribedVA: 9000,
              worstVa1m: 4000,
              observedDays: 60,
              rates: {80: PeakRate.monthly},
              days30Over80: 2,
            ),
          )!;
      expect(check.suggestedKVA, isNull);
      expect(check.days30Over80, 2);
    });

    test('plancher : le jour le plus récent qui en a un', () {
      expect(
        parseLatestFloor(
          '{"floor":[{"date":"2026-10-12","w":310},{"date":"2026-10-13","w":null}]}',
        ),
        310,
      );
    });

    test('le plancher de la box l\'emporte sur le calcul local', () {
      final load =
          EnergyAdvice.baseLoad(
            LinkySnapshot(
              deviceName: 'x',
              timestamp: DateTime.now(),
              source: LinkySource.local,
            ),
            const EnergyExtras(floorW: 310),
          )!;
      expect(load.watts, 310);
    });
  });

  test('/api/alerts : sans émojis, avec la date', () {
    final alerts =
        BoxAlert.parse(
          '{"alerts":[{"id":42,"ts":"14/10/2026 18:42","type":"over_budget",'
          '"level":0,"title":"💸🚨Dépassement de budget","message":"...",'
          '"value":4200,"threshold":4000}],"lastId":42}',
        )!;
    expect(alerts.single.title, 'Dépassement de budget');
    expect(alerts.single.at, DateTime(2026, 10, 14, 18, 42));
    expect(alerts.single.type, 'over_budget');
  });

  test('/api/tariff : index, prix et prochain changement', () {
    final t =
        TariffNow.parse(
          '{"show":true,"tariff":"Heures Pleines","bgColor":"#154360",'
          '"isTempo":false,"today":{"class":"tempo-undef"},'
          '"tomorrow":{"class":"tempo-undef"},'
          '"index":258,"price":0.2068,"nextChange":"22:00"}',
        )!;
    expect(t.attribute, 258);
    expect(t.price, 0.2068);
    expect(t.nextChange, '22:00');

    final w =
        EnergyAdvice.weather(
          LinkySnapshot(
            deviceName: 'x',
            timestamp: DateTime.now(),
            source: LinkySource.local,
          ),
          EnergyExtras(tariff: t),
        )!;
    expect(w.pricePerKWh, 0.2068);
    expect(w.advice, contains('dès 22 h'));
  });
}

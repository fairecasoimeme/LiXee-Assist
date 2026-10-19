import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zigpower_connect/services/energy_detail_service.dart';
import 'package:zigpower_connect/services/widget_data_service.dart';

void main() {
  group('détail horaire de l\'export', () {
    // Box en HP/HC avec un sous-compteur : la colonne HC est vide en
    // journée, et « Véhicule » s'intercale avant le total.
    const hpHcCsv = '﻿Periode;HC / EJPHN / BBRHCJB / EASF01 (Wh);'
        'HP / EJPHPM / BBRHPJB / EASF02 (Wh);Véhicule (Wh);'
        'Consommation totale (Wh);Conso - Energie (EUR);'
        'Conso - Abonnement (EUR);Conso - Taxes (EUR);Conso - Cout total (EUR)\r\n'
        '5H;820;;40;860;0,10;0,02;0,03;0,15\r\n'
        '18H;;1611;130;1741;0,23;0,02;0,06;0,32\r\n';

    test('sépare les index tarifaires du sous-compteur', () {
      final samples = WidgetDataService.parseHourlyCsv(hpHcCsv);
      expect(samples[0].tariffs, {256: 820});
      expect(samples[1].tariffs, {258: 1611});
      expect(samples[1].subMeters, {'Véhicule': 130});
    });

    test('tarifs et sous-compteurs redonnent le total de la box', () {
      for (final s in WidgetDataService.parseHourlyCsv(hpHcCsv)) {
        final parts =
            s.tariffs.values.fold<int>(0, (a, b) => a + b) +
            s.subMeters.values.fold<int>(0, (a, b) => a + b);
        expect(parts, s.wh);
      }
    });

    test('la production signée n\'est ni un tarif ni un sous-compteur', () {
      const producerCsv = '﻿Periode;HC / EJPHN / BBRHCJB / EASF01 (Wh);'
          'Production (Wh);Consommation totale (Wh);Conso - Energie (EUR);'
          'Conso - Abonnement (EUR);Conso - Taxes (EUR);Conso - Cout total (EUR);'
          'Production totale (Wh);Production - Revenu (EUR);Net (Wh);'
          'Facture nette (EUR)\r\n'
          '11H;935;-1433;935;0,14;0,03;0,03;0,20;1433;0,89;-498;-0,69\r\n';
      final sample = WidgetDataService.parseHourlyCsv(producerCsv).single;
      expect(sample.tariffs, {256: 935});
      expect(sample.subMeters, isEmpty);
    });

    test('reconnaît les index par leur libellé EASF', () {
      expect(WidgetDataService.tariffAttribute('BASE'), 256);
      expect(
        WidgetDataService.tariffAttribute('HP / EJPHPM / BBRHPJB / EASF02'),
        258,
      );
      expect(WidgetDataService.tariffAttribute('BBRHCJW / EASF03'), 260);
      // « BBRHPJB » figure aussi dans l'en-tête de l'index 258.
      expect(WidgetDataService.tariffAttribute('BBRHPJB / EASF06'), 266);
      expect(WidgetDataService.tariffAttribute('Véhicule'), isNull);
    });

    test('le détail survit à l\'enregistrement du relevé', () {
      final sample = WidgetDataService.parseHourlyCsv(hpHcCsv)[1];
      final restored = HourlySample.fromJson(
        jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>,
      );
      expect(restored.tariffs, {258: 1611});
      expect(restored.subMeters, {'Véhicule': 130});
    });

    test('un relevé enregistré avant le détail se relit sans lui', () {
      final old = HourlySample.fromJson({'h': 18, 'wh': 167, 'c': 0.05});
      expect(old.tariffs, isEmpty);
      expect(old.subMeters, isEmpty);
    });
  });

  group('noms des index tarifaires', () {
    test('suivent le contrat', () {
      expect(tariffLabel(256, 'BASE'), 'Base');
      expect(tariffLabel(256, 'HC..'), 'Heures creuses');
      expect(tariffLabel(258, 'HC..'), 'Heures pleines');
      expect(tariffLabel(258, 'EJP.'), 'Pointe mobile');
      expect(tariffLabel(260, 'BBR('), 'HC Blanc');
      expect(tariffLabel(266, 'TEMPO'), 'HP Rouge');
    });

    test('restent neutres pour un contrat inconnu', () {
      expect(tariffLabel(256, null), 'Index 1');
      expect(tariffLabel(260, 'HC..'), 'Index 3');
    });
  });

  group('sous-compteurs', () {
    test('couleur par nom, sans les compteurs désactivés', () {
      final colors = EnergyDetailService.parseSubMeterColors(
        '{"subMeters":['
        '{"index":0,"IEEE":"00158d0001020304","alias":"Véhicule","color":"#e74c3c","enabled":true},'
        '{"index":1,"IEEE":"00158d0001020305","alias":"","color":"#16a085","enabled":true},'
        '{"index":2,"IEEE":"00158d0001020306","alias":"Four","color":"#000000","enabled":false}'
        '],"count":3}',
      );
      expect(colors, {'Véhicule': 0xe74c3c, 'Sous-compteur 2': 0x16a085});
    });
  });

  group('gaz et eau', () {
    test('lit les compteurs déclarés, et rien d\'autre du fichier', () {
      final meters = EnergyDetailService.parseUtilityConfig(
        '{"ZLinky":"00158d0005aabbcc","Gaz":"00158D0001020304",'
        '"tarifGaz":"0.12","coeffGaz":"10","unitGaz":"Wh",'
        '"Water":"","tarifWater":"0,004","coeffWater":"1","unitWater":"L",'
        '"passHTTP":"secret"}',
      );
      expect(meters, hasLength(1));
      expect(meters.single.kind, UtilityKind.gas);
      expect(meters.single.ieee, '00158D0001020304');
      expect(meters.single.unit, 'Wh');
      expect(meters.single.coefficient, 10);
      expect(meters.single.price, closeTo(0.12, 1e-9));
    });

    test('unité et coefficient par défaut', () {
      final meter =
          EnergyDetailService.parseUtilityConfig(
            '{"Water":"00158d0001020304","coeffWater":"0"}',
          ).single;
      expect(meter.kind, UtilityKind.water);
      expect(meter.unit, 'L');
      expect(meter.coefficient, 1);
      expect(meter.price, 0);
    });

    test('refuse ce qui n\'est pas une adresse IEEE', () {
      expect(
        EnergyDetailService.parseUtilityConfig('{"Gaz":"abc&time=day"}'),
        isEmpty,
      );
    });

    test('applique le coefficient à l\'historique', () {
      final samples = EnergyDetailService.parseUtilityChart(
        '[{"y":"14H","0":3},{"y":"15H"},{"y":"16H","0":5,"sub_0":230}]',
        10,
      );
      expect(samples.map((s) => s.hour), [14, 15, 16]);
      expect(samples.map((s) => s.value), [30, 0, 50]);
    });

    test('un historique sans aucune valeur n\'est pas une consommation nulle', () {
      expect(
        EnergyDetailService.parseUtilityChart('[{"y":"14H"},{"y":"15H"}]', 1),
        isEmpty,
      );
      const meter = UtilityMeter(kind: UtilityKind.gas, unit: 'm3');
      expect(meter.dailyTotal, isNull);
      expect(meter.dailyCostEur, isNull);
    });

    test('le coût compte en kWh quand l\'unité est le Wh', () {
      const gas = UtilityMeter(
        kind: UtilityKind.gas,
        unit: 'Wh',
        price: 0.1,
        hourly: [UtilitySample(14, 1500), UtilitySample(15, 500)],
      );
      expect(gas.dailyTotal, 2000);
      expect(gas.dailyCostEur, closeTo(0.2, 1e-9));

      const water = UtilityMeter(
        kind: UtilityKind.water,
        unit: 'L',
        price: 0.004,
        hourly: [UtilitySample(14, 120)],
      );
      expect(water.dailyCostEur, closeTo(0.48, 1e-9));
    });

    test('se relit après enregistrement', () {
      const extras = EnergyExtras(
        subMeterColors: {'Véhicule': 0xe74c3c},
        utilities: [
          UtilityMeter(
            kind: UtilityKind.water,
            unit: 'L',
            price: 0.004,
            hourly: [UtilitySample(14, 120)],
          ),
        ],
      );
      final restored = EnergyExtras.fromJson(
        jsonDecode(jsonEncode(extras.toJson())) as Map<String, dynamic>,
      );
      expect(restored.subMeterColors, {'Véhicule': 0xe74c3c});
      expect(restored.utilities.single.kind, UtilityKind.water);
      expect(restored.utilities.single.dailyTotal, 120);
    });
  });
}

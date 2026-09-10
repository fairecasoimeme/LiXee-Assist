import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zigpower_connect/services/widget_data_service.dart';

/// Réponse réelle de `GET /getLinky` sur une box en contrat BASE.
/// Noter l'espace avant les deux-points : le firmware produit ce JSON.
const _realPayload = '{"65382_768" :0,"1794_0" :16552341,"1794_256" :0,'
    '"1794_258" :0,"1794_260" :0,"1794_262" :0,"1794_264" :0,"1794_266" :0,'
    '"2820_1295" :410,"2820_1293" :0,"1794_32" :"TH..","65382_16" :"TH..",'
    '"1794_776" :"021861808743","2817_13" :45,"2817_14" :0,"2820_1288" :1,'
    '"2820_1290" :90,"65382_0" :"BASE","65382_1" :"","65382_2" :"",'
    '"65382_3" :0,"65382_4" :0,"65382_5" :0}';

void main() {
  group('LinkySnapshot.fromLinkyJson', () {
    late LinkySnapshot snapshot;

    setUp(() {
      snapshot = LinkySnapshot.fromLinkyJson(
        jsonDecode(_realPayload) as Map<String, dynamic>,
        deviceName: 'LiXee-Box',
        source: LinkySource.remote,
      );
    });

    test('décode les métriques qui portent le widget', () {
      expect(snapshot.apparentPowerVA, 410);
      expect(snapshot.indexWh, 16552341);
      expect(snapshot.indexKWh, closeTo(16552.341, 0.001));
      expect(snapshot.currentA, 1);
    });

    test('expose la puissance souscrite, échelle de la jauge', () {
      // 2817_13 = 45 A → palier d'abonnement 9 kVA (facteur conventionnel 200).
      expect(snapshot.subscribedCurrentA, 45);
      expect(snapshot.subscribedPowerVA, 9000);
    });

    test('sans intensité souscrite, pas d\'échelle inventée', () {
      final partial = LinkySnapshot.fromLinkyJson(
        const {'2820_1295': 410},
        deviceName: 'x',
        source: LinkySource.local,
      );
      expect(partial.subscribedCurrentA, isNull);
      expect(partial.subscribedPowerVA, isNull);
    });

    test('décode les champs contractuels', () {
      expect(snapshot.contract, 'BASE');
      expect(snapshot.tariffPeriod, 'TH..');
      expect(snapshot.meterSerial, '021861808743');
      expect(snapshot.isSingleTariff, isTrue);
    });

    test('en HP/HC, l\'index total vient des tranches', () {
      // Cas réel d'une box en HC.. : 1794_0 est à zéro, seuls les index par
      // tranche sont renseignés. S'en tenir à 1794_0 afficherait 0 kWh.
      final hpHc = LinkySnapshot.fromLinkyJson(
        const {
          '1794_0': 0,
          '1794_256': 21342722,
          '1794_258': 37405645,
          '65382_0': 'HC..',
        },
        deviceName: 'flo',
        source: LinkySource.remote,
      );
      expect(hpHc.totalIndexWh, 58748367);
      expect(hpHc.indexKWh, closeTo(58748.367, 0.001));
      expect(hpHc.isSingleTariff, isFalse);
    });

    test('en BASE, l\'index total reste celui de 1794_0', () {
      expect(snapshot.totalIndexWh, 16552341);
    });

    test('les index par tranche sont nuls en contrat BASE', () {
      expect(snapshot.tierIndexesWh, hasLength(6));
      expect(snapshot.tierIndexesWh, everyElement(0));
    });

    test('les chaînes vides deviennent null', () {
      // 65382_1 et 65382_2 valent "" dans la réponse réelle.
      final raw = jsonDecode(_realPayload) as Map<String, dynamic>;
      expect(raw['65382_1'], '');
      final withEmptyContract = LinkySnapshot.fromLinkyJson(
        {...raw, '65382_0': '  '},
        deviceName: 'x',
        source: LinkySource.local,
      );
      expect(withEmptyContract.contract, isNull);
    });

    test('accepte un nombre transmis sous forme de chaîne', () {
      final snapshot = LinkySnapshot.fromLinkyJson(
        {'2820_1295': '410', '1794_0': '16552341'},
        deviceName: 'x',
        source: LinkySource.local,
      );
      expect(snapshot.apparentPowerVA, 410);
      expect(snapshot.indexWh, 16552341);
    });

    test('tolère les clés absentes', () {
      final empty = LinkySnapshot.fromLinkyJson(
        const {},
        deviceName: 'x',
        source: LinkySource.local,
      );
      expect(empty.apparentPowerVA, isNull);
      expect(empty.indexWh, isNull);
      expect(empty.indexKWh, isNull);
      expect(empty.tierIndexesWh, everyElement(0));
    });
  });

  test('le snapshot survit à un aller-retour JSON', () {
    final original = LinkySnapshot.fromLinkyJson(
      jsonDecode(_realPayload) as Map<String, dynamic>,
      deviceName: 'LiXee-Box',
      source: LinkySource.local,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1757260800000),
    );

    final restored =
        LinkySnapshot.fromJson(jsonDecode(jsonEncode(original.toJson())));

    expect(restored.deviceName, original.deviceName);
    expect(restored.apparentPowerVA, original.apparentPowerVA);
    expect(restored.indexWh, original.indexWh);
    expect(restored.currentA, original.currentA);
    expect(restored.subscribedCurrentA, original.subscribedCurrentA);
    expect(restored.contract, original.contract);
    expect(restored.tariffPeriod, original.tariffPeriod);
    expect(restored.meterSerial, original.meterSerial);
    expect(restored.tierIndexesWh, original.tierIndexesWh);
    expect(restored.source, LinkySource.local);
    expect(restored.timestamp, original.timestamp);
  });

  group('série horaire', () {
    test('le total journalier est la somme des heures', () {
      final snapshot = LinkySnapshot(
        deviceName: 'x',
        timestamp: DateTime.now(),
        source: LinkySource.local,
        hourly: const [HourlySample(18, 167), HourlySample(19, 188)],
      );
      expect(snapshot.dailyTotalWh, 355);
    });

    test('le coût du jour est la somme des heures', () {
      final snapshot = LinkySnapshot(
        deviceName: 'x',
        timestamp: DateTime.now(),
        source: LinkySource.local,
        hourly: const [HourlySample(18, 167, 0.05), HourlySample(19, 188, 0.06)],
      );
      expect(snapshot.dailyCostEur, closeTo(0.11, 0.0001));
    });

    test('sans tarif paramétré, pas de coût affiché', () {
      final snapshot = LinkySnapshot(
        deviceName: 'x',
        timestamp: DateTime.now(),
        source: LinkySource.local,
        hourly: const [HourlySample(18, 167), HourlySample(19, 188)],
      );
      // Un total à zéro signifie « pas de tarif », pas « gratuit ».
      expect(snapshot.dailyCostEur, isNull);
      expect(snapshot.dailyTotalWh, 355);
    });

    test('la tendance compare les deux dernières heures complètes', () {
      // La dernière entrée est l'heure en cours, donc partielle : la retenir
      // donnerait une chute de 90 % en début d'heure.
      final snapshot = LinkySnapshot(
        deviceName: 'x',
        timestamp: DateTime.now(),
        source: LinkySource.local,
        hourly: const [
          HourlySample(15, 200),
          HourlySample(16, 250), // référence
          HourlySample(17, 300), // dernière heure complète
          HourlySample(18, 30), // heure en cours, partielle
        ],
      );
      expect(snapshot.hourlyTrendPct, closeTo(20, 0.001));
    });

    test('pas de tendance sans historique suffisant', () {
      final short = LinkySnapshot(
        deviceName: 'x',
        timestamp: DateTime.now(),
        source: LinkySource.local,
        hourly: const [HourlySample(17, 300), HourlySample(18, 30)],
      );
      expect(short.hourlyTrendPct, isNull);
    });

    test('pas de tendance si l\'heure de référence est nulle', () {
      final zeroRef = LinkySnapshot(
        deviceName: 'x',
        timestamp: DateTime.now(),
        source: LinkySource.local,
        hourly: const [
          HourlySample(16, 0),
          HourlySample(17, 300),
          HourlySample(18, 30),
        ],
      );
      expect(zeroRef.hourlyTrendPct, isNull);
    });

    test('sans série, pas de total inventé', () {
      final snapshot = LinkySnapshot(
        deviceName: 'x',
        timestamp: DateTime.now(),
        source: LinkySource.local,
      );
      // 0 laisserait croire à une consommation nulle : il faut null.
      expect(snapshot.dailyTotalWh, isNull);
    });

    test('la série survit à un aller-retour JSON', () {
      final original = LinkySnapshot(
        deviceName: 'x',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1757260800000),
        source: LinkySource.remote,
        hourly: const [HourlySample(18, 167), HourlySample(2, 189)],
      );
      final restored =
          LinkySnapshot.fromJson(jsonDecode(jsonEncode(original.toJson())));
      expect(restored.hourly.map((s) => '${s.hour}:${s.wh}'),
          ['18:167', '2:189']);
      expect(restored.dailyTotalWh, 356);
    });
  });

  group('parseHourlyCsv', () {
    // Box en contrat BASE : 7 colonnes.
    const baseCsv = '﻿Periode;BASE (Wh);Consommation totale (Wh);'
        'Conso - Energie (EUR);Conso - Abonnement (EUR);Conso - Taxes (EUR);'
        'Conso - Cout total (EUR)\r\n'
        '18H;167;167;0,02;0,03;0,00;0,05\r\n'
        '19H;188;188;0,03;0,03;0,00;0,06\r\n';

    // Box en HP/HC avec sous-comptage : 9 colonnes, et des cellules vides
    // pour la période tarifaire inactive.
    const hpHcCsv = '﻿Periode;HC / EJPHN / BBRHCJB / EASF01 (Wh);'
        'HP / EJPHPM / BBRHPJB / EASF02 (Wh);Véhicule (Wh);'
        'Consommation totale (Wh);Conso - Energie (EUR);'
        'Conso - Abonnement (EUR);Conso - Taxes (EUR);Conso - Cout total (EUR)\r\n'
        '18H;;1611;130;1741;0,23;0,02;0,06;0,32\r\n'
        '19H;;1942;2110;4052;0,47;0,02;0,07;0,57\r\n';

    test('lit la bonne colonne en contrat BASE', () {
      final samples = WidgetDataService.parseHourlyCsv(baseCsv);
      expect(samples.map((s) => s.wh), [167, 188]);
      expect(samples.map((s) => s.hour), [18, 19]);
      expect(samples.first.costEur, closeTo(0.05, 0.0001));
    });

    test('suit le décalage des colonnes en HP/HC', () {
      // La consommation totale passe de l'index 2 à 4, le coût de 6 à 8 :
      // se fier au rang donnerait ici la colonne « Véhicule ».
      final samples = WidgetDataService.parseHourlyCsv(hpHcCsv);
      expect(samples.map((s) => s.wh), [1741, 4052]);
      expect(samples.first.costEur, closeTo(0.32, 0.0001));
    });

    // Installation productrice : 11 colonnes, avec « Production (Wh) » signée
    // intercalée avant la consommation, puis production, revenu, net et
    // facture nette. Relevé sur une box réelle.
    const producerCsv = '﻿Periode;HC / EJPHN / BBRHCJB / EASF01 (Wh);'
        'Production (Wh);Consommation totale (Wh);Conso - Energie (EUR);'
        'Conso - Abonnement (EUR);Conso - Taxes (EUR);Conso - Cout total (EUR);'
        'Production totale (Wh);Production - Revenu (EUR);Net (Wh);'
        'Facture nette (EUR)\r\n'
        '11H;935;-1433;935;0,14;0,03;0,03;0,20;1433;0,89;-498;-0,69\r\n'
        '12H;960;-1662;960;0,14;0,03;0,03;0,20;1662;1,03;-702;-0,83\r\n';

    test('décode la production et le revenu d\'un producteur', () {
      final samples = WidgetDataService.parseHourlyCsv(producerCsv);
      expect(samples.map((s) => s.wh), [935, 960]);
      expect(samples.map((s) => s.productionWh), [1433, 1662]);
      expect(samples.first.revenueEur, closeTo(0.89, 0.0001));
    });

    test('ne confond pas « Production » signée et « Production totale »', () {
      // La colonne « Production (Wh) » vaut -1433 : la lire donnerait une
      // injection négative. C'est « Production totale » qui porte la quantité.
      final samples = WidgetDataService.parseHourlyCsv(producerCsv);
      expect(samples.every((s) => s.productionWh > 0), isTrue);
    });

    test('le net se déduit et concorde avec la colonne de la box', () {
      final samples = WidgetDataService.parseHourlyCsv(producerCsv);
      // La box annonce -498 et -702 Wh, -0,69 et -0,83 €.
      expect(samples.map((s) => s.netWh), [-498, -702]);
      expect(samples.first.netCostEur, closeTo(-0.69, 0.0001));
      expect(samples.last.netCostEur, closeTo(-0.83, 0.0001));
    });

    test('une box sans production n\'expose ni injection ni revenu', () {
      final snapshot = LinkySnapshot(
        deviceName: 'x',
        timestamp: DateTime.now(),
        source: LinkySource.local,
        hourly: WidgetDataService.parseHourlyCsv(baseCsv),
      );
      expect(snapshot.produces, isFalse);
      expect(snapshot.dailyProductionWh, isNull);
      expect(snapshot.dailyRevenueEur, isNull);
    });

    test('totaux journaliers d\'un producteur', () {
      final snapshot = LinkySnapshot(
        deviceName: 'maison',
        timestamp: DateTime.now(),
        source: LinkySource.remote,
        hourly: WidgetDataService.parseHourlyCsv(producerCsv),
      );
      expect(snapshot.produces, isTrue);
      expect(snapshot.dailyTotalWh, 1895);
      expect(snapshot.dailyProductionWh, 3095);
      expect(snapshot.dailyRevenueEur, closeTo(1.92, 0.0001));
      expect(snapshot.dailyNetWh, -1200);
      expect(snapshot.dailyNetCostEur, closeTo(-1.52, 0.0001));
    });

    test('le coût HP/HC vient de la box, pas d\'un recalcul', () {
      // La colonne « Conso - Cout total » applique déjà les tarifs de chaque
      // période : c'est elle qu'on lit, on ne réapplique aucun barème ici.
      final samples = WidgetDataService.parseHourlyCsv(hpHcCsv);
      expect(samples.map((s) => s.costEur), [
        closeTo(0.32, 0.0001),
        closeTo(0.57, 0.0001),
      ]);
    });

    test('ignore les colonnes de sous-comptage', () {
      // « Véhicule » vaut 2110 Wh à 19 h : la lire donnerait un total faux.
      final samples = WidgetDataService.parseHourlyCsv(hpHcCsv);
      expect(samples.map((s) => s.wh), [1741, 4052]);
    });

    test('ignore un CSV sans ligne de données', () {
      expect(WidgetDataService.parseHourlyCsv('Periode;BASE (Wh)\r\n'), isEmpty);
      expect(WidgetDataService.parseHourlyCsv(''), isEmpty);
    });
  });

  test('age reflète la fraîcheur du relevé', () {
    final stale = LinkySnapshot(
      deviceName: 'x',
      timestamp: DateTime.now().subtract(const Duration(minutes: 42)),
      source: LinkySource.remote,
    );
    expect(stale.age.inMinutes, 42);
  });
}

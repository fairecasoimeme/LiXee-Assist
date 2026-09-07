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

    test('décode les champs contractuels', () {
      expect(snapshot.contract, 'BASE');
      expect(snapshot.tariffPeriod, 'TH..');
      expect(snapshot.meterSerial, '021861808743');
      expect(snapshot.isSingleTariff, isTrue);
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
    expect(restored.contract, original.contract);
    expect(restored.tariffPeriod, original.tariffPeriod);
    expect(restored.meterSerial, original.meterSerial);
    expect(restored.tierIndexesWh, original.tierIndexesWh);
    expect(restored.source, LinkySource.local);
    expect(restored.timestamp, original.timestamp);
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

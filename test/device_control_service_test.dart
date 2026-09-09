import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zigpower_connect/services/device_control_service.dart';

/// Extraits réels de `GET /getDevices` sur une LiXee-Box : un volet SONOFF et
/// un capteur température/humidité. Les valeurs sont en hexadécimal, les clés
/// numériques sont des clusters.
const _devicesJson = '''
{
  "6ce4a4fffea2eced": {
    "INFO": {
      "shortAddr": "30210", "LQI": "7D", "device_id": "514",
      "manufacturer": "SONOFF", "model": "MINI-ZBRBS", "endpoint": "1",
      "alias": "volet salon 1"
    },
    "0006": { "0": "00" },
    "0102": { "23": "00", "8": "64" },
    "FC11": { "20499": "00" }
  },
  "c4d8c8fffe1954f3": {
    "INFO": {
      "shortAddr": "60851", "LQI": "77", "device_id": "770",
      "manufacturer": "SONOFF", "model": "SNZB-02D", "endpoint": "1",
      "alias": "temp"
    },
    "0001": { "33": "C8" },
    "0402": { "0": "0AFA" },
    "0405": { "0": "1022" }
  },
  "0badentry": { "INFO": "pas un objet" }
}
''';

/// Extraits réels de `GET /getTemplates`, réduits aux deux types utilisés.
final _templates = jsonDecode('''
{
  "514.json": {
    "TS130F": [{
      "status": [
        {"name": "current_position", "cluster": "0102", "attribut": 8},
        {"name": "calibration", "cluster": "0102", "attribut": 61441,
         "writable": true, "typewritable": 48}
      ],
      "action": [
        {"name": "UP", "command": 250, "endpoint": 1, "value": 1, "visible": 1}
      ]
    }],
    "default": [{
      "status": [
        {"name": "current_position", "cluster": "0102", "attribut": 8},
        {"name": "config_status", "cluster": "0102", "attribut": 7}
      ],
      "action": [
        {"name": "UP", "command": 250, "endpoint": 1, "value": 1, "visible": 1},
        {"name": "DOWN", "command": 250, "endpoint": 1, "value": 0, "visible": 1},
        {"name": "STOP", "command": 250, "endpoint": 1, "value": 2, "visible": 1}
      ]
    }]
  },
  "770.json": {
    "SNZB-02D": [{
      "status": [
        {"name": "temperature", "cluster": "0402", "attribut": 0,
         "type": "float", "coefficient": 0.01, "unit": "\\u00b0C",
         "visible": 1, "jauge": "gauge", "min": -20, "max": 50},
        {"name": "humidity", "cluster": "0405", "attribut": 0,
         "type": "float", "coefficient": 0.01, "unit": "%", "visible": 1},
        {"name": "battery", "cluster": "0001", "attribut": 33,
         "type": "numeric", "unit": "%", "coefficient": 0.5, "visible": 1},
        {"name": "humidity_calibration", "cluster": "FC11", "attribut": 8196,
         "writable": true, "typewritable": 41}
      ],
      "action": []
    }]
  },
  "266.json": {
    "default": [{
      "status": [],
      "action": [
        {"name": "FORCE ON", "command": 400, "endpoint": 1, "cluster": "FC41",
         "manufacturerSpecific": "0x1021", "value": 2, "visible": 1},
        {"name": "REGLAGE", "cluster": "0201", "attribut": 28, "type": 48,
         "value": 0, "visible": 1}
      ]
    }]
  }
}
''') as Map<String, dynamic>;

List<DeviceSnapshot> parse() =>
    DeviceControlService.parseDevices('LIXEEBOX-8BF0', _devicesJson, _templates);

DeviceSnapshot byLabel(String label) =>
    parse().firstWhere((d) => d.label == label);

void main() {
  group('parseDevices', () {
    test('retient les appareils et ignore une entrée malformée', () {
      final devices = parse();
      expect(devices.map((d) => d.label), ['volet salon 1', 'temp']);
    });

    test("l'alias prime sur le modèle et sur l'IEEE", () {
      final volet = byLabel('volet salon 1');
      expect(volet.model, 'MINI-ZBRBS');
      expect(volet.ieee, '6ce4a4fffea2eced');
      expect(volet.key, 'LIXEEBOX-8BF0/6ce4a4fffea2eced');
    });

    test('adresse courte et endpoint sont décodés en décimal', () {
      final volet = byLabel('volet salon 1');
      expect(volet.shortAddr, 30210);
      expect(volet.endpoint, 1);
    });

    test('la position du volet est décodée depuis son hexadécimal', () {
      // 0x64 = 100, et sur ce matériel 100 vaut « ouvert ».
      expect(byLabel('volet salon 1').reading('current_position')?.value, 100);
    });

    test('le coefficient du gabarit est appliqué', () {
      final capteur = byLabel('temp');
      // 0x0AFA = 2810, ×0,01
      expect(capteur.reading('temperature')?.value, closeTo(28.10, 0.001));
      // 0x1022 = 4130, ×0,01
      expect(capteur.reading('humidity')?.value, closeTo(41.30, 0.001));
      // 0xC8 = 200 demi-pourcents, ×0,5 → 100 %
      expect(capteur.reading('battery')?.value, 100);
    });

    test('la position hérite du pourcentage que le gabarit omet', () {
      // 0x0102 attribut 8 est CurrentPositionLiftPercentage : la
      // spécification en fait un pourcentage, le gabarit ne le dit pas.
      expect(byLabel('volet salon 1').reading('current_position')?.unit, '%');
    });

    test("le gabarit garde le dernier mot sur l'unité", () {
      // L'unité déduite ne doit compléter que là où le gabarit se tait.
      expect(byLabel('temp').reading('temperature')?.unit, '°C');
    });

    test('unité et bornes de jauge viennent du gabarit', () {
      final temperature = byLabel('temp').reading('temperature')!;
      expect(temperature.unit, '°C');
      expect(temperature.min, -20);
      expect(temperature.max, 50);
      expect(temperature.gaugeKind, 'gauge');
    });

    test('les réglages ne sont pas affichés', () {
      // `writable` marque la calibration : sans intérêt sur un écran d'accueil.
      expect(byLabel('temp').reading('humidity_calibration'), isNull);
      expect(byLabel('temp').readings.length, 3);
    });

    test('le modèle exact choisit la variante, sinon default', () {
      // MINI-ZBRBS n'est pas TS130F : c'est `default` qui s'applique, avec ses
      // trois actions, pas l'unique action de la variante TS130F.
      expect(byLabel('volet salon 1').actions.map((a) => a.name),
          ['UP', 'DOWN', 'STOP']);
      // SNZB-02D est nommé explicitement : sa variante l'emporte.
      expect(byLabel('temp').readings.first.name, 'temperature');
    });

    test('un appareil sans action n\'en propose aucune', () {
      expect(byLabel('temp').actions, isEmpty);
    });
  });

  group('actions', () {
    test('les paramètres du volet sont ceux du gabarit', () {
      final actions = byLabel('volet salon 1').actions;
      final up = actions.firstWhere((a) => a.name == 'UP');
      final down = actions.firstWhere((a) => a.name == 'DOWN');
      final stop = actions.firstWhere((a) => a.name == 'STOP');
      expect([up.command, up.endpoint, up.value], [250, 1, 1]);
      expect(down.value, 0);
      expect(stop.value, 2);
    });

    test('la requête garde l\'ordre des arguments', () {
      // handleZigbeeAction lit ses arguments par position : l'ordre est
      // porteur de sens, les noms sont décoratifs.
      final up = byLabel('volet salon 1').actions.first;
      expect(up.query(30210),
          'shortaddr=30210&command=250&endpoint=1&value=1');
    });

    test('la commande 400 seule emporte cluster et code constructeur', () {
      final block =
          DeviceControlService.templateBlock(_templates, '266', 'inconnu')!;
      final forced = DeviceControlService.parseDevices(
        'b',
        '{"aa":{"INFO":{"device_id":"266","model":"inconnu","shortAddr":"7",'
            '"endpoint":"1"}}}',
        _templates,
      ).first;
      expect(block['action'], isNotNull);
      // L'action sans `command` passe par une écriture d'attribut : elle n'est
      // pas proposée, faute de quoi on enverrait une trame au hasard.
      expect(forced.actions.map((a) => a.name), ['FORCE ON']);
      expect(forced.actions.first.query(7),
          'shortaddr=7&command=400&endpoint=1&value=2&cluster=64577&mfr=4129');
    });
  });

  group('decodeHex', () {
    test('lit un hexadécimal non signé', () {
      expect(DeviceControlService.decodeHex('64'), 100);
      expect(DeviceControlService.decodeHex('0AFA'), 2810);
      expect(DeviceControlService.decodeHex('000000000036'), 54);
    });

    test('un 16 bits au bit de poids fort est négatif', () {
      // Sans ça, -1,50 °C se lirait 654,86 °C.
      expect(DeviceControlService.decodeHex('FF6A'), -150);
    });

    test('le signe explicite est respecté', () {
      expect(DeviceControlService.decodeHex('-5B4C05'), -5983237);
    });

    test('rend null sur une valeur absente ou illisible', () {
      expect(DeviceControlService.decodeHex(null), isNull);
      expect(DeviceControlService.decodeHex(''), isNull);
      expect(DeviceControlService.decodeHex('zz'), isNull);
    });
  });
}

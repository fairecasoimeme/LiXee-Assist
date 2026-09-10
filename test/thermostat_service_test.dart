import 'package:flutter_test/flutter_test.dart';
import 'package:zigpower_connect/services/thermostat_service.dart';

/// Réponse réelle de `GET /loadThermostats` : une zone qui régule, et une
/// zone créée mais jamais raccordée — sans sonde ni actionneur.
const _listing = '''
[
  {"id": 0, "name": "Salon", "enabled": 1, "heating": 0, "setpoint": 27.0,
   "frostTemp": 7.0, "temp": 27.9, "sensorValid": 1, "occupied": 1,
   "actuatorCount": 1, "operMode": 1, "actualOn": 0, "forceMode": 2,
   "reversible": 1, "frostMode": 0},
  {"id": 1, "name": "test", "enabled": 1, "heating": 1, "setpoint": 19.5,
   "temp": null, "sensorValid": 0, "actuatorCount": 0, "actualOn": 0,
   "forceMode": 0, "reversible": 0, "frostMode": 1},
  {"id": 2, "name": "", "setpoint": 0}
]
''';

ThermostatZone zone(String name) =>
    ThermostatService.parseZones('LIXEEBOX-8BF0', _listing)
        .firstWhere((z) => z.name == name);

void main() {
  group('parseZones', () {
    test('retient les zones nommées', () {
      final zones = ThermostatService.parseZones('b', _listing);
      expect(zones.map((z) => z.name), ['Salon', 'test']);
    });

    test('lit consigne, mesure et état', () {
      final salon = zone('Salon');
      expect(salon.setpoint, 27.0);
      expect(salon.temperature, 27.9);
      expect(salon.heating, isFalse);
      expect(salon.reversible, isTrue);
      expect(salon.forceMode, 2);
      expect(salon.active, isFalse);
    });

    test('une sonde invalide ne donne pas de mesure', () {
      // Sans elle la consigne ne régule rien : afficher une température
      // résiduelle laisserait croire le contraire.
      expect(zone('test').temperature, isNull);
      expect(zone('test').hasReading, isFalse);
      expect(zone('Salon').hasReading, isTrue);
    });

    test('la clé est bâtie sur le nom, pas sur le rang', () {
      expect(zone('Salon').key, 'LIXEEBOX-8BF0~Salon');
    });

    test('une réponse illisible ne donne aucune zone', () {
      expect(ThermostatService.parseZones('b', '{}'), isEmpty);
      expect(ThermostatService.parseZones('b', 'nope'), isEmpty);
    });
  });

  group('nextSetpoint', () {
    test('avance et recule d\'un demi-degré', () {
      expect(ThermostatService.nextSetpoint(19.5, 0.5), 20.0);
      expect(ThermostatService.nextSetpoint(19.5, -0.5), 19.0);
    });

    test('arrondit au demi-degré', () {
      // La box n'accepte que des demis : 20,3 + 0,5 doit retomber sur 21,0.
      expect(ThermostatService.nextSetpoint(20.3, 0.5), 21.0);
      expect(ThermostatService.nextSetpoint(20.2, 0.0), 20.0);
    });

    test('reste dans les bornes de la box', () {
      expect(ThermostatService.nextSetpoint(40.0, 0.5), 40.0);
      expect(ThermostatService.nextSetpoint(0.0, -0.5), 0.0);
    });
  });

  group('pathFor', () {
    test('la consigne part en valeur absolue, pas en écart', () {
      expect(
        ThermostatService.pathFor(zone('Salon'), delta: -0.5),
        '/setThermostatSetpoint?id=0&value=26.5',
      );
    });

    test('un entier s\'écrit sans décimale', () {
      expect(
        ThermostatService.pathFor(zone('Salon'), delta: 1.0),
        '/setThermostatSetpoint?id=0&value=28',
      );
    });

    test('forçage, mode et hors-gel ont chacun leur route', () {
      final salon = zone('Salon');
      expect(ThermostatService.pathFor(salon, forceMode: 0),
          '/setThermostatForce?id=0&mode=0');
      expect(ThermostatService.pathFor(salon, heat: true),
          '/setThermostatMode?id=0&heat=1');
    });

    test('le hors-gel envoie l\'état voulu, pas un ordre de bascule', () {
      // Salon n'est pas en hors-gel : on demande 1. La zone « test » l'est
      // déjà : on demande 0.
      expect(ThermostatService.pathFor(zone('Salon'), toggleFrost: true),
          '/setThermostatFrost?id=0&on=1');
      expect(ThermostatService.pathFor(zone('test'), toggleFrost: true),
          '/setThermostatFrost?id=1&on=0');
    });

    test('sans commande, aucune requête', () {
      expect(ThermostatService.pathFor(zone('Salon')), isNull);
    });
  });
}

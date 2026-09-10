import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'box_client.dart';

/// Une zone du thermostat virtuel de la box.
///
/// La box pilote un actionneur d'après une sonde et une consigne. Rien de tout
/// cela n'est un appareil Zigbee : c'est une couche à elle, avec sa propre
/// section dans l'interface et ses propres endpoints.
class ThermostatZone {
  final String boxName;

  /// Rang de la zone chez la box, seul identifiant que ses endpoints acceptent.
  final int id;

  final String name;

  /// Consigne, en °C. La box l'arrondit au demi-degré.
  final double setpoint;

  /// Température mesurée. `null` si la sonde ne répond pas — auquel cas la
  /// régulation ne peut rien faire, et le widget doit le dire.
  final double? temperature;

  /// Chauffe (`true`) ou refroidit (`false`).
  final bool heating;

  /// La zone peut-elle basculer entre chaud et froid ?
  final bool reversible;

  /// L'actionneur est-il en train de marcher ?
  final bool active;

  /// 0 = Auto, 1 = Marche forcée, 2 = Arrêt forcé.
  final int forceMode;

  /// La consigne est-elle basculée sur le hors-gel ?
  final bool frost;

  const ThermostatZone({
    required this.boxName,
    required this.id,
    required this.name,
    required this.setpoint,
    this.temperature,
    this.heating = true,
    this.reversible = false,
    this.active = false,
    this.forceMode = 0,
    this.frost = false,
  });

  /// Identifiant stable à travers les box.
  ///
  /// Bâti sur le nom, pas sur l'id : celui-ci est un rang chez la box, et
  /// supprimer une zone décalerait toutes les suivantes. Un widget resterait
  /// alors pointé sur la voisine.
  String get key => '$boxName~$name';

  /// La sonde répond-elle ? Sans elle, la consigne ne régule rien.
  bool get hasReading => temperature != null;

  @override
  String toString() =>
      'ThermostatZone($boxName/$id, $name, ${setpoint}°C, '
      '${temperature ?? '—'}°C, force=$forceMode)';
}

/// Lit et pilote les thermostats virtuels d'une box.
class ThermostatService {
  ThermostatService._();

  /// La box arrondit la consigne au demi-degré et la borne entre 0 et 40.
  static const setpointStep = 0.5;
  static const setpointMin = 0.0;
  static const setpointMax = 40.0;

  static Future<List<ThermostatZone>> fetchAll(
    BoxDevice box, {
    Future<String?> Function(String deviceName)? mdnsResolver,
    Duration localTimeout = BoxClient.defaultLocalTimeout,
    Duration remoteTimeout = BoxClient.defaultRemoteTimeout,
  }) async {
    final routes = BoxClient.routes(
      box,
      mdnsResolver: mdnsResolver,
      localTimeout: localTimeout,
      remoteTimeout: remoteTimeout,
    );

    await for (final (candidate, route) in routes) {
      try {
        final body = await BoxClient.get(route, '/loadThermostats');
        if (body == null) {
          BoxClient.dropSession(route);
          continue;
        }
        BoxClient.remember(box, candidate);
        return parseZones(box.name, body);
      } catch (e) {
        print('[THERMO] ${route.baseUrl} échec: $e');
        BoxClient.dropSession(route);
      }
    }
    return const [];
  }

  /// Applique une commande à une zone, désignée par son nom.
  ///
  /// [delta] déplace la consigne du pas demandé ; les autres paramètres visent
  /// un réglage absolu. La zone est relue juste avant d'agir : la consigne a
  /// pu bouger depuis l'écran d'accueil — un thermostat se règle aussi depuis
  /// la box, et déplacer une valeur périmée reviendrait à annuler ce
  /// changement-là.
  static Future<bool> command(
    BoxDevice box,
    String zoneName, {
    double? delta,
    int? forceMode,
    bool? heat,
    bool? toggleFrost,
    Future<String?> Function(String deviceName)? mdnsResolver,
    Duration localTimeout = BoxClient.defaultLocalTimeout,
    Duration remoteTimeout = BoxClient.defaultRemoteTimeout,
  }) async {
    final routes = BoxClient.routes(
      box,
      mdnsResolver: mdnsResolver,
      localTimeout: localTimeout,
      remoteTimeout: remoteTimeout,
    );

    await for (final (candidate, route) in routes) {
      try {
        final listing = await BoxClient.get(route, '/loadThermostats');
        if (listing == null) {
          BoxClient.dropSession(route);
          continue;
        }
        final zone = parseZones(box.name, listing)
            .where((z) => z.name == zoneName)
            .firstOrNull;
        if (zone == null) {
          print('[THERMO] Zone introuvable: $zoneName');
          return false;
        }

        final path = pathFor(
          zone,
          delta: delta,
          forceMode: forceMode,
          heat: heat,
          toggleFrost: toggleFrost,
        );
        if (path == null) return false;

        final body = await BoxClient.get(route, path);
        if (body == null) {
          BoxClient.dropSession(route);
          continue;
        }
        BoxClient.remember(box, candidate);
        print('[THERMO] $zoneName ← $path');
        return true;
      } catch (e) {
        print('[THERMO] Commande échouée: $e');
        BoxClient.dropSession(route);
      }
    }
    return false;
  }

  /// La requête à émettre pour une commande donnée, ou `null` si aucune.
  @visibleForTesting
  static String? pathFor(
    ThermostatZone zone, {
    double? delta,
    int? forceMode,
    bool? heat,
    bool? toggleFrost,
  }) {
    if (delta != null) {
      return '/setThermostatSetpoint?id=${zone.id}'
          '&value=${_format(nextSetpoint(zone.setpoint, delta))}';
    }
    if (forceMode != null) {
      return '/setThermostatForce?id=${zone.id}&mode=$forceMode';
    }
    if (heat != null) {
      return '/setThermostatMode?id=${zone.id}&heat=${heat ? 1 : 0}';
    }
    if (toggleFrost == true) {
      // Bascule : la box attend l'état voulu, pas un ordre d'inversion.
      return '/setThermostatFrost?id=${zone.id}&on=${zone.frost ? 0 : 1}';
    }
    return null;
  }

  /// Consigne après déplacement, arrondie au demi-degré et bornée.
  @visibleForTesting
  static double nextSetpoint(double current, double delta) {
    final moved = (current + delta) * 2;
    final rounded = moved.round() / 2;
    if (rounded < setpointMin) return setpointMin;
    if (rounded > setpointMax) return setpointMax;
    return rounded;
  }

  @visibleForTesting
  static List<ThermostatZone> parseZones(String boxName, String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      return [
        for (final raw in decoded)
          if (raw is Map)
            ThermostatZone(
              boxName: boxName,
              id: (raw['id'] as num?)?.toInt() ?? 0,
              name: raw['name']?.toString() ?? '',
              setpoint: (raw['setpoint'] as num?)?.toDouble() ?? 0,
              // `sensorValid` à 0 accompagne parfois une valeur résiduelle :
              // c'est lui qui fait foi, pas la présence du champ.
              temperature: raw['sensorValid'] == 1
                  ? (raw['temp'] as num?)?.toDouble()
                  : null,
              heating: raw['heating'] == 1,
              reversible: raw['reversible'] == 1,
              active: raw['actualOn'] == 1,
              forceMode: (raw['forceMode'] as num?)?.toInt() ?? 0,
              frost: raw['frostMode'] == 1,
            ),
      ].where((z) => z.name.isNotEmpty).toList(growable: false);
    } catch (e) {
      print('[THERMO] Liste illisible: $e');
      return const [];
    }
  }

  /// Nombre sans zéro décimal inutile : la box attend « 19.5 » ou « 20 ».
  static String _format(double value) =>
      value == value.roundToDouble()
          ? value.toStringAsFixed(0)
          : value.toStringAsFixed(1);
}

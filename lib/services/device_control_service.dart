import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'box_client.dart';

/// Une grandeur affichable d'un appareil, telle que le gabarit la décrit.
///
/// Le gabarit porte déjà l'unité, le coefficient et les bornes de jauge : rien
/// n'est codé en dur par type d'appareil, et un modèle inconnu de l'app
/// s'affiche correctement dès que la box le connaît.
class DeviceReading {
  final String name;
  final String? unit;
  final double? value;

  /// Bornes de jauge, quand le gabarit en propose une.
  final double? min;
  final double? max;

  /// `gauge`, `battery`… tel qu'écrit par le gabarit. Vide si la grandeur se
  /// lit comme un simple nombre.
  final String? gaugeKind;

  const DeviceReading({
    required this.name,
    this.unit,
    this.value,
    this.min,
    this.max,
    this.gaugeKind,
  });

  @override
  String toString() => '$name=${value ?? '—'}${unit ?? ''}';
}

/// Un bouton proposé par le gabarit, avec de quoi l'envoyer tel quel.
class DeviceAction {
  final String name;

  /// Sélecteur interne LiXee : 146 = OnOff, 250 = volet, 400 = cluster
  /// constructeur, 300-303 = Tuya…
  final int command;
  final int endpoint;
  final int value;

  /// Renseignés pour la commande 400 seule, qui les exige.
  final int? cluster;
  final int? manufacturerCode;

  const DeviceAction({
    required this.name,
    required this.command,
    required this.endpoint,
    required this.value,
    this.cluster,
    this.manufacturerCode,
  });

  /// Requête à émettre, **arguments dans cet ordre impérativement**.
  ///
  /// `handleZigbeeAction` les lit par position (`request->arg(0)`…), pas par
  /// nom : les intitulés sont décoratifs, et intervertir deux paramètres
  /// enverrait une commande valide au mauvais endroit.
  String query(int shortAddr) {
    final base = 'shortaddr=$shortAddr&command=$command'
        '&endpoint=$endpoint&value=$value';
    // Le firmware n'ajoute cluster et code constructeur que pour la 400 ;
    // les joindre ailleurs ferait basculer la box sur SendActionEx.
    if (command != 400) return base;
    return '$base&cluster=${cluster ?? 0}&mfr=${manufacturerCode ?? 0}';
  }
}

/// État d'un appareil Zigbee appairé, prêt à être affiché et commandé.
class DeviceSnapshot {
  final String boxName;
  final String ieee;

  /// Nom donné par l'utilisateur sur la box, à défaut le modèle. C'est lui
  /// qu'on affiche : personne ne reconnaît un appareil à son adresse IEEE.
  final String label;
  final String model;
  final int shortAddr;
  final int endpoint;
  final List<DeviceReading> readings;
  final List<DeviceAction> actions;
  final DateTime timestamp;

  const DeviceSnapshot({
    required this.boxName,
    required this.ieee,
    required this.label,
    required this.model,
    required this.shortAddr,
    required this.endpoint,
    required this.timestamp,
    this.readings = const [],
    this.actions = const [],
  });

  /// Identifiant stable d'un appareil à travers les box.
  String get key => '$boxName/$ieee';

  DeviceReading? reading(String name) {
    for (final r in readings) {
      if (r.name == name) return r;
    }
    return null;
  }

  @override
  String toString() =>
      'DeviceSnapshot($label, $model, ${readings.join(' ')}, '
      '${actions.length} action(s))';
}

/// Lit et commande les appareils Zigbee d'une box.
///
/// Ne connaît aucun type d'appareil : ce que la box décrit dans ses gabarits
/// dicte ce qui s'affiche et ce qui s'envoie.
class DeviceControlService {
  DeviceControlService._();

  /// Gabarits par box. Ils pèsent ~150 ko et ne changent qu'au gré des mises à
  /// jour du firmware : les relire à chaque relevé serait absurde.
  static final Map<String, Map<String, dynamic>> _templates = {};

  /// Relève tous les appareils d'une box.
  static Future<List<DeviceSnapshot>> fetchAll(
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
        final devices = await BoxClient.get(route, '/getDevices');
        if (devices == null) {
          print('[DEVICES] ${route.baseUrl}: pas de réponse exploitable');
          BoxClient.dropSession(route);
          continue;
        }

        final templates = await _templatesFor(route);
        BoxClient.remember(box, candidate);
        return parseDevices(box.name, devices, templates);
      } catch (e) {
        print('[DEVICES] ${route.baseUrl} échec: $e');
        BoxClient.dropSession(route);
      }
    }

    print('[DEVICES] Aucune URL joignable pour ${box.name}');
    return const [];
  }

  /// Envoie une action et rend `true` si la box l'a acceptée.
  ///
  /// Un `true` ne dit pas que l'appareil a bougé : la box se contente
  /// d'empiler la trame Zigbee. Seule une relecture ultérieure le confirme.
  static Future<bool> send(
    BoxDevice box,
    DeviceSnapshot device,
    DeviceAction action, {
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
        final path = '/ZigbeeAction?${action.query(device.shortAddr)}';
        final body = await BoxClient.get(route, path);
        // La réponse est vide en cas de succès : c'est l'absence d'erreur qui
        // fait foi, et BoxClient rend null dès que le code n'est pas 200.
        if (body == null) {
          BoxClient.dropSession(route);
          continue;
        }
        BoxClient.remember(box, candidate);
        print('[DEVICES] ${device.label} ← ${action.name}');
        return true;
      } catch (e) {
        print('[DEVICES] Action ${action.name} échouée: $e');
        BoxClient.dropSession(route);
      }
    }
    return false;
  }

  /// Force la box à relire un attribut sur l'appareil lui-même.
  ///
  /// Indispensable après une action : `/getDevices` sert la dernière valeur
  /// *rapportée*, qui peut avoir des minutes de retard. Sans ce rappel, un
  /// volet en mouvement affiche encore sa position de départ.
  static Future<void> forceRead(
    BoxDevice box,
    DeviceSnapshot device,
    String clusterHex,
    int attribute, {
    Future<String?> Function(String deviceName)? mdnsResolver,
    Duration localTimeout = BoxClient.defaultLocalTimeout,
    Duration remoteTimeout = BoxClient.defaultRemoteTimeout,
  }) async {
    final cluster = int.tryParse(clusterHex, radix: 16);
    if (cluster == null) return;

    final routes = BoxClient.routes(
      box,
      mdnsResolver: mdnsResolver,
      localTimeout: localTimeout,
      remoteTimeout: remoteTimeout,
    );
    await for (final (_, route) in routes) {
      try {
        await BoxClient.get(
          route,
          '/ZigbeeSendRequest?shortaddr=${device.shortAddr}'
          '&endpoint=${device.endpoint}&cluster=$cluster&attribute=$attribute',
        );
        return;
      } catch (e) {
        print('[DEVICES] Relecture forcée impossible: $e');
      }
    }
  }

  /// Entrées `saved_devices`, décodées.
  static Future<List<BoxDevice>> savedBoxes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return (prefs.getStringList('saved_devices') ?? [])
        .map(BoxDevice.tryParse)
        .whereType<BoxDevice>()
        .toList(growable: false);
  }

  // --- Décodage, sans réseau ------------------------------------------------

  /// Croise `/getDevices` et `/getTemplates` en instantanés affichables.
  @visibleForTesting
  static List<DeviceSnapshot> parseDevices(
    String boxName,
    String devicesJson,
    Map<String, dynamic> templates,
  ) {
    final decoded = jsonDecode(devicesJson);
    if (decoded is! Map) return const [];

    final now = DateTime.now();
    final result = <DeviceSnapshot>[];
    for (final entry in decoded.entries) {
      final device = entry.value;
      if (device is! Map) continue;
      final info = device['INFO'];
      if (info is! Map) continue;

      final model = info['model']?.toString() ?? '';
      final block = templateBlock(templates, info['device_id']?.toString(), model);

      result.add(DeviceSnapshot(
        boxName: boxName,
        ieee: entry.key.toString(),
        label: _label(info, model, entry.key.toString()),
        model: model,
        shortAddr: int.tryParse(info['shortAddr']?.toString() ?? '') ?? 0,
        endpoint: int.tryParse(info['endpoint']?.toString() ?? '') ?? 1,
        readings: _readings(device, block),
        actions: _actions(block),
        timestamp: now,
      ));
    }
    return result;
  }

  /// Le bloc de gabarit qui s'applique à un appareil.
  ///
  /// Un gabarit propose une variante par modèle plus un `default` : le modèle
  /// exact l'emporte, faute de quoi on retombe sur le cas général — c'est ce
  /// que fait la box pour sa propre interface.
  @visibleForTesting
  static Map<String, dynamic>? templateBlock(
    Map<String, dynamic> templates,
    String? deviceId,
    String model,
  ) {
    if (deviceId == null) return null;
    final entry = templates['$deviceId.json'] ?? templates[deviceId];
    if (entry is! Map) return null;

    final variant = entry[model] ?? entry['default'] ??
        (entry.values.isEmpty ? null : entry.values.first);
    final block = variant is List
        ? (variant.isEmpty ? null : variant.first)
        : variant;
    return block is Map<String, dynamic> ? block : null;
  }

  /// Décode une valeur de `/getDevices`, donnée en hexadécimal.
  ///
  /// Les grandeurs sur 16 bits peuvent être négatives — une température sous
  /// zéro arrive en complément à deux, et la lire non signée donnerait 655 °C.
  @visibleForTesting
  static int? decodeHex(Object? raw) {
    var text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final negative = text.startsWith('-');
    if (negative) text = text.substring(1);
    final value = int.tryParse(text, radix: 16);
    if (value == null) return null;
    if (negative) return -value;
    if (text.length == 4 && value >= 0x8000) return value - 0x10000;
    return value;
  }

  static String _label(Map info, String model, String ieee) {
    final alias = info['alias']?.toString().trim() ?? '';
    if (alias.isNotEmpty) return alias;
    if (model.isNotEmpty) return model;
    return ieee;
  }

  static List<DeviceReading> _readings(Map device, Map<String, dynamic>? block) {
    final status = block?['status'];
    if (status is! List) return const [];

    final readings = <DeviceReading>[];
    for (final raw in status) {
      if (raw is! Map) continue;
      // Le firmware tient pour masqué tout ce qui n'a pas `visible: 1`, mais
      // affiche quand même la position d'un volet, qui ne porte pas le
      // drapeau. On retient plutôt : masqué si dit explicitement, ou si
      // l'entrée est un réglage (`writable`) — calibration, inversion de
      // moteur, seuils de confort n'ont rien à faire sur un écran d'accueil.
      if (raw['visible'] == 0 || raw['writable'] == true) continue;

      final cluster = raw['cluster']?.toString() ?? '';
      final attribute = raw['attribut']?.toString() ?? '';
      final stored = (device[cluster] as Map?)?[attribute];
      final decoded = decodeHex(stored);
      final coefficient = (raw['coefficient'] as num?)?.toDouble() ?? 1;

      readings.add(DeviceReading(
        name: raw['name']?.toString() ?? attribute,
        unit: raw['unit']?.toString(),
        value: decoded == null ? null : decoded * coefficient,
        min: (raw['min'] as num?)?.toDouble(),
        max: (raw['max'] as num?)?.toDouble(),
        gaugeKind: raw['jauge']?.toString(),
      ));
    }
    return readings;
  }

  static List<DeviceAction> _actions(Map<String, dynamic>? block) {
    final actions = block?['action'];
    if (actions is! List) return const [];

    final result = <DeviceAction>[];
    for (final raw in actions) {
      if (raw is! Map) continue;
      if (raw.containsKey('visible') && raw['visible'] != 1) continue;

      // Sans `command`, l'action passe par une écriture d'attribut ou un
      // datapoint Tuya — d'autres routes que /ZigbeeAction. L'interface de la
      // box ne les propose pas non plus ; les offrir ici enverrait une trame
      // au hasard sur un actionneur.
      final command = (raw['command'] as num?)?.toInt() ?? 0;
      if (command == 0) continue;

      result.add(DeviceAction(
        name: raw['name']?.toString() ?? '?',
        command: command,
        endpoint: (raw['endpoint'] as num?)?.toInt() ?? 1,
        value: (raw['value'] as num?)?.toInt() ?? 0,
        cluster: int.tryParse(raw['cluster']?.toString() ?? '', radix: 16),
        manufacturerCode: _parseMfr(raw['manufacturerSpecific']),
      ));
    }
    return result;
  }

  /// Le code constructeur est écrit `0x1021` dans les gabarits.
  static int? _parseMfr(Object? raw) {
    final text = raw?.toString().trim().toLowerCase() ?? '';
    if (text.isEmpty) return null;
    return int.tryParse(
      text.startsWith('0x') ? text.substring(2) : text,
      radix: 16,
    );
  }

  static Future<Map<String, dynamic>> _templatesFor(BoxRoute route) async {
    final cached = _templates[route.device.key];
    if (cached != null) return cached;

    final body = await BoxClient.get(route, '/getTemplates');
    if (body == null) return const {};
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const {};
    _templates[route.device.key] = decoded;
    return decoded;
  }
}

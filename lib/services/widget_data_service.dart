import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'network_scope.dart';
import 'session_manager.dart';
import 'session_pool.dart';

/// Clés `cluster_attribut` renvoyées par `GET /getLinky`.
///
/// Les identifiants sont ceux des clusters Zigbee en décimal :
/// 0x0702 Metering = 1794, 0x0B04 Electrical Measurement = 2820,
/// 0x0B01 Meter Identification = 2817, 0xFF66 (privé LiXee) = 65382.
class LinkyKeys {
  /// 0x050F ApparentPower — puissance apparente instantanée, en VA (le PAPP).
  static const apparentPower = '2820_1295';

  /// 0x0000 CurrentSummationDelivered — index total, en Wh.
  static const index = '1794_0';

  /// 0x0508 RMSCurrent — courant instantané, en A.
  static const current = '2820_1288';

  /// 0x050A RMSCurrentMax — IMAX, en A.
  static const currentMax = '2820_1290';

  /// Intensité souscrite, en A.
  static const subscribedCurrent = '2817_13';

  /// OPTARIF : "BASE", "HC..", "TEMPO"...
  static const contract = '65382_0';

  /// PTEC — période tarifaire en cours ("TH..", "HP..", "HC..").
  static const tariffPeriod = '1794_32';

  /// 0x0308 MeterSerialNumber — numéro de compteur (ADCO/ADSC).
  static const meterSerial = '1794_776';

  /// Index par tranche tarifaire. Tous à 0 en contrat BASE : ne pas les
  /// afficher sans avoir lu [contract] au préalable.
  static const tierIndexes = <String>[
    '1794_256',
    '1794_258',
    '1794_260',
    '1794_262',
    '1794_264',
    '1794_266',
  ];
}

/// Voie par laquelle le snapshot a été obtenu.
enum LinkySource { local, remote }

/// Consommation d'une heure, telle que renvoyée par `/exportEnergyChart`.
class HourlySample {
  /// Heure de début, de 0 à 23.
  final int hour;

  /// Énergie consommée sur l'heure, en Wh.
  final int wh;

  /// Coût de l'heure en euros, abonnement et taxes compris.
  ///
  /// Vaut 0 quand aucun tarif n'est paramétré sur la box. La valeur vient de
  /// la colonne `Conso - Cout total` de l'export : c'est la box qui applique
  /// les tarifs HC/HP, rien n'est recalculé ici.
  final double costEur;

  const HourlySample(this.hour, this.wh, [this.costEur = 0]);

  Map<String, dynamic> toJson() => {'h': hour, 'wh': wh, 'c': costEur};

  factory HourlySample.fromJson(Map<String, dynamic> json) => HourlySample(
        json['h'] as int? ?? 0,
        json['wh'] as int? ?? 0,
        (json['c'] as num?)?.toDouble() ?? 0,
      );
}

/// Relevé horodaté des métriques d'une box, tel que consommé par le widget.
///
/// Le code natif ne doit jamais savoir d'où vient la valeur : il lit ce
/// snapshot et affiche son âge.
class LinkySnapshot {
  final String deviceName;

  /// Puissance apparente instantanée, en VA.
  final int? apparentPowerVA;

  /// Index total, en Wh.
  final int? indexWh;

  final int? currentA;

  /// Intensité souscrite au contrat, en A. Sert d'échelle à la jauge.
  final int? subscribedCurrentA;

  final String? contract;
  final String? tariffPeriod;
  final String? meterSerial;
  final List<int> tierIndexesWh;

  /// Consommation heure par heure sur les 24 dernières heures, dans l'ordre
  /// chronologique renvoyé par la box. Vide si l'export n'a pas abouti.
  final List<HourlySample> hourly;

  final LinkySource source;
  final DateTime timestamp;

  const LinkySnapshot({
    required this.deviceName,
    required this.timestamp,
    required this.source,
    this.apparentPowerVA,
    this.indexWh,
    this.currentA,
    this.subscribedCurrentA,
    this.contract,
    this.tariffPeriod,
    this.meterSerial,
    this.tierIndexesWh = const [],
    this.hourly = const [],
  });

  /// Total des 24 heures relevées, en Wh. `null` si l'export a échoué —
  /// afficher 0 laisserait croire à une consommation nulle.
  int? get dailyTotalWh => hourly.isEmpty
      ? null
      : hourly.fold<int>(0, (sum, sample) => sum + sample.wh);

  /// Évolution entre les deux dernières heures **complètes**, en pourcentage.
  ///
  /// La dernière entrée de la série est l'heure en cours, donc partielle :
  /// la comparer donnerait une chute systématique en début d'heure. On compare
  /// donc l'avant-dernière à celle qui la précède.
  ///
  /// `null` si l'historique est trop court ou si l'heure de référence est
  /// nulle — une variation relative n'y aurait pas de sens.
  double? get hourlyTrendPct {
    if (hourly.length < 3) return null;
    final reference = hourly[hourly.length - 3].wh;
    final last = hourly[hourly.length - 2].wh;
    if (reference <= 0) return null;
    return (last - reference) / reference * 100;
  }

  /// Coût des 24 heures, en euros. `null` si aucun tarif n'est paramétré sur
  /// la box — l'export renvoie alors des colonnes à zéro, qu'il ne faut pas
  /// afficher comme une consommation gratuite.
  double? get dailyCostEur {
    if (hourly.isEmpty) return null;
    final total = hourly.fold<double>(0, (sum, s) => sum + s.costEur);
    return total > 0 ? total : null;
  }

  /// Puissance souscrite, en VA.
  ///
  /// Le compteur ne publie que l'intensité souscrite. Le facteur 200 n'est pas
  /// une tension mais la convention des paliers d'abonnement : 30 A → 6 kVA,
  /// 45 A → 9 kVA, 60 A → 12 kVA.
  int? get subscribedPowerVA =>
      subscribedCurrentA == null ? null : subscribedCurrentA! * 200;

  /// Index total du compteur, en Wh, toutes tranches confondues.
  ///
  /// En contrat BASE la box renseigne `1794_0`. En HP/HC elle le laisse à zéro
  /// et ne remplit que les index par tranche : s'en tenir à `1794_0` afficherait
  /// un index nul à ces abonnés.
  int? get totalIndexWh {
    if (indexWh != null && indexWh! > 0) return indexWh;
    final tiers = tierIndexesWh.fold<int>(0, (sum, wh) => sum + wh);
    if (tiers > 0) return tiers;
    return indexWh;
  }

  /// Index total en kWh, pour l'affichage.
  double? get indexKWh =>
      totalIndexWh == null ? null : totalIndexWh! / 1000.0;

  /// Le contrat est-il en tarif unique ? Les index par tranche sont alors
  /// tous nuls et seul [indexWh] porte de l'information.
  bool get isSingleTariff => (contract ?? '').toUpperCase().startsWith('BASE');

  Duration get age => DateTime.now().difference(timestamp);

  /// Construit un snapshot depuis la réponse brute de `/getLinky`.
  factory LinkySnapshot.fromLinkyJson(
    Map<String, dynamic> json, {
    required String deviceName,
    required LinkySource source,
    DateTime? timestamp,
  }) {
    return LinkySnapshot(
      deviceName: deviceName,
      timestamp: timestamp ?? DateTime.now(),
      source: source,
      apparentPowerVA: _asInt(json[LinkyKeys.apparentPower]),
      indexWh: _asInt(json[LinkyKeys.index]),
      currentA: _asInt(json[LinkyKeys.current]),
      subscribedCurrentA: _asInt(json[LinkyKeys.subscribedCurrent]),
      contract: _asString(json[LinkyKeys.contract]),
      tariffPeriod: _asString(json[LinkyKeys.tariffPeriod]),
      meterSerial: _asString(json[LinkyKeys.meterSerial]),
      tierIndexesWh: LinkyKeys.tierIndexes
          .map((k) => _asInt(json[k]) ?? 0)
          .toList(growable: false),
    );
  }

  /// L'export horaire arrive par une seconde requête : on l'attache après coup.
  LinkySnapshot withHourly(List<HourlySample> samples) => LinkySnapshot(
        deviceName: deviceName,
        timestamp: timestamp,
        source: source,
        apparentPowerVA: apparentPowerVA,
        indexWh: indexWh,
        currentA: currentA,
        subscribedCurrentA: subscribedCurrentA,
        contract: contract,
        tariffPeriod: tariffPeriod,
        meterSerial: meterSerial,
        tierIndexesWh: tierIndexesWh,
        hourly: samples,
      );

  Map<String, dynamic> toJson() => {
        'deviceName': deviceName,
        'hourly': hourly.map((s) => s.toJson()).toList(),
        'apparentPowerVA': apparentPowerVA,
        'indexWh': indexWh,
        'currentA': currentA,
        'subscribedCurrentA': subscribedCurrentA,
        'contract': contract,
        'tariffPeriod': tariffPeriod,
        'meterSerial': meterSerial,
        'tierIndexesWh': tierIndexesWh,
        'source': source.name,
        'ts': timestamp.millisecondsSinceEpoch,
      };

  factory LinkySnapshot.fromJson(Map<String, dynamic> json) {
    return LinkySnapshot(
      deviceName: json['deviceName'] as String? ?? '',
      apparentPowerVA: _asInt(json['apparentPowerVA']),
      indexWh: _asInt(json['indexWh']),
      currentA: _asInt(json['currentA']),
      subscribedCurrentA: _asInt(json['subscribedCurrentA']),
      contract: _asString(json['contract']),
      tariffPeriod: _asString(json['tariffPeriod']),
      meterSerial: _asString(json['meterSerial']),
      tierIndexesWh:
          (json['tierIndexesWh'] as List?)?.map((e) => _asInt(e) ?? 0).toList() ??
              const [],
      hourly: (json['hourly'] as List?)
              ?.map((e) => HourlySample.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      source: json['source'] == 'local' ? LinkySource.local : LinkySource.remote,
      timestamp:
          DateTime.fromMillisecondsSinceEpoch(_asInt(json['ts']) ?? 0),
    );
  }

  /// Le firmware renvoie tantôt des nombres, tantôt des chaînes.
  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String? _asString(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }

  @override
  String toString() =>
      'LinkySnapshot($deviceName, ${apparentPowerVA}VA, ${indexKWh?.toStringAsFixed(1)}kWh, '
      '${hourly.length}h/${dailyTotalWh}Wh, ${source.name}, ${age.inSeconds}s)';
}

/// Entrée `saved_devices` décodée.
///
/// Formats supportés : `name|url`, `name|url|fallback`,
/// `name|url|auth|login|pass`, `name|url|auth|login|pass|fallback`.
class _ParsedDevice {
  final String name;
  final String primaryUrl;
  final String? fallbackUrl;
  final String? login;
  final String? password;

  const _ParsedDevice({
    required this.name,
    required this.primaryUrl,
    this.fallbackUrl,
    this.login,
    this.password,
  });

  bool get hasAuth => login != null && password != null;

  String get key => '$name|$primaryUrl';

  static _ParsedDevice? tryParse(String entry) {
    final parts = entry.split('|');
    if (parts.length < 2) return null;

    final hasAuth = parts.length >= 5 && parts[2] == 'auth';

    if (hasAuth && (parts.length == 5 || parts.length == 6)) {
      return _ParsedDevice(
        name: parts[0],
        primaryUrl: parts[1],
        login: parts[3],
        password: parts[4],
        fallbackUrl: parts.length == 6 ? parts[5] : null,
      );
    }
    if (parts.length == 2) {
      return _ParsedDevice(name: parts[0], primaryUrl: parts[1]);
    }
    if (parts.length == 3 && parts[2] != 'auth') {
      return _ParsedDevice(
        name: parts[0],
        primaryUrl: parts[1],
        fallbackUrl: parts[2],
      );
    }
    return null;
  }
}

/// Récupère les métriques Linky d'une box et les persiste pour le widget.
///
/// Marche indifféremment en accès LAN ou via le tunnel `remote.lixee-box.fr` :
/// seule la base URL change, et la cascade primaire/fallback des entrées
/// `saved_devices` s'en charge.
///
/// Ne dépend d'aucun `BuildContext` — appelable depuis un worker WorkManager,
/// un service de premier plan ou un handler FCM.
class WidgetDataService {
  static const _prefsKeyPrefix = 'widget_snapshot_';

  /// Une requête LAN qui n'a pas répondu en 3 s ne répondra pas : on bascule.
  static const defaultLocalTimeout = Duration(seconds: 3);

  /// Le tunnel relaie par WebSocket et impose un login formulaire : il lui faut
  /// nettement plus de marge qu'un accès direct.
  static const defaultRemoteTimeout = Duration(seconds: 10);

  /// Dernière URL ayant répondu, par device. Évite de retenter systématiquement
  /// l'IP locale en timeout quand on n'est pas sur le réseau de la box.
  static final Map<String, String> _lastGoodUrl = {};

  /// Relève une box. Retourne `null` si aucune URL n'a répondu.
  ///
  /// [mdnsResolver] est requis pour les hôtes `.local` ; passer
  /// `resolveMdnsIP` si l'appelant y a accès.
  static Future<LinkySnapshot?> fetchForDevice(
    String deviceEntry, {
    Future<String?> Function(String deviceName)? mdnsResolver,
    Duration localTimeout = defaultLocalTimeout,
    Duration remoteTimeout = defaultRemoteTimeout,
  }) async {
    final device = _ParsedDevice.tryParse(deviceEntry);
    if (device == null) {
      print('[WIDGET-DATA] Entrée illisible: $deviceEntry');
      return null;
    }

    for (final candidate in _orderedCandidates(device)) {
      final baseUrl = await _resolve(candidate, device.name, mdnsResolver);
      if (baseUrl == null) continue;

      final source = _classify(baseUrl);
      final timeout =
          source == LinkySource.local ? localTimeout : remoteTimeout;

      try {
        final body =
            await _authGet(baseUrl, device, timeout, source, '/getLinky');
        if (body == null) {
          print('[WIDGET-DATA] $baseUrl: pas de réponse exploitable');
          _dropSession(baseUrl, device);
          continue;
        }

        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          print('[WIDGET-DATA] $baseUrl: JSON inattendu');
          continue;
        }

        _lastGoodUrl[device.key] = candidate;
        var snapshot = LinkySnapshot.fromLinkyJson(
          decoded,
          deviceName: device.name,
          source: source,
        );

        // Complément facultatif : un échec ici ne doit pas perdre le relevé.
        try {
          final hourly = await _fetchHourly(baseUrl, device, timeout, source);
          if (hourly.isNotEmpty) snapshot = snapshot.withHourly(hourly);
        } catch (e) {
          print('[WIDGET-DATA] Export horaire indisponible: $e');
        }

        print('[WIDGET-DATA] $snapshot');
        return snapshot;
      } catch (e) {
        print('[WIDGET-DATA] $baseUrl échec: $e');
        _dropSession(baseUrl, device);
      }
    }

    print('[WIDGET-DATA] Aucune URL joignable pour ${device.name}');
    return null;
  }

  /// Noms des box enregistrées, dans l'ordre de `saved_devices`.
  ///
  /// L'activité de configuration du widget s'en sert pour proposer un choix,
  /// y compris avant qu'un premier relevé ait eu lieu.
  static Future<List<String>> savedDeviceNames() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return (prefs.getStringList('saved_devices') ?? [])
        .map(_ParsedDevice.tryParse)
        .whereType<_ParsedDevice>()
        .map((d) => d.name)
        .toList(growable: false);
  }

  /// Relève toutes les box enregistrées et persiste les snapshots.
  /// C'est le point d'entrée des workers background.
  static Future<List<LinkySnapshot>> refreshAll({
    Future<String?> Function(String deviceName)? mdnsResolver,
    Duration localTimeout = defaultLocalTimeout,
    Duration remoteTimeout = defaultRemoteTimeout,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final entries = prefs.getStringList('saved_devices') ?? [];

    final snapshots = <LinkySnapshot>[];
    for (final entry in entries) {
      final snapshot = await fetchForDevice(
        entry,
        mdnsResolver: mdnsResolver,
        localTimeout: localTimeout,
        remoteTimeout: remoteTimeout,
      );
      if (snapshot != null) {
        await saveSnapshot(snapshot);
        snapshots.add(snapshot);
      }
    }
    return snapshots;
  }

  /// Persiste un snapshot, sauf si un plus récent est déjà stocké.
  ///
  /// Plusieurs sources peuvent écrire en concurrence — un poll encore en vol
  /// et un push qui arrive. Sans cette garde, la réponse lente écrase la
  /// valeur fraîche. Retourne `false` si l'écriture a été refusée.
  static Future<bool> saveSnapshot(LinkySnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final key = _prefsKeyPrefix + snapshot.deviceName;

    final existing = prefs.getString(key);
    if (existing != null) {
      try {
        final previous = LinkySnapshot.fromJson(jsonDecode(existing));
        if (!snapshot.timestamp.isAfter(previous.timestamp)) {
          return false;
        }
      } catch (_) {
        // Snapshot précédent illisible : on l'écrase.
      }
    }

    await prefs.setString(key, jsonEncode(snapshot.toJson()));
    return true;
  }

  /// Relit le dernier snapshot connu, sans accès réseau.
  static Future<LinkySnapshot?> readSnapshot(String deviceName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_prefsKeyPrefix + deviceName);
    if (raw == null) return null;
    try {
      return LinkySnapshot.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// Ferme les sessions ouvertes.
  ///
  /// À n'appeler que depuis un isolate qui se termine : au premier plan, ces
  /// sessions sont partagées avec l'écran d'accueil.
  static void disposeAll() => SessionPool.closeAll();

  // --- Interne -------------------------------------------------------------

  /// URLs à tenter, la dernière qui a fonctionné en premier.
  static List<String> _orderedCandidates(_ParsedDevice device) {
    final candidates = <String>[device.primaryUrl];
    final fallback = device.fallbackUrl;
    if (fallback != null && fallback.isNotEmpty) {
      candidates.add(fallback);
    }

    final lastGood = _lastGoodUrl[device.key];
    if (lastGood != null && candidates.remove(lastGood)) {
      candidates.insert(0, lastGood);
    }
    return candidates;
  }

  static Future<String?> _resolve(
    String candidate,
    String deviceName,
    Future<String?> Function(String)? mdnsResolver,
  ) async {
    var url = candidate.trim();
    if (url.isEmpty) return null;
    if (!url.startsWith('http')) url = 'http://$url';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    final host = Uri.tryParse(url)?.host ?? '';
    if (host.endsWith('.local') && mdnsResolver != null) {
      final ip = await mdnsResolver(deviceName);
      return ip == null ? null : 'http://$ip';
    }
    return url;
  }

  /// Adresse IEEE du ZLinky, par box. Découverte une fois via `/getDevices`,
  /// qui est bien plus lourd que l'export lui-même.
  static final Map<String, String> _linkyIeee = {};

  /// Dernier export horaire réussi, par box. L'historique ne bouge qu'à
  /// l'heure : inutile de le retélécharger à chaque relevé.
  static final Map<String, DateTime> _lastHourlyFetch = {};
  static const _hourlyInterval = Duration(minutes: 10);

  /// Récupère la consommation horaire des 24 dernières heures.
  ///
  /// Retourne une liste vide en cas d'échec : le graphe est un complément,
  /// son absence ne doit jamais faire échouer le relevé principal.
  static Future<List<HourlySample>> _fetchHourly(
    String baseUrl,
    _ParsedDevice device,
    Duration timeout,
    LinkySource source,
  ) async {
    final last = _lastHourlyFetch[device.key];
    if (last != null && DateTime.now().difference(last) < _hourlyInterval) {
      return const [];
    }

    var ieee = _linkyIeee[device.key];
    if (ieee == null) {
      final body = await _authGet(baseUrl, device, timeout, source, '/getDevices');
      if (body == null) return const [];
      ieee = _findLinkyIeee(body);
      if (ieee == null) {
        print('[WIDGET-DATA] Aucun ZLinky trouvé sur ${device.name}');
        return const [];
      }
      _linkyIeee[device.key] = ieee;
    }

    final csv = await _authGet(
      baseUrl,
      device,
      timeout,
      source,
      '/exportEnergyChart?IEEE=$ieee&time=hour',
    );
    if (csv == null) return const [];

    _lastHourlyFetch[device.key] = DateTime.now();
    return parseHourlyCsv(csv);
  }

  /// Repère le ZLinky parmi les équipements Zigbee appairés.
  static String? _findLinkyIeee(String devicesJson) {
    try {
      final decoded = jsonDecode(devicesJson);
      if (decoded is! Map<String, dynamic>) return null;
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final info = value['INFO'];
        if (info is Map && (info['model']?.toString() ?? '').startsWith('ZLinky')) {
          return entry.key;
        }
      }
    } catch (e) {
      print('[WIDGET-DATA] /getDevices illisible: $e');
    }
    return null;
  }

  /// Décode le CSV de `/exportEnergyChart`.
  ///
  /// Format : BOM UTF-8, séparateur `;`, une ligne par heure (`18H;167;167;…`).
  /// Les colonnes utiles sont repérées par leur en-tête et non par leur rang :
  /// une box en BASE renvoie 7 colonnes, une box en HP/HC 9 — avec en prime
  /// des cellules vides pour la période inactive et une colonne de sous-comptage
  /// quand un usage est suivi à part.
  @visibleForTesting
  static List<HourlySample> parseHourlyCsv(String csv) {
    final lines = csv
        .replaceFirst('﻿', '')
        .split(RegExp(r'\r?\n'))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) return const [];

    final header = lines.first.split(';');
    var column = header.indexWhere(
      (h) => h.toLowerCase().contains('consommation totale'),
    );
    if (column < 0) column = 1; // Repli : la première colonne de valeurs.

    // Absente si aucun tarif n'est paramétré sur la box.
    final costColumn = header.indexWhere(
      (h) => h.toLowerCase().contains('cout total'),
    );

    final samples = <HourlySample>[];
    for (final line in lines.skip(1)) {
      final cells = line.split(';');
      if (cells.length <= column) continue;

      final hour = int.tryParse(cells[0].replaceAll(RegExp(r'[^0-9]'), ''));
      final wh = int.tryParse(cells[column].trim());
      if (hour == null || wh == null) continue;

      // Les montants arrivent avec une virgule décimale.
      final cost = costColumn >= 0 && cells.length > costColumn
          ? double.tryParse(cells[costColumn].trim().replaceAll(',', '.')) ?? 0
          : 0.0;

      samples.add(HourlySample(hour, wh, cost));
    }
    return samples;
  }

  static void _dropSession(String baseUrl, _ParsedDevice device) {
    if (device.login != null) {
      SessionPool.invalidate(baseUrl, device.login!);
    }
  }

  /// GET authentifié sur la box, quel que soit le mode d'auth.
  ///
  /// [path] commence par `/`. Retourne `null` si la requête n'aboutit pas.
  static Future<String?> _authGet(
    String baseUrl,
    _ParsedDevice device,
    Duration timeout,
    LinkySource source,
    String path,
  ) async {
    if (!device.hasAuth) {
      return _rawGet('$baseUrl$path', timeout);
    }

    final basic =
        'Basic ${base64Encode(utf8.encode('${device.login}:${device.password}'))}';

    // En LAN la box accepte le Basic : une requête unique, sans état ni cookie
    // à entretenir. C'est le tunnel qui impose le formulaire, pas le firmware.
    var basicTried = false;
    if (source == LinkySource.local) {
      basicTried = true;
      final body = await _rawGet('$baseUrl$path', timeout, authHeader: basic);
      if (body != null) return body;
      print('[WIDGET-DATA] Basic refusé sur $baseUrl, bascule sur le formulaire');
    }

    final mode = await SessionPool.authMode(baseUrl, timeout: timeout);
    if (mode == AuthMode.form) {
      final session =
          SessionPool.session(baseUrl, device.login!, device.password!);
      final result = await session.authenticatedGet(path).timeout(timeout);
      if (result.statusCode == 200 && result.body.isNotEmpty) {
        return result.body;
      }
      print('[WIDGET-DATA] Formulaire KO (${result.statusCode}) sur $baseUrl$path');
    }

    // Inutile de rejouer le Basic si la voie LAN l'a déjà refusé.
    return basicTried
        ? null
        : _rawGet('$baseUrl$path', timeout, authHeader: basic);
  }

  static Future<String?> _rawGet(
    String url,
    Duration timeout, {
    String? authHeader,
  }) async {
    final client = HttpClient()
      ..badCertificateCallback = ((cert, host, port) => true)
      ..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Accept', 'application/json');
      if (authHeader != null) {
        request.headers.set('Authorization', authHeader);
      }
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();
      return response.statusCode == 200 && body.isNotEmpty ? body : null;
    } finally {
      client.close(force: true);
    }
  }

  /// Distingue un accès LAN d'un accès par le tunnel, pour l'afficher.
  static LinkySource _classify(String baseUrl) =>
      isLanUrl(baseUrl) ? LinkySource.local : LinkySource.remote;
}

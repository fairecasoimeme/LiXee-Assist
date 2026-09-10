import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'box_client.dart';

/// [LinkySource] appartient au transport, mais reste visible d'ici : c'est par
/// ce service que tout le reste de l'app la connait.
export 'box_client.dart' show LinkySource;

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

  /// Énergie injectée sur l'heure, en Wh. Vaut 0 hors installation productrice.
  final int productionWh;

  /// Revenu de l'injection sur l'heure, en euros.
  final double revenueEur;

  const HourlySample(
    this.hour,
    this.wh, [
    this.costEur = 0,
    this.productionWh = 0,
    this.revenueEur = 0,
  ]);

  /// Solde de l'heure : positif si l'on a tiré du réseau, négatif si l'on y a
  /// injecté plus qu'on n'a consommé.
  int get netWh => wh - productionWh;

  /// Solde facturé. Négatif quand l'injection rapporte plus qu'elle ne coûte.
  double get netCostEur => costEur - revenueEur;

  Map<String, dynamic> toJson() =>
      {'h': hour, 'wh': wh, 'c': costEur, 'p': productionWh, 'r': revenueEur};

  factory HourlySample.fromJson(Map<String, dynamic> json) => HourlySample(
        json['h'] as int? ?? 0,
        json['wh'] as int? ?? 0,
        (json['c'] as num?)?.toDouble() ?? 0,
        json['p'] as int? ?? 0,
        (json['r'] as num?)?.toDouble() ?? 0,
      );
}

/// Relevé horodaté des métriques d'une box, tel que consommé par le widget.
///
/// Le code natif ne doit jamais savoir d'où vient la valeur : il lit ce
/// snapshot et affiche son âge.
class LinkySnapshot {
  final String deviceName;

  /// Puissance apparente instantanée soutirée, en VA.
  final int? apparentPowerVA;

  /// Puissance apparente instantanée injectée, en VA. `null` hors installation
  /// productrice. Sur un producteur, l'une des deux est nulle à tout instant.
  final int? productionPowerVA;

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
    this.productionPowerVA,
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

  /// L'installation injecte-t-elle sur le réseau ? Détermine si les thèmes
  /// production et bilan ont quelque chose à montrer.
  bool get produces => hourly.any((s) => s.productionWh > 0);

  /// Énergie injectée sur 24 h, en Wh. `null` hors installation productrice.
  int? get dailyProductionWh => produces
      ? hourly.fold<int>(0, (sum, s) => sum + s.productionWh)
      : null;

  /// Revenu de l'injection sur 24 h, en euros.
  double? get dailyRevenueEur {
    if (!produces) return null;
    final total = hourly.fold<double>(0, (sum, s) => sum + s.revenueEur);
    return total > 0 ? total : null;
  }

  /// Solde énergétique sur 24 h : positif si l'on a tiré du réseau, négatif si
  /// l'installation a injecté plus qu'elle n'a consommé.
  int? get dailyNetWh =>
      hourly.isEmpty ? null : hourly.fold<int>(0, (sum, s) => sum + s.netWh);

  /// Facture nette sur 24 h. Négative quand l'injection rapporte davantage
  /// qu'elle ne coûte.
  double? get dailyNetCostEur => hourly.isEmpty
      ? null
      : hourly.fold<double>(0, (sum, s) => sum + s.netCostEur);

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

  /// L'export horaire et la production arrivent par des requêtes séparées :
  /// on les attache après coup.
  LinkySnapshot withHourly(
    List<HourlySample> samples, {
    int? productionPowerVA,
  }) =>
      LinkySnapshot(
        deviceName: deviceName,
        timestamp: timestamp,
        source: source,
        apparentPowerVA: apparentPowerVA,
        productionPowerVA: productionPowerVA ?? this.productionPowerVA,
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
        'productionPowerVA': productionPowerVA,
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
      productionPowerVA: _asInt(json['productionPowerVA']),
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
  String toString() {
    final injected =
        productionPowerVA == null ? '' : ', +${productionPowerVA}VA injectés';
    final production =
        dailyProductionWh == null ? '' : '/${dailyProductionWh}Wh produits';
    return 'LinkySnapshot($deviceName, ${apparentPowerVA}VA$injected, '
        '${indexKWh?.toStringAsFixed(1)}kWh, '
        '${hourly.length}h/${dailyTotalWh}Wh$production, '
        '${source.name}, ${age.inSeconds}s)';
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

  static const defaultLocalTimeout = BoxClient.defaultLocalTimeout;
  static const defaultRemoteTimeout = BoxClient.defaultRemoteTimeout;

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
    final device = BoxDevice.tryParse(deviceEntry);
    if (device == null) {
      print('[WIDGET-DATA] Entrée illisible: $deviceEntry');
      return null;
    }

    final routes = BoxClient.routes(
      device,
      mdnsResolver: mdnsResolver,
      localTimeout: localTimeout,
      remoteTimeout: remoteTimeout,
    );
    await for (final (candidate, route) in routes) {
      final baseUrl = route.baseUrl;

      try {
        final body = await BoxClient.get(route, '/getLinky');
        if (body == null) {
          print('[WIDGET-DATA] $baseUrl: pas de réponse exploitable');
          BoxClient.dropSession(route);
          continue;
        }

        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          print('[WIDGET-DATA] $baseUrl: JSON inattendu');
          continue;
        }

        BoxClient.remember(device, candidate);
        var snapshot = LinkySnapshot.fromLinkyJson(
          decoded,
          deviceName: device.name,
          source: route.source,
        );

        // Compléments facultatifs : un échec ici ne doit pas perdre le relevé.
        try {
          final hourly = await _fetchHourly(route);
          // La découverte des compteurs a lieu dans _fetchHourly : la
          // production ne peut être lue qu'ensuite.
          final injected = await _fetchProductionPower(route);
          if (hourly.isNotEmpty || injected != null) {
            snapshot = snapshot.withHourly(
              hourly.isNotEmpty ? hourly : snapshot.hourly,
              productionPowerVA: injected,
            );
          }
        } catch (e) {
          print('[WIDGET-DATA] Complément indisponible: $e');
        }

        print('[WIDGET-DATA] $snapshot');
        return snapshot;
      } catch (e) {
        print('[WIDGET-DATA] $baseUrl échec: $e');
        BoxClient.dropSession(route);
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
        .map(BoxDevice.tryParse)
        .whereType<BoxDevice>()
        .map((d) => d.name)
        .toList(growable: false);
  }

  /// Relève les box enregistrées et persiste les snapshots.
  /// C'est le point d'entrée des workers background.
  ///
  /// [only] restreint le relevé à une box : sur un appui, le widget touché est
  /// le seul qui intéresse l'utilisateur, et balayer les autres allongerait
  /// l'attente de plusieurs secondes par box injoignable.
  ///
  /// [onResult] est appelé au fil de l'eau, une box après l'autre, avec un
  /// snapshot ou `null` si elle n'a pas répondu. C'est ce qui permet de
  /// publier au fur et à mesure : le système peut tuer le processus en cours
  /// de balayage, et tout ce qui n'a pas été écrit avant est perdu.
  ///
  /// Les box injoignables sont rapportées à part : sans elles, un échec est
  /// indiscernable d'un succès côté widget, qui garderait ses chiffres avec le
  /// même aplomb.
  static Future<({List<LinkySnapshot> snapshots, List<String> unreachable})>
      refreshAll({
    Future<String?> Function(String deviceName)? mdnsResolver,
    Duration localTimeout = defaultLocalTimeout,
    Duration remoteTimeout = defaultRemoteTimeout,
    String? only,
    Future<void> Function(String name, LinkySnapshot? snapshot)? onResult,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final entries = prefs.getStringList('saved_devices') ?? [];

    final snapshots = <LinkySnapshot>[];
    final unreachable = <String>[];
    for (final entry in entries) {
      final device = BoxDevice.tryParse(entry);
      if (device == null) continue;
      if (only != null && device.name != only) continue;

      final snapshot = await fetchForDevice(
        entry,
        mdnsResolver: mdnsResolver,
        localTimeout: localTimeout,
        remoteTimeout: remoteTimeout,
      );
      if (snapshot != null) {
        await saveSnapshot(snapshot);
        snapshots.add(snapshot);
      } else {
        unreachable.add(device.name);
      }
      await onResult?.call(device.name, snapshot);
    }
    return (snapshots: snapshots, unreachable: unreachable);
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
  static void disposeAll() => BoxClient.disposeAll();

  // --- Interne -------------------------------------------------------------

  /// Adresse IEEE du ZLinky, par box. Découverte une fois via `/getDevices`,
  /// qui est bien plus lourd que l'export lui-même.
  static final Map<String, String> _linkyIeee = {};

  /// IEEE du compteur de production, quand l'installation en a un.
  static final Map<String, String> _productionIeee = {};

  /// SINSTI, puissance apparente injectée, dans le cluster privé LiXee.
  ///
  /// Identifié en comparant deux relevés pendant que la production chutait :
  /// cet attribut est passé de 1179 à 268 en suivant l'export horaire, quand
  /// 0x0B04/0x0511 restait figé autour de 230 — c'était la tension, dont la
  /// proximité numérique avec une puissance plausible avait d'abord induit en
  /// erreur. L'attribut voisin 0x0208 varie en sens inverse : c'est SINSTS.
  ///
  /// Ces libellés n'existent qu'en mode standard ; en historique le cluster
  /// les laisse à zéro. `/getLinky` ne remonte qu'un seul compteur, d'où le
  /// passage par `/getDevice`.
  static const _injectedPowerCluster = 'FF66';
  static const _injectedPowerAttribute = '519';

  /// Relève la puissance injectée. `null` sans compteur de production.
  static Future<int?> _fetchProductionPower(BoxRoute route) async {
    final ieee = _productionIeee[route.device.key];
    if (ieee == null) return null;

    final body = await BoxClient.get(route, '/getDevice?id=$ieee');
    if (body == null) return null;

    try {
      var decoded = jsonDecode(body);
      // La réponse est tantôt l'objet direct, tantôt indexée par IEEE.
      if (decoded is Map && decoded[ieee] is Map) decoded = decoded[ieee];
      if (decoded is! Map) return null;
      final cluster = decoded[_injectedPowerCluster];
      if (cluster is! Map) return null;
      return _fromHex(cluster[_injectedPowerAttribute]);
    } catch (e) {
      print('[WIDGET-DATA] /getDevice illisible: $e');
      return null;
    }
  }

  /// Dernier export horaire réussi, par box. L'historique ne bouge qu'à
  /// l'heure : inutile de le retélécharger à chaque relevé.
  static final Map<String, DateTime> _lastHourlyFetch = {};
  static const _hourlyInterval = Duration(minutes: 10);

  /// Récupère la consommation horaire des 24 dernières heures.
  ///
  /// Retourne une liste vide en cas d'échec : le graphe est un complément,
  /// son absence ne doit jamais faire échouer le relevé principal.
  static Future<List<HourlySample>> _fetchHourly(BoxRoute route) async {
    final device = route.device;
    final last = _lastHourlyFetch[device.key];
    if (last != null && DateTime.now().difference(last) < _hourlyInterval) {
      return const [];
    }

    var ieee = _linkyIeee[device.key];
    if (ieee == null) {
      final body = await BoxClient.get(route, '/getDevices');
      if (body == null) return const [];
      final meters = _discoverMeters(body);
      ieee = meters.consumption;
      if (ieee == null) {
        print('[WIDGET-DATA] Aucun ZLinky trouvé sur ${device.name}');
        return const [];
      }
      _linkyIeee[device.key] = ieee;
      if (meters.production != null) {
        _productionIeee[device.key] = meters.production!;
        print('[WIDGET-DATA] ${device.name}: compteur de production détecté');
      }
    }

    final csv = await BoxClient.get(
      route,
      '/exportEnergyChart?IEEE=$ieee&time=hour',
    );
    if (csv == null) return const [];

    _lastHourlyFetch[device.key] = DateTime.now();
    return parseHourlyCsv(csv);
  }

  /// Repère les ZLinky appairés et distingue celui de production.
  ///
  /// Une installation productrice en porte deux : le contrat du second est
  /// annoncé `PRODUCTEUR` dans le cluster privé LiXee. On ne se fie pas au
  /// `linkyMode`, dont les valeurs varient selon le firmware.
  static ({String? consumption, String? production}) _discoverMeters(
    String devicesJson,
  ) {
    String? consumption;
    String? production;
    try {
      final decoded = jsonDecode(devicesJson);
      if (decoded is! Map<String, dynamic>) return (consumption: null, production: null);

      for (final entry in decoded.entries) {
        final device = entry.value;
        if (device is! Map) continue;
        final info = device['INFO'];
        if (info is! Map) continue;
        if (!(info['model']?.toString() ?? '').startsWith('ZLinky')) continue;

        final contract = (device['FF66'] as Map?)?['0']?.toString() ?? '';
        if (contract.toUpperCase().contains('PRODUCTEUR')) {
          production ??= entry.key;
        } else {
          consumption ??= entry.key;
        }
      }
    } catch (e) {
      print('[WIDGET-DATA] /getDevices illisible: $e');
    }
    return (consumption: consumption, production: production);
  }

  /// Décode une valeur de `/getDevices`, donnée en hexadécimal signé
  /// (`00E6`, `-0000005B4C05`) là où `/getLinky` renvoie des décimaux.
  static int? _fromHex(Object? raw) {
    var text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final negative = text.startsWith('-');
    if (negative) text = text.substring(1);
    final value = int.tryParse(text, radix: 16);
    return value == null ? null : (negative ? -value : value);
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

    // Absentes hors installation productrice. « Production totale » et non
    // « Production » tout court : la seconde porte la valeur signée, la
    // première la quantité injectée.
    final productionColumn = header.indexWhere(
      (h) => h.toLowerCase().contains('production totale'),
    );
    final revenueColumn = header.indexWhere(
      (h) => h.toLowerCase().contains('revenu'),
    );

    final samples = <HourlySample>[];
    for (final line in lines.skip(1)) {
      final cells = line.split(';');
      if (cells.length <= column) continue;

      final hour = int.tryParse(cells[0].replaceAll(RegExp(r'[^0-9]'), ''));
      final wh = int.tryParse(cells[column].trim());
      if (hour == null || wh == null) continue;

      samples.add(HourlySample(
        hour,
        wh,
        _cell(cells, costColumn),
        _cell(cells, productionColumn).round(),
        _cell(cells, revenueColumn),
      ));
    }
    return samples;
  }

  /// Lit une cellule numérique. Les montants arrivent avec une virgule
  /// décimale, et l'export laisse des cellules vides pour ce qui ne s'applique
  /// pas à l'heure considérée.
  static double _cell(List<String> cells, int column) {
    if (column < 0 || cells.length <= column) return 0;
    return double.tryParse(cells[column].trim().replaceAll(',', '.')) ?? 0;
  }

}

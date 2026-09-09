import 'dart:convert';

import 'package:home_widget/home_widget.dart';

import 'action_group_service.dart';
import 'device_control_service.dart';
import 'widget_data_service.dart';

/// Pousse les relevés vers les widgets d'écran d'accueil natifs.
///
/// Volontairement séparé de [WidgetDataService] : ces appels passent par un
/// canal de plateforme, et le décodage des métriques doit rester testable
/// sans binding Flutter.
///
/// L'app gère plusieurs box, et chaque widget posé est lié à l'une d'elles par
/// son activité de configuration. On publie donc un relevé **par box**, sous
/// des clés préfixées par son nom, plus la liste des box disponibles.
class HomeWidgetBridge {
  HomeWidgetBridge._();

  /// Classes Kotlin des providers, résolues par le plugin dans le package de
  /// l'app. Chaque thème a la sienne pour apparaître séparément dans le
  /// sélecteur de widgets ; toutes lisent le même stockage.
  static const _androidProviders = [
    'ConsoWidgetProvider',
    'ProductionWidgetProvider',
    'BalanceWidgetProvider',
  ];

  /// Liste des box proposées par l'activité de configuration, en JSON.
  static const keyDeviceList = 'widget_device_list';

  // Suffixes des clés par box. Le natif reconstruit « <nom>.<suffixe> ».
  // Tout est stocké en chaîne, y compris l'horodatage : un entier Dart
  // traverse le canal en Int32 ou Int64 selon sa valeur, et le natif devrait
  // alors deviner entre getInt et getLong.
  static const suffixPower = '.power';
  static const suffixIndex = '.index';
  static const suffixTimestamp = '.ts';
  static const suffixSource = '.source';

  /// Puissance souscrite, échelle de la jauge. Vide si le compteur ne la
  /// publie pas : le natif dessine alors la jauge sans repère.
  static const suffixMaxPower = '.maxpower';

  /// Série horaire pour le graphe, en `heure:conso:production` séparés par des
  /// virgules (`18:1741:0,19:4052:1433,…`). Les deux grandeurs voyagent
  /// ensemble : le solde s'en déduit côté natif, sans seconde clé à tenir
  /// synchronisée.
  static const suffixHourly = '.hourly';

  /// Total des 24 heures, en Wh.
  static const suffixDaily = '.daily';

  /// Coût des 24 heures, en euros. Vide si aucun tarif n'est paramétré.
  static const suffixCost = '.cost';

  // Grandeurs de production et de bilan. Vides hors installation productrice,
  // ce qui permet au natif de savoir qu'un thème n'a rien à montrer.
  static const suffixProductionPower = '.prodpower';
  static const suffixProduction = '.production';
  static const suffixRevenue = '.revenue';
  static const suffixNet = '.net';
  static const suffixNetCost = '.netcost';

  /// Évolution entre les deux dernières heures complètes, en pourcentage
  /// signé. Vide si l'historique est trop court pour conclure.
  static const suffixTrend = '.trend';

  /// Publie les box disponibles, même si aucun relevé n'a encore abouti :
  /// l'utilisateur peut poser un widget avant le premier rafraîchissement.
  static Future<void> publishDeviceList(List<String> names) async {
    await HomeWidget.saveWidgetData<String>(keyDeviceList, jsonEncode(names));
  }

  /// Horodatage de la dernière tentative infructueuse. Comparé à celui du
  /// relevé, il dit si la box a cessé de répondre depuis.
  static const suffixFailedAt = '.failedat';

  /// Note une box injoignable, puis redessine.
  ///
  /// Sans cette marque, le widget garderait ses chiffres avec le même aplomb
  /// qu'un relevé abouti — et l'accusé de réception de l'appui resterait figé.
  static Future<void> pushFailure(String deviceName) async {
    await HomeWidget.saveWidgetData<String>(
      '$deviceName$suffixFailedAt',
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    await notifyWidgets();
  }

  /// Écrit un relevé puis demande le redessin de tous les widgets posés.
  ///
  /// Appelé box par box plutôt qu'en fin de balayage : le système tue
  /// volontiers le processus d'arrière-plan au bout de quelques secondes, et
  /// ce qui n'a pas encore été écrit à cet instant est perdu.
  ///
  /// Sans effet si aucun widget n'est présent sur l'écran d'accueil.
  static Future<void> push(LinkySnapshot snapshot) async {
    final prefix = snapshot.deviceName;
    // Le relevé a abouti : on efface la marque d'échec précédente.
    await HomeWidget.saveWidgetData<String>('$prefix$suffixFailedAt', '');
    await Future.wait([
      HomeWidget.saveWidgetData<String>(
        '$prefix$suffixPower',
        snapshot.apparentPowerVA?.toString() ?? '',
      ),
      // Nombre brut, séparateur décimal invariant : c'est le natif qui
      // formate selon la locale de l'appareil.
      HomeWidget.saveWidgetData<String>(
        '$prefix$suffixIndex',
        snapshot.indexKWh?.toStringAsFixed(1) ?? '',
      ),
      HomeWidget.saveWidgetData<String>(
        '$prefix$suffixMaxPower',
        snapshot.subscribedPowerVA?.toString() ?? '',
      ),
      HomeWidget.saveWidgetData<String>(
        '$prefix$suffixProductionPower',
        snapshot.productionPowerVA?.toString() ?? '',
      ),
      HomeWidget.saveWidgetData<String>(
        '$prefix$suffixTimestamp',
        snapshot.timestamp.millisecondsSinceEpoch.toString(),
      ),
      HomeWidget.saveWidgetData<String>(
        '$prefix$suffixSource',
        snapshot.source.name,
      ),
    ]);

    // L'export horaire est throttlé : une série vide veut dire « pas de
    // nouvelle donnée », pas « consommation nulle ». L'écrire quand même
    // effacerait le graphe jusqu'au prochain export abouti.
    if (snapshot.hourly.isNotEmpty) {
      await Future.wait([
        HomeWidget.saveWidgetData<String>(
          '$prefix$suffixHourly',
          snapshot.hourly
              .map((s) => '${s.hour}:${s.wh}:${s.productionWh}')
              .join(','),
        ),
        HomeWidget.saveWidgetData<String>(
          '$prefix$suffixDaily',
          snapshot.dailyTotalWh?.toString() ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          '$prefix$suffixCost',
          snapshot.dailyCostEur?.toStringAsFixed(2) ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          '$prefix$suffixProduction',
          snapshot.dailyProductionWh?.toString() ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          '$prefix$suffixRevenue',
          snapshot.dailyRevenueEur?.toStringAsFixed(2) ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          '$prefix$suffixNet',
          snapshot.dailyNetWh?.toString() ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          '$prefix$suffixNetCost',
          snapshot.dailyNetCostEur?.toStringAsFixed(2) ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          '$prefix$suffixTrend',
          snapshot.hourlyTrendPct?.toStringAsFixed(0) ?? '',
        ),
      ]);
    }

    await notifyWidgets();
  }

  /// Redemande le rendu de tous les widgets posés, quel que soit leur thème.
  static Future<void> notifyWidgets() async {
    for (final provider in _androidProviders) {
      await HomeWidget.updateWidget(androidName: provider);
    }
  }

  // --- Widgets par appareil Zigbee -----------------------------------------

  static const _deviceProvider = 'DeviceWidgetProvider';

  /// Catalogue proposé par l'écran de configuration : un objet par appareil,
  /// toutes box confondues.
  static const keyDeviceCatalog = 'widget_device_catalog';

  /// État d'un appareil, en JSON.
  ///
  /// Contrairement aux relevés Linky, dont chaque grandeur a sa clé, un
  /// appareil n'a pas de forme connue d'avance : le gabarit de la box dicte
  /// combien de valeurs et combien de boutons. Un objet structuré évite
  /// d'inventer un encodage maison pour une liste de longueur variable.
  static const suffixDevice = '.device';

  /// Publie le catalogue des appareils, pour l'écran de configuration.
  ///
  /// [refreshedBoxes] nomme les box effectivement relevées. Celles qui n'ont
  /// pas répondu gardent leurs appareils de la fois précédente : les effacer
  /// ferait disparaître un volet de la liste parce que le Wi-Fi a hoqueté, et
  /// interdirait de reposer son widget jusqu'au retour de la box.
  static Future<void> publishDeviceCatalog(
    List<DeviceSnapshot> devices,
    Set<String> refreshedBoxes,
  ) async {
    final entries = <String, Map<String, String>>{};

    final previous = await HomeWidget.getWidgetData<String>(keyDeviceCatalog);
    if (previous != null && previous.isNotEmpty) {
      try {
        for (final raw in jsonDecode(previous) as List) {
          final entry = Map<String, String>.from(
            (raw as Map).map((k, v) => MapEntry('$k', '$v')),
          );
          final key = entry['key'];
          if (key != null && !refreshedBoxes.contains(entry['box'])) {
            entries[key] = entry;
          }
        }
      } catch (e) {
        print('[DEVICES] Catalogue précédent illisible: $e');
      }
    }

    for (final d in devices) {
      entries[d.key] = {
        'key': d.key,
        'box': d.boxName,
        'label': d.label,
        'model': d.model,
      };
    }

    await HomeWidget.saveWidgetData<String>(
      keyDeviceCatalog,
      jsonEncode(entries.values.toList()),
    );
  }

  /// Écrit l'état d'un appareil et redessine les widgets qui le montrent.
  static Future<void> pushDevice(DeviceSnapshot device) async {
    final prefix = device.key;
    await HomeWidget.saveWidgetData<String>('$prefix$suffixFailedAt', '');
    await HomeWidget.saveWidgetData<String>(
      '$prefix$suffixDevice',
      jsonEncode({
        'label': device.label,
        'model': device.model,
        'short': device.shortAddr,
        'endpoint': device.endpoint,
        'readings': [
          for (final r in device.readings)
            {
              'name': r.name,
              if (r.value != null) 'value': r.value,
              if (r.unit != null) 'unit': r.unit,
              if (r.min != null) 'min': r.min,
              if (r.max != null) 'max': r.max,
              if (r.gaugeKind != null) 'gauge': r.gaugeKind,
            },
        ],
        // Les paramètres voyagent avec le bouton, et pas seulement son nom :
        // le natif les renvoie tels quels à l'appui, ce qui évite de relire
        // tout l'inventaire de la box avant d'émettre la commande.
        'actions': [
          for (final a in device.actions)
            {
              'name': a.name,
              'command': a.command,
              'endpoint': a.endpoint,
              'value': a.value,
              if (a.cluster != null) 'cluster': a.cluster,
              if (a.manufacturerCode != null) 'mfr': a.manufacturerCode,
            },
        ],
      }),
    );
    await HomeWidget.saveWidgetData<String>(
      '$prefix$suffixTimestamp',
      device.timestamp.millisecondsSinceEpoch.toString(),
    );
    await notifyDeviceWidgets();
  }

  /// Note un appareil qu'on n'a pas su joindre, puis redessine.
  static Future<void> pushDeviceFailure(String deviceKey) async {
    await HomeWidget.saveWidgetData<String>(
      '$deviceKey$suffixFailedAt',
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    await notifyDeviceWidgets();
  }

  static Future<void> notifyDeviceWidgets() =>
      HomeWidget.updateWidget(androidName: _deviceProvider);

  // --- Widgets de groupe d'actions -----------------------------------------

  static const _groupProvider = 'ActionGroupWidgetProvider';

  /// Catalogue proposé par l'écran de configuration.
  static const keyGroupCatalog = 'widget_group_catalog';

  /// Description d'un groupe, en JSON.
  static const suffixGroup = '.group';

  /// Nombre d'actions émises au dernier déclenchement, ou vide.
  static const suffixSent = '.sent';

  static Future<void> publishGroupCatalog(
    List<ActionGroup> groups,
    Set<String> refreshedBoxes,
  ) async {
    final entries = <String, Map<String, String>>{};

    // Même prudence que pour les appareils : une box muette garde ses groupes,
    // sinon un widget devient impossible à reposer le temps qu'elle revienne.
    final previous = await HomeWidget.getWidgetData<String>(keyGroupCatalog);
    if (previous != null && previous.isNotEmpty) {
      try {
        for (final raw in jsonDecode(previous) as List) {
          final entry = Map<String, String>.from(
            (raw as Map).map((k, v) => MapEntry('$k', '$v')),
          );
          final key = entry['key'];
          if (key != null && !refreshedBoxes.contains(entry['box'])) {
            entries[key] = entry;
          }
        }
      } catch (e) {
        print('[GROUPES] Catalogue précédent illisible: $e');
      }
    }

    for (final g in groups) {
      entries[g.key] = {
        'key': g.key,
        'box': g.boxName,
        'name': g.name,
        'icon': g.icon,
        'count': g.actionCount.toString(),
      };
    }

    await HomeWidget.saveWidgetData<String>(
      keyGroupCatalog,
      jsonEncode(entries.values.toList()),
    );
  }

  /// Écrit la description d'un groupe et redessine.
  static Future<void> pushGroup(ActionGroup group) async {
    await HomeWidget.saveWidgetData<String>('${group.key}$suffixFailedAt', '');
    await HomeWidget.saveWidgetData<String>(
      '${group.key}$suffixGroup',
      jsonEncode({
        'name': group.name,
        'icon': group.icon,
        'color': group.color,
        'count': group.actionCount,
        'enabled': group.enabled,
      }),
    );
    await notifyGroupWidgets();
  }

  /// Note le résultat d'un déclenchement : combien d'actions sont parties.
  static Future<void> pushGroupResult(String groupKey, int sent) async {
    await HomeWidget.saveWidgetData<String>('$groupKey$suffixFailedAt', '');
    await HomeWidget.saveWidgetData<String>(
      '$groupKey$suffixSent',
      sent.toString(),
    );
    await HomeWidget.saveWidgetData<String>(
      '$groupKey$suffixTimestamp',
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    await notifyGroupWidgets();
  }

  static Future<void> pushGroupFailure(String groupKey) async {
    await HomeWidget.saveWidgetData<String>(
      '$groupKey$suffixFailedAt',
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    await notifyGroupWidgets();
  }

  static Future<void> notifyGroupWidgets() =>
      HomeWidget.updateWidget(androidName: _groupProvider);
}

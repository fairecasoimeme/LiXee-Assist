import 'dart:convert';

import 'package:home_widget/home_widget.dart';

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

  /// Nom de la classe Kotlin, résolu par le plugin dans le package de l'app.
  static const _androidProvider = 'ConsoWidgetProvider';

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

  /// Série horaire pour le graphe, en `heure:wh` séparés par des virgules
  /// (`18:1741,19:4052,…`). Un format compact suffit et évite d'imposer un
  /// parseur JSON au natif.
  static const suffixHourly = '.hourly';

  /// Total des 24 heures, en Wh.
  static const suffixDaily = '.daily';

  /// Coût des 24 heures, en euros. Vide si aucun tarif n'est paramétré.
  static const suffixCost = '.cost';

  /// Évolution entre les deux dernières heures complètes, en pourcentage
  /// signé. Vide si l'historique est trop court pour conclure.
  static const suffixTrend = '.trend';

  /// Publie les box disponibles, même si aucun relevé n'a encore abouti :
  /// l'utilisateur peut poser un widget avant le premier rafraîchissement.
  static Future<void> publishDeviceList(List<String> names) async {
    await HomeWidget.saveWidgetData<String>(keyDeviceList, jsonEncode(names));
  }

  /// Écrit les relevés puis demande le redessin de tous les widgets posés.
  ///
  /// Sans effet si aucun widget n'est présent sur l'écran d'accueil.
  static Future<void> push(List<LinkySnapshot> snapshots) async {
    for (final snapshot in snapshots) {
      final prefix = snapshot.deviceName;
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
            snapshot.hourly.map((s) => '${s.hour}:${s.wh}').join(','),
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
            '$prefix$suffixTrend',
            snapshot.hourlyTrendPct?.toStringAsFixed(0) ?? '',
          ),
        ]);
      }
    }

    await HomeWidget.updateWidget(androidName: _androidProvider);
  }
}

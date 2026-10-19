import 'package:shared_preferences/shared_preferences.dart';

import '../screens/home_screen.dart' show resolveMdnsIP;
import '../services/box_client.dart';
import '../services/home_widget_bridge.dart';
import '../services/widget_data_service.dart';

/// Comment la box a répondu au dernier relevé.
enum TvReach { unknown, local, remote, offline }

/// Une box telle que l'écran d'accueil TV l'affiche.
class TvBox {
  final String entry;
  final BoxDevice device;
  final LinkySnapshot? snapshot;
  final TvReach reach;

  const TvBox({
    required this.entry,
    required this.device,
    this.snapshot,
    this.reach = TvReach.unknown,
  });

  String get name => device.name;

  TvBox copyWith({LinkySnapshot? snapshot, TvReach? reach}) => TvBox(
    entry: entry,
    device: device,
    snapshot: snapshot ?? this.snapshot,
    reach: reach ?? this.reach,
  );
}

/// Accès aux box pour la version TV, au-dessus des services des widgets.
class TvData {
  TvData._();

  static const _prefsKey = 'saved_devices';

  /// Les box enregistrées, avec leur dernier relevé connu (sans réseau).
  static Future<List<TvBox>> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final boxes = <TvBox>[];
    for (final entry in prefs.getStringList(_prefsKey) ?? const <String>[]) {
      final device = BoxDevice.tryParse(entry);
      if (device == null) continue;
      boxes.add(
        TvBox(
          entry: entry,
          device: device,
          snapshot: await WidgetDataService.readSnapshot(device.name),
        ),
      );
    }
    return boxes;
  }

  /// Relève une box : Linky si elle en a un, sinon simple test de présence.
  ///
  /// Le relevé est aussi publié pour l'écran de veille, qui lit les mêmes
  /// données que les widgets.
  static Future<TvBox> refresh(TvBox box) async {
    var snapshot = await WidgetDataService.fetchForDevice(
      box.entry,
      mdnsResolver: resolveMdnsIP,
    );
    // L'historique horaire n'est retéléchargé que toutes les dix minutes :
    // entre-temps le relevé arrive sans lui, et le garder tel quel viderait
    // le graphe et les totaux sur 24 h.
    final previous =
        box.snapshot ?? await WidgetDataService.readSnapshot(box.name);
    if (snapshot != null &&
        snapshot.hourly.isEmpty &&
        (previous?.hourly.isNotEmpty ?? false)) {
      snapshot = snapshot.withHourly(previous!.hourly);
    }
    if (snapshot != null) {
      await WidgetDataService.saveSnapshot(snapshot);
      await HomeWidgetBridge.push(snapshot);
      return box.copyWith(
        snapshot: snapshot,
        reach:
            snapshot.source == LinkySource.local
                ? TvReach.local
                : TvReach.remote,
      );
    }

    // Pas de Linky ne veut pas dire hors ligne : une box peut n'en avoir
    // aucun et piloter des volets.
    final route = await reachableRoute(box.device);
    if (route == null) return box.copyWith(reach: TvReach.offline);
    return box.copyWith(
      reach:
          route.$2.source == LinkySource.local ? TvReach.local : TvReach.remote,
    );
  }

  /// Première voie qui répond, avec l'URL candidate d'origine.
  static Future<(String, BoxRoute)?> reachableRoute(BoxDevice device) async {
    await for (final (candidate, route) in BoxClient.routes(
      device,
      mdnsResolver: resolveMdnsIP,
    )) {
      try {
        final body = await BoxClient.get(route, '/poll', allowEmpty: true);
        if (body != null) {
          BoxClient.remember(device, candidate);
          return (candidate, route);
        }
      } catch (_) {
        // Voie suivante.
      }
    }
    return null;
  }

  /// Retire une box de la liste.
  static Future<void> remove(TvBox box) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = List<String>.from(
      prefs.getStringList(_prefsKey) ?? const [],
    );
    entries.remove(box.entry);
    await prefs.setStringList(_prefsKey, entries);
  }

  /// Renomme une box en gardant ses adresses et identifiants.
  static Future<void> rename(TvBox box, String newName) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = List<String>.from(
      prefs.getStringList(_prefsKey) ?? const [],
    );
    final index = entries.indexOf(box.entry);
    if (index < 0) return;
    final parts = box.entry.split('|');
    parts[0] = newName.replaceAll('|', ' ').trim();
    entries[index] = parts.join('|');
    await prefs.setStringList(_prefsKey, entries);
  }

  /// Ajoute une box, ou remplace celle qui porte déjà ce nom.
  static Future<void> upsert(String entry) async {
    final device = BoxDevice.tryParse(entry);
    if (device == null) return;
    final prefs = await SharedPreferences.getInstance();
    final entries = List<String>.from(
      prefs.getStringList(_prefsKey) ?? const [],
    );
    entries.removeWhere((e) => BoxDevice.tryParse(e)?.name == device.name);
    entries.add(entry);
    await prefs.setStringList(_prefsKey, entries);
  }
}

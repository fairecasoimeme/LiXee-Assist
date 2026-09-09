import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'box_client.dart';

/// Un groupe d'actions configuré sur la box, tel qu'il se déclenche.
///
/// La box les tient dans `config → Groupes d'actions` : une liste d'actions
/// sur plusieurs appareils, sous un nom, une icône et une couleur. C'est
/// exactement ce qu'un widget peut offrir de plus simple — un bouton.
class ActionGroup {
  final String boxName;

  /// Rang dans la liste de la box. C'est le seul identifiant qu'elle expose,
  /// et il change si un groupe antérieur est supprimé — d'où la vérification
  /// du nom avant de déclencher.
  final int index;

  final String name;

  /// Émoji choisi sur la box. Vide si l'utilisateur n'en a pas mis.
  final String icon;

  /// Couleur `#rrggbb` choisie sur la box.
  final String color;

  final bool enabled;

  /// Nombre d'actions que le groupe enverra.
  final int actionCount;

  const ActionGroup({
    required this.boxName,
    required this.index,
    required this.name,
    this.icon = '',
    this.color = '',
    this.enabled = true,
    this.actionCount = 0,
  });

  /// Identifiant stable à travers les box.
  ///
  /// Bâti sur le **nom** et non sur le rang : supprimer un groupe décale tous
  /// les suivants, et un widget resterait pointé sur un rang devenu celui d'un
  /// autre groupe — au risque de fermer les volets en croyant les ouvrir.
  String get key => '$boxName#$name';

  @override
  String toString() => 'ActionGroup($boxName/$index, $name, $actionCount action(s))';
}

/// Résultat d'un déclenchement, tel que la box le rapporte.
class ActionGroupResult {
  final bool ok;

  /// Nombre d'actions effectivement émises.
  final int sent;

  final String? error;

  const ActionGroupResult({required this.ok, this.sent = 0, this.error});
}

/// Liste et déclenche les groupes d'actions d'une box.
class ActionGroupService {
  ActionGroupService._();

  /// Énumère les groupes d'une box. Liste vide si elle ne répond pas — ou si
  /// son firmware ignore les groupes d'actions.
  static Future<List<ActionGroup>> fetchAll(
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
        final body = await BoxClient.get(route, '/api/actiongroups/list');
        if (body == null) {
          BoxClient.dropSession(route);
          continue;
        }
        BoxClient.remember(box, candidate);
        return parseGroups(box.name, body);
      } catch (e) {
        print('[GROUPES] ${route.baseUrl} échec: $e');
        BoxClient.dropSession(route);
      }
    }
    return const [];
  }

  /// Déclenche un groupe, désigné par son nom.
  ///
  /// Le rang est relu juste avant d'émettre : c'est le seul identifiant que la
  /// box accepte, mais il se décale dès qu'un groupe antérieur est supprimé.
  /// Se fier au rang mémorisé par le widget reviendrait à déclencher le voisin
  /// — fermer les volets là où l'on voulait les ouvrir.
  static Future<ActionGroupResult> run(
    BoxDevice box,
    String groupName, {
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
        final listing = await BoxClient.get(route, '/api/actiongroups/list');
        if (listing == null) {
          BoxClient.dropSession(route);
          continue;
        }
        final group = parseGroups(box.name, listing)
            .where((g) => g.name == groupName)
            .firstOrNull;
        if (group == null) {
          return ActionGroupResult(ok: false, error: 'groupe introuvable');
        }

        final body = await BoxClient.post(
          route,
          '/api/actiongroups/run',
          {'index': group.index.toString()},
        );
        if (body == null) {
          BoxClient.dropSession(route);
          continue;
        }
        BoxClient.remember(box, candidate);
        return parseResult(body);
      } catch (e) {
        print('[GROUPES] Déclenchement échoué: $e');
        BoxClient.dropSession(route);
      }
    }
    return const ActionGroupResult(ok: false, error: 'box injoignable');
  }

  @visibleForTesting
  static List<ActionGroup> parseGroups(String boxName, String json) {
    try {
      final decoded = jsonDecode(json);
      final groups = decoded is Map ? decoded['groups'] : null;
      if (groups is! List) return const [];

      return [
        for (final raw in groups)
          if (raw is Map)
            ActionGroup(
              boxName: boxName,
              index: (raw['index'] as num?)?.toInt() ?? 0,
              name: raw['name']?.toString() ?? '',
              icon: raw['icon']?.toString() ?? '',
              color: raw['color']?.toString() ?? '',
              enabled: raw['enabled'] != false,
              actionCount: (raw['actions'] as List?)?.length ?? 0,
            ),
      ].where((g) => g.name.isNotEmpty).toList(growable: false);
    } catch (e) {
      print('[GROUPES] Liste illisible: $e');
      return const [];
    }
  }

  @visibleForTesting
  static ActionGroupResult parseResult(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return const ActionGroupResult(ok: false);
      return ActionGroupResult(
        ok: decoded['ok'] == true,
        sent: (decoded['sent'] as num?)?.toInt() ?? 0,
        error: decoded['error']?.toString(),
      );
    } catch (e) {
      return ActionGroupResult(ok: false, error: 'réponse illisible');
    }
  }
}

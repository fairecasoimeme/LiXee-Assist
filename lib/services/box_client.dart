import 'dart:convert';
import 'dart:io';

import 'network_scope.dart';
import 'session_manager.dart' show AuthMode;
import 'session_pool.dart';

/// Voie par laquelle un relevé a été obtenu.
enum LinkySource { local, remote }

/// Entrée `saved_devices` décodée.
///
/// Formats supportés : `name|url`, `name|url|fallback`,
/// `name|url|auth|login|pass`, `name|url|auth|login|pass|fallback`.
class BoxDevice {
  final String name;
  final String primaryUrl;
  final String? fallbackUrl;
  final String? login;
  final String? password;

  const BoxDevice({
    required this.name,
    required this.primaryUrl,
    this.fallbackUrl,
    this.login,
    this.password,
  });

  bool get hasAuth => login != null && password != null;

  String get key => '$name|$primaryUrl';

  static BoxDevice? tryParse(String entry) {
    final parts = entry.split('|');
    if (parts.length < 2) return null;

    final hasAuth = parts.length >= 5 && parts[2] == 'auth';

    if (hasAuth && (parts.length == 5 || parts.length == 6)) {
      return BoxDevice(
        name: parts[0],
        primaryUrl: parts[1],
        login: parts[3],
        password: parts[4],
        fallbackUrl: parts.length == 6 ? parts[5] : null,
      );
    }
    if (parts.length == 2) {
      return BoxDevice(name: parts[0], primaryUrl: parts[1]);
    }
    if (parts.length == 3 && parts[2] != 'auth') {
      return BoxDevice(
        name: parts[0],
        primaryUrl: parts[1],
        fallbackUrl: parts[2],
      );
    }
    return null;
  }
}

/// Une base URL joignable pour une box, avec le mode d'accès qui va avec.
class BoxRoute {
  final String baseUrl;
  final BoxDevice device;
  final LinkySource source;
  final Duration timeout;

  const BoxRoute({
    required this.baseUrl,
    required this.device,
    required this.source,
    required this.timeout,
  });
}

/// Transport HTTP vers une LiXee-Box, indifférent à ce qu'on lui demande.
///
/// Rassemble ce qui a demandé le plus de mise au point : la cascade
/// primaire/repli, la résolution mDNS, le choix entre authentification Basic
/// (acceptée en LAN) et formulaire (imposée par le tunnel), et la mémoire de
/// la dernière URL qui a répondu.
///
/// Extrait de [WidgetDataService] pour servir aussi le pilotage des appareils :
/// dupliquer cette logique aurait été le plus sûr moyen de voir les deux
/// copies diverger sur le seul point qui compte, l'authentification.
class BoxClient {
  BoxClient._();

  /// Une requête LAN qui n'a pas répondu en 3 s ne répondra pas : on bascule.
  static const defaultLocalTimeout = Duration(seconds: 3);

  /// Le tunnel relaie par WebSocket et impose un login formulaire : il lui faut
  /// nettement plus de marge qu'un accès direct.
  static const defaultRemoteTimeout = Duration(seconds: 10);

  /// Dernière URL ayant répondu, par box. Évite de retenter systématiquement
  /// l'IP locale en timeout quand on n'est pas sur le réseau de la box.
  static final Map<String, String> _lastGoodUrl = {};

  /// Ferme les sessions ouvertes.
  ///
  /// À n'appeler que depuis un isolate qui se termine : au premier plan, ces
  /// sessions sont partagées avec l'écran d'accueil.
  static void disposeAll() => SessionPool.closeAll();

  /// Note l'URL qui vient d'aboutir, pour la tenter en premier la prochaine
  /// fois.
  static void remember(BoxDevice device, String candidate) {
    _lastGoodUrl[device.key] = candidate;
  }

  /// Les voies à tenter pour joindre [device], la meilleure d'abord.
  ///
  /// Rend un couple (candidat brut, route résolue) : le premier sert à
  /// mémoriser le choix, la seconde à émettre les requêtes.
  static Stream<(String, BoxRoute)> routes(
    BoxDevice device, {
    Future<String?> Function(String deviceName)? mdnsResolver,
    Duration localTimeout = defaultLocalTimeout,
    Duration remoteTimeout = defaultRemoteTimeout,
  }) async* {
    for (final candidate in _orderedCandidates(device)) {
      final baseUrl = await _resolve(candidate, device.name, mdnsResolver);
      if (baseUrl == null) continue;

      final source = classify(baseUrl);
      yield (
        candidate,
        BoxRoute(
          baseUrl: baseUrl,
          device: device,
          source: source,
          timeout: source == LinkySource.local ? localTimeout : remoteTimeout,
        ),
      );
    }
  }

  /// GET authentifié sur la box, quel que soit le mode d'auth.
  ///
  /// [path] commence par `/`. Retourne `null` si la requête n'aboutit pas.
  static Future<String?> get(BoxRoute route, String path) async {
    final device = route.device;
    if (!device.hasAuth) {
      return rawGet('${route.baseUrl}$path', route.timeout);
    }

    final basic =
        'Basic ${base64Encode(utf8.encode('${device.login}:${device.password}'))}';

    // En LAN la box accepte le Basic : une requête unique, sans état ni cookie
    // à entretenir. C'est le tunnel qui impose le formulaire, pas le firmware.
    var basicTried = false;
    if (route.source == LinkySource.local) {
      basicTried = true;
      final body = await rawGet(
        '${route.baseUrl}$path',
        route.timeout,
        authHeader: basic,
      );
      if (body != null) return body;
      print('[BOX] Basic refusé sur ${route.baseUrl}, bascule sur le formulaire');
    }

    final mode = await SessionPool.authMode(route.baseUrl, timeout: route.timeout);
    if (mode == AuthMode.form) {
      final session =
          SessionPool.session(route.baseUrl, device.login!, device.password!);
      final result = await session.authenticatedGet(path).timeout(route.timeout);
      if (result.statusCode == 200 && result.body.isNotEmpty) {
        return result.body;
      }
      print('[BOX] Formulaire KO (${result.statusCode}) sur ${route.baseUrl}$path');
    }

    // Inutile de rejouer le Basic si la voie LAN l'a déjà refusé.
    return basicTried
        ? null
        : rawGet('${route.baseUrl}$path', route.timeout, authHeader: basic);
  }

  /// POST authentifié, en formulaire. Retourne `null` si rien n'aboutit.
  ///
  /// Le corps est identique quel que soit le mode d'authentification : seule
  /// la façon de prouver son identité change.
  static Future<String?> post(
    BoxRoute route,
    String path,
    Map<String, String> fields,
  ) async {
    final device = route.device;
    if (device.hasAuth && route.source != LinkySource.local) {
      // Le tunnel impose le formulaire : passer par la session évite un aller
      // simple en Basic qui serait refusé.
      final mode =
          await SessionPool.authMode(route.baseUrl, timeout: route.timeout);
      if (mode == AuthMode.form) {
        final session =
            SessionPool.session(route.baseUrl, device.login!, device.password!);
        final result =
            await session.authenticatedPost(path, fields).timeout(route.timeout);
        return result.statusCode == 200 ? result.body : null;
      }
    }

    final basic = device.hasAuth
        ? 'Basic ${base64Encode(utf8.encode('${device.login}:${device.password}'))}'
        : null;
    final body = await _rawPost(
      '${route.baseUrl}$path',
      fields,
      route.timeout,
      authHeader: basic,
    );
    if (body != null || !device.hasAuth) return body;

    // Le Basic a été refusé : la box attend le formulaire, même en LAN.
    final session =
        SessionPool.session(route.baseUrl, device.login!, device.password!);
    final result =
        await session.authenticatedPost(path, fields).timeout(route.timeout);
    return result.statusCode == 200 ? result.body : null;
  }

  static Future<String?> _rawPost(
    String url,
    Map<String, String> fields,
    Duration timeout, {
    String? authHeader,
  }) async {
    final client = HttpClient()
      ..badCertificateCallback = ((cert, host, port) => true)
      ..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(Uri.parse(url));
      request.headers.set('Content-Type', 'application/x-www-form-urlencoded');
      request.headers.set('Accept', 'application/json');
      if (authHeader != null) request.headers.set('Authorization', authHeader);
      request.followRedirects = false;
      request.add(utf8.encode(fields.entries
          .map((e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
          .join('&')));
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();
      return response.statusCode == 200 && body.isNotEmpty ? body : null;
    } finally {
      client.close(force: true);
    }
  }

  /// Oublie la session d'une box dont une requête vient d'échouer.
  static void dropSession(BoxRoute route) {
    final login = route.device.login;
    if (login != null) SessionPool.invalidate(route.baseUrl, login);
  }

  static Future<String?> rawGet(
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
  static LinkySource classify(String baseUrl) =>
      isLanUrl(baseUrl) ? LinkySource.local : LinkySource.remote;

  // --- Interne -------------------------------------------------------------

  /// URLs à tenter, la dernière qui a fonctionné en premier.
  static List<String> _orderedCandidates(BoxDevice device) {
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
}

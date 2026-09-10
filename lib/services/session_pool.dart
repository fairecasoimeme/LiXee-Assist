import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_manager.dart';

/// Registre partagé des sessions authentifiées, par box.
///
/// Le cookie de session est lié à l'hôte et vit 24 h. Sans registre commun,
/// chaque appelant — écran d'accueil, relevé des métriques — ouvre sa propre
/// session sur la même box et refait un `POST /login` de son côté. La box
/// répond alors `/login?error=1` sur les tentatives concurrentes, et les
/// cookies obtenus sont jetés aussitôt.
class SessionPool {
  SessionPool._();

  static final Map<String, SessionManager> _sessions = {};

  /// Mémorise le `Future` et pas seulement son résultat : deux appels
  /// concurrents partagent la même détection au lieu d'émettre deux requêtes.
  static final Map<String, Future<AuthMode>> _authModes = {};

  /// Le cookie de session tient lieu de mot de passe pendant 24 h : il va au
  /// trousseau du système, que le Keychain sur iOS et le KeyStore sur Android
  /// chiffrent avec une clé matérielle. Les préférences partagées, elles, sont
  /// un fichier en clair, lisible dès qu'une sauvegarde ou un appareil rooté
  /// donne accès au répertoire de l'app.
  ///
  /// `first_unlock_this_device` : lisible en tâche de fond dès le premier
  /// déverrouillage depuis le démarrage — le widget se rafraîchit sans que
  /// l'écran soit allumé — mais jamais recopié vers un autre appareil, un
  /// cookie n'étant de toute façon valable que là où il a été obtenu.
  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// Champs de formulaire et modes d'authentification retenus d'un passage
  /// précédent de l'app, lus au démarrage.
  ///
  /// Un isolate d'arrière-plan naît sans rien : sans ce report, chaque appui
  /// sur un widget refaisait détection du mode, détection des champs du
  /// formulaire et POST /login — trois allers-retours avant la première
  /// requête utile, soit deux secondes de plus sur un tunnel.
  static Map<String, String> _persisted = const {};

  /// Cookies relus du trousseau, indexés comme [_persisted].
  ///
  /// Tenus en mémoire parce que [session] est synchrone, alors que la lecture
  /// du trousseau ne l'est pas.
  static final Map<String, String> _cookies = {};

  /// Mémorise le chargement lui-même : deux isolates qui démarrent ensemble
  /// partagent la même lecture au lieu d'en lancer deux.
  static Future<void>? _loading;

  static const _cookiePrefix = 'session_cookie_';
  static const _fieldsPrefix = 'session_fields_';
  static const _modePrefix = 'session_mode_';

  /// Recharge les sessions conservées. Sans effet si déjà fait.
  ///
  /// À appeler au début d'un point d'entrée d'arrière-plan, avant la première
  /// requête : après, il serait trop tard pour éviter le login.
  static Future<void> loadPersisted() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      _persisted = {
        for (final key in prefs.getKeys())
          if (key.startsWith(_fieldsPrefix) || key.startsWith(_modePrefix))
            key: prefs.getString(key) ?? '',
      };

      // Le mode d'authentification est une propriété de l'endpoint : le
      // reprendre tel quel évite un GET / dont la réponse ne change jamais.
      for (final entry in _persisted.entries) {
        if (!entry.key.startsWith(_modePrefix)) continue;
        final baseUrl = entry.key.substring(_modePrefix.length);
        final mode = AuthMode.values
            .where((m) => m.name == entry.value)
            .firstOrNull;
        if (mode != null) _authModes[baseUrl] = Future.value(mode);
      }

      await _purgeLegacyCookies(prefs);
    } catch (e) {
      print('[SESSION] Sessions conservées illisibles: $e');
    }

    try {
      final stored = await _secure.readAll();
      _cookies
        ..clear()
        ..addEntries(
          stored.entries.where((e) => e.key.startsWith(_cookiePrefix)),
        );
    } catch (e) {
      print('[SESSION] Trousseau illisible: $e');
    }
  }

  /// Efface les cookies que les versions précédentes laissaient en clair.
  ///
  /// Les recopier vers le trousseau serait du travail perdu — un cookie vit
  /// 24 h et le prochain login en fournit un neuf — alors que les laisser
  /// garderait sur disque exactement ce que ce stockage cherche à en retirer.
  static Future<void> _purgeLegacyCookies(SharedPreferences prefs) async {
    final stale =
        prefs.getKeys().where((k) => k.startsWith(_cookiePrefix)).toList();
    for (final key in stale) {
      await prefs.remove(key);
    }
    if (stale.isNotEmpty) {
      print('[SESSION] ${stale.length} cookie(s) en clair effacé(s)');
    }
  }

  static Future<void> _remember(SessionManager session) async {
    final key = _key(session.targetBaseUrl, session.username);
    final cookie = session.sessionCookie;

    if (cookie != null && cookie.isNotEmpty) {
      try {
        await _secure.write(key: '$_cookiePrefix$key', value: cookie);
        _cookies['$_cookiePrefix$key'] = cookie;
      } catch (e) {
        print('[SESSION] Cookie non conservé: $e');
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_fieldsPrefix$key',
        '${session.userField ?? ''}|${session.passField ?? ''}',
      );
      await prefs.setString('$_modePrefix${session.targetBaseUrl}',
          AuthMode.form.name);
    } catch (e) {
      print('[SESSION] Session non conservée: $e');
    }
  }

  /// La clé inclut l'hôte : un cookie obtenu via le tunnel n'est pas valable
  /// sur l'IP locale, les deux voies ont donc leur session propre.
  static String _key(String baseUrl, String username) => '$baseUrl|$username';

  /// Session pour cette box, créée à la demande puis réutilisée.
  static SessionManager session(
    String baseUrl,
    String username,
    String password,
  ) {
    return _sessions.putIfAbsent(_key(baseUrl, username), () {
      final manager = SessionManager(
        targetBaseUrl: baseUrl,
        username: username,
        password: password,
      );
      final key = _key(baseUrl, username);
      final fields = (_persisted['$_fieldsPrefix$key'] ?? '').split('|');
      manager.restore(
        cookie: _cookies['$_cookiePrefix$key'],
        userField: fields.length == 2 && fields[0].isNotEmpty ? fields[0] : null,
        passField: fields.length == 2 && fields[1].isNotEmpty ? fields[1] : null,
      );
      manager.onAuthenticated = (s) => _remember(s);
      return manager;
    });
  }

  /// Mode d'authentification de cette box, détecté une seule fois.
  static Future<AuthMode> authMode(String baseUrl, {Duration? timeout}) {
    return _authModes.putIfAbsent(baseUrl, () {
      final detection = detectAuthMode(baseUrl);
      return timeout == null
          ? detection
          : detection.timeout(timeout, onTimeout: () => AuthMode.basic);
    });
  }

  /// Impose un mode, quand une tentative a montré que la détection se trompait.
  static void setAuthMode(String baseUrl, AuthMode mode) {
    _authModes[baseUrl] = Future.value(mode);
  }

  /// Ferme et oublie la session d'une box : le prochain appel se réauthentifie.
  ///
  /// Le mode d'authentification est délibérément conservé : c'est une
  /// propriété de l'endpoint, pas de la session. L'effacer ferait redétecter
  /// le mode par le prochain appelant, avec la requête réseau que cela
  /// implique — et une fenêtre pendant laquelle un autre appelant lit un mode
  /// absent et lance sa propre détection en parallèle.
  static void invalidate(String baseUrl, String username) {
    _sessions.remove(_key(baseUrl, username))?.close();
  }

  /// Oublie le mode détecté, quand l'endpoint lui-même a pu changer.
  static void forgetAuthMode(String baseUrl) => _authModes.remove(baseUrl);

  /// Ferme toutes les sessions.
  ///
  /// À n'appeler que depuis un isolate qui se termine — un worker background.
  /// Depuis l'app au premier plan, ce serait fermer les sessions que l'écran
  /// d'accueil est en train d'utiliser.
  static void closeAll() {
    for (final session in _sessions.values) {
      session.close();
    }
    _sessions.clear();
    _authModes.clear();
  }
}

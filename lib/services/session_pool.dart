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

  /// Sessions retenues d'un passage précédent de l'app, lues au démarrage.
  ///
  /// Un isolate d'arrière-plan naît sans rien : sans ce report, chaque appui
  /// sur un widget refaisait détection du mode, détection des champs du
  /// formulaire et POST /login — trois allers-retours avant la première
  /// requête utile, soit deux secondes de plus sur un tunnel.
  static Map<String, String> _persisted = const {};

  static const _cookiePrefix = 'session_cookie_';
  static const _fieldsPrefix = 'session_fields_';
  static const _modePrefix = 'session_mode_';

  /// Recharge les sessions conservées. Sans effet si déjà fait.
  ///
  /// À appeler au début d'un point d'entrée d'arrière-plan, avant la première
  /// requête : après, il serait trop tard pour éviter le login.
  static Future<void> loadPersisted() async {
    if (_persisted.isNotEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      _persisted = {
        for (final key in prefs.getKeys())
          if (key.startsWith(_cookiePrefix) ||
              key.startsWith(_fieldsPrefix) ||
              key.startsWith(_modePrefix))
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
    } catch (e) {
      print('[SESSION] Sessions conservées illisibles: $e');
    }
  }

  static Future<void> _remember(SessionManager session) async {
    final key = _key(session.targetBaseUrl, session.username);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_cookiePrefix$key', session.sessionCookie ?? '');
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
        cookie: _persisted['$_cookiePrefix$key'],
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

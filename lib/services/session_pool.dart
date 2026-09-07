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

  /// La clé inclut l'hôte : un cookie obtenu via le tunnel n'est pas valable
  /// sur l'IP locale, les deux voies ont donc leur session propre.
  static String _key(String baseUrl, String username) => '$baseUrl|$username';

  /// Session pour cette box, créée à la demande puis réutilisée.
  static SessionManager session(
    String baseUrl,
    String username,
    String password,
  ) {
    return _sessions.putIfAbsent(
      _key(baseUrl, username),
      () => SessionManager(
        targetBaseUrl: baseUrl,
        username: username,
        password: password,
      ),
    );
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

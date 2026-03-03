import 'dart:io';
import 'dart:convert';
import 'dart:async';

enum AuthMode { basic, form }

/// Résultat d'une requête authentifiée.
class AuthenticatedResponse {
  final int statusCode;
  final String body;

  AuthenticatedResponse(this.statusCode, this.body);
}

/// Vérifie si le body HTML contient un formulaire de login (guillemets simples ou doubles).
bool _hasLoginForm(String body) {
  return body.contains('<form') &&
      (body.contains('action="/login"') || body.contains("action='/login'"));
}

/// Détecte le mode d'authentification d'un appareil.
Future<AuthMode> detectAuthMode(String targetBaseUrl) async {
  final client = HttpClient();
  client.badCertificateCallback = (cert, host, port) => true;
  client.connectionTimeout = const Duration(seconds: 5);

  try {
    final uri = Uri.parse(targetBaseUrl);
    final request = await client.getUrl(uri);
    request.headers.set('Accept', 'text/html,application/xhtml+xml,*/*');
    request.followRedirects = false;
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    print('[AUTH-DETECT] GET / → status=${response.statusCode}, bodyLen=${body.length}, body=${body.substring(0, body.length > 200 ? 200 : body.length)}');

    // Cas 1 : La page d'accueil contient directement le formulaire de login
    if (_hasLoginForm(body)) {
      print('[AUTH-DETECT] → AuthMode.form (login form in body)');
      return AuthMode.form;
    }

    // Cas 2 : Redirection vers /login
    if (response.statusCode >= 300 && response.statusCode < 400) {
      final location = response.headers.value('location') ?? '';
      if (location.contains('/login') || location == '/') {
        print('[AUTH-DETECT] → AuthMode.form (redirect to $location)');
        return AuthMode.form;
      }
    }

    // Cas 3 : 401 Unauthorized → vérifier si /login existe avec un formulaire
    if (response.statusCode == 401) {
      try {
        final loginUri = uri.resolve('/login');
        print('[AUTH-DETECT] 401 detected, trying GET $loginUri');
        final loginReq = await client.getUrl(loginUri);
        loginReq.headers.set('Accept', 'text/html,application/xhtml+xml,*/*');
        loginReq.followRedirects = false;
        final loginResp = await loginReq.close();
        final loginBody = await loginResp.transform(utf8.decoder).join();
        print('[AUTH-DETECT] GET /login → status=${loginResp.statusCode}, bodyLen=${loginBody.length}, body=${loginBody.substring(0, loginBody.length > 200 ? 200 : loginBody.length)}');
        if (_hasLoginForm(loginBody)) {
          print('[AUTH-DETECT] → AuthMode.form (login form at /login)');
          return AuthMode.form;
        }
      } catch (e) {
        print('[AUTH-DETECT] GET /login error: $e');
      }
    }

    print('[AUTH-DETECT] → AuthMode.basic (fallback)');
    return AuthMode.basic;
  } catch (e) {
    print('[AUTH-DETECT] Exception: $e');
    return AuthMode.basic;
  } finally {
    client.close();
  }
}

/// Gère l'authentification par formulaire et le cookie de session.
class SessionManager {
  final String targetBaseUrl;
  final String username;
  final String password;
  final HttpClient httpClient;

  String? _sessionCookie;
  Completer<bool>? _loginCompleter;
  String? _userField;
  String? _passField;

  SessionManager({
    required this.targetBaseUrl,
    required this.username,
    required this.password,
  }) : httpClient = HttpClient() {
    httpClient.badCertificateCallback = (cert, host, port) => true;
    httpClient.connectionTimeout = const Duration(seconds: 5);
  }

  String? get sessionCookie => _sessionCookie;

  /// Détecte les noms des champs du formulaire de login depuis le HTML.
  Future<void> _detectFormFields() async {
    if (_userField != null) return; // déjà détecté
    _userField = 'user';
    _passField = 'pass';
    try {
      final uri = Uri.parse(targetBaseUrl).resolve('/login');
      final req = await httpClient.getUrl(uri);
      req.headers.set('Accept', 'text/html,*/*');
      req.followRedirects = false;
      final resp = await req.close();
      final html = await resp.transform(utf8.decoder).join();

      final inputs = RegExp(r'<input[^>]*>', caseSensitive: false).allMatches(html);
      for (final input in inputs) {
        final tag = input.group(0)!;
        final nameMatch = RegExp(r"""name\s*=\s*['"](\w+)['"]""").firstMatch(tag);
        final typeMatch = RegExp(r"""type\s*=\s*['"](\w+)['"]""").firstMatch(tag);
        if (nameMatch != null) {
          final name = nameMatch.group(1)!;
          final type = (typeMatch?.group(1) ?? 'text').toLowerCase();
          if (type == 'text' || type == 'email') _userField = name;
          if (type == 'password') _passField = name;
        }
      }
      print('[SESSION] Detected form fields: user=$_userField, pass=$_passField');
    } catch (e) {
      print('[SESSION] Form field detection failed: $e');
    }
  }

  /// POST /login, extrait le cookie de session.
  Future<bool> login() async {
    if (_loginCompleter != null) {
      return _loginCompleter!.future;
    }

    _loginCompleter = Completer<bool>();

    try {
      // Détecter les noms des champs du formulaire
      await _detectFormFields();

      final uri = Uri.parse(targetBaseUrl).resolve('/login');
      final request = await httpClient.postUrl(uri);
      request.headers.set('Content-Type', 'application/x-www-form-urlencoded');
      request.followRedirects = false;

      final body = '$_userField=${Uri.encodeComponent(username)}&$_passField=${Uri.encodeComponent(password)}';
      print('[SESSION] POST /login with: $_userField=***, $_passField=***');
      request.add(utf8.encode(body));

      final response = await request.close();

      // Chercher le cookie sur la réponse du POST
      var cookies = response.headers['set-cookie'];
      print('[SESSION] Login POST status=${response.statusCode}, set-cookie=$cookies');

      // Si redirect (303/302) sans cookie → suivre la redirection pour récupérer le cookie
      if ((cookies == null || cookies.isEmpty) &&
          response.statusCode >= 300 &&
          response.statusCode < 400) {
        final location = response.headers.value('location');
        print('[SESSION] No cookie on redirect, following → $location');
        await response.drain();
        if (location != null) {
          final redirectUri = uri.resolve(location);
          final redirectReq = await httpClient.getUrl(redirectUri);
          redirectReq.followRedirects = false;
          final redirectResp = await redirectReq.close();
          cookies = redirectResp.headers['set-cookie'];
          print('[SESSION] Redirect response status=${redirectResp.statusCode}, set-cookie=$cookies');
          await redirectResp.drain();
        }
      } else {
        await response.drain();
      }

      if (cookies != null && cookies.isNotEmpty) {
        final cookieParts = <String>[];
        for (final cookieHeader in cookies) {
          final nameValue = cookieHeader.split(';').first.trim();
          if (nameValue.isNotEmpty) {
            cookieParts.add(nameValue);
          }
        }
        if (cookieParts.isNotEmpty) {
          _sessionCookie = cookieParts.join('; ');
          print('[SESSION] Login OK, cookie=$_sessionCookie');
          _loginCompleter!.complete(true);
          _loginCompleter = null;
          return true;
        }
      }

      print('[SESSION] Login FAILED: no set-cookie header');
      _loginCompleter!.complete(false);
      _loginCompleter = null;
      return false;
    } catch (e) {
      _loginCompleter!.complete(false);
      _loginCompleter = null;
      return false;
    }
  }

  /// Retourne le cookie de session, effectue le login si nécessaire.
  Future<String?> getSessionCookie() async {
    if (_sessionCookie == null) {
      await login();
    }
    return _sessionCookie;
  }

  /// Détecte si une réponse est la page de login (session expirée).
  bool isLoginPage(int statusCode, String body, String? locationHeader) {
    // 401 Unauthorized = session expirée ou cookie invalide
    if (statusCode == 401) {
      return true;
    }
    if (_hasLoginForm(body)) {
      return true;
    }
    if (statusCode >= 300 && statusCode < 400) {
      final loc = locationHeader ?? '';
      if (loc.contains('/login')) {
        return true;
      }
    }
    return false;
  }

  /// Invalide la session (force un re-login au prochain appel).
  void invalidateSession() {
    _sessionCookie = null;
  }

  /// Met à jour le cookie de session (ex: l'ESP32 a rafraîchi le cookie).
  void updateSessionCookie(String newCookie) {
    _sessionCookie = newCookie;
  }

  /// GET authentifié avec re-login automatique si session expirée.
  Future<AuthenticatedResponse> authenticatedGet(String path) async {
    final cookie = await getSessionCookie();
    final uri = Uri.parse(targetBaseUrl).resolve(path);

    var request = await httpClient.getUrl(uri);
    if (cookie != null) {
      request.headers.set('Cookie', cookie);
    }
    request.followRedirects = false;
    var response = await request.close();
    var body = await response.transform(utf8.decoder).join();
    final location = response.headers.value('location');

    if (isLoginPage(response.statusCode, body, location)) {
      _sessionCookie = null;
      final success = await login();
      if (success) {
        request = await httpClient.getUrl(uri);
        request.headers.set('Cookie', _sessionCookie!);
        request.followRedirects = false;
        response = await request.close();
        body = await response.transform(utf8.decoder).join();
      }
    }

    return AuthenticatedResponse(response.statusCode, body);
  }

  void close() {
    httpClient.close();
  }
}

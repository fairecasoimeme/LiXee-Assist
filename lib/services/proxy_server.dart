import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_proxy/shelf_proxy.dart';

import 'session_manager.dart';

Future<HttpServer> startProxy({
  required String targetBaseUrl,
  String? username,
  String? password,
}) async {
  final resolvedUrl = await _resolveRedirects(targetBaseUrl);
  final hasAuth = username != null && password != null;

  if (hasAuth) {
    // Détecter le mode d'auth (formulaire ou Basic Auth)
    final authMode = await detectAuthMode(resolvedUrl);
    print('[PROXY] resolvedUrl=$resolvedUrl, authMode=$authMode');

    if (authMode == AuthMode.form) {
      // Tester le login par formulaire avant de lancer le proxy
      final sessionManager = SessionManager(
        targetBaseUrl: resolvedUrl,
        username: username!,
        password: password!,
      );
      final loginOk = await sessionManager.login();

      if (loginOk) {
        // Réutiliser le même SessionManager (évite un double login sur l'ESP32)
        return _startSessionProxy(resolvedUrl, sessionManager);
      } else {
        // Form login échoué → fallback Basic Auth
        sessionManager.close();
        print('[PROXY] Form login failed, fallback to Basic Auth');
        return _startBasicAuthProxy(resolvedUrl, username!, password!);
      }
    } else {
      return _startBasicAuthProxy(resolvedUrl, username!, password!);
    }
  }

  // Pas d'auth : proxy simple
  final handler = proxyHandler(resolvedUrl);
  final server = await io.serve(handler, '127.0.0.1', 0);
  return server;
}

/// Proxy avec authentification par formulaire + cookie de session.
Future<HttpServer> _startSessionProxy(String targetBaseUrl, SessionManager sessionManager) async {
  final targetUri = Uri.parse(targetBaseUrl);
  print('[PROXY] Starting session proxy for $targetBaseUrl');

  final server = await HttpServer.bind('127.0.0.1', 0);
  final httpClient = HttpClient();
  httpClient.badCertificateCallback = (cert, host, port) => true;

  server.listen((HttpRequest clientRequest) async {
    try {
      final path = clientRequest.uri.toString();
      final url = targetUri.resolve(path);

      final bodyBytes = await _proxyRequest(
        httpClient, clientRequest, url, targetUri, sessionManager,
      );

      if (bodyBytes == null) return; // déjà géré (retry ou erreur)
    } catch (e) {
      try {
        clientRequest.response.statusCode = 502;
        clientRequest.response.write('Proxy error: $e');
        await clientRequest.response.close();
      } catch (_) {}
    }
  });

  return server;
}

/// Effectue une requête proxy avec gestion de session, redirections et re-login.
/// Boucle unique : suit les redirections, détecte le login, re-auth si besoin.
Future<List<int>?> _proxyRequest(
  HttpClient httpClient,
  HttpRequest clientRequest,
  Uri url,
  Uri targetUri,
  SessionManager sessionManager,
) async {
  final clientBody = await clientRequest.fold<List<int>>(
      [], (prev, chunk) => prev..addAll(chunk));
  final originalUrl = url;
  var currentUrl = url;
  var currentMethod = clientRequest.method;
  int loginRetries = 0;
  int redirectCount = 0;
  const maxLoginRetries = 2;
  const maxRedirects = 5;
  // Compteur total pour éviter toute boucle infinie
  int totalIterations = 0;
  const maxIterations = 10;

  while (totalIterations < maxIterations) {
    totalIterations++;
    final cookie = await sessionManager.getSessionCookie();

    final proxyRequest =
        await httpClient.openUrl(currentMethod, currentUrl);

    // Copier les headers (sans host, cookie, auth, encoding, referer)
    clientRequest.headers.forEach((name, values) {
      final lower = name.toLowerCase();
      if (lower != 'host' &&
          lower != 'cookie' &&
          lower != 'authorization' &&
          lower != 'accept-encoding' &&
          lower != 'referer') {
        for (var value in values) {
          proxyRequest.headers.add(name, value);
        }
      }
    });

    if (cookie != null) {
      proxyRequest.headers.set('Cookie', cookie);
    }
    proxyRequest.headers.set('host', targetUri.host);
    proxyRequest.followRedirects = false;

    // Body uniquement sur la toute première requête
    if (loginRetries == 0 && redirectCount == 0) {
      proxyRequest.add(clientBody);
    }

    final response = await proxyRequest.close();
    final bytes = await response.fold<List<int>>(
        [], (prev, chunk) => prev..addAll(chunk));
    final body = utf8.decode(bytes, allowMalformed: true);
    final location = response.headers.value('location');

    // Capturer Set-Cookie (rotation/rafraîchissement par l'ESP32)
    final setCookies = response.headers['set-cookie'];
    if (setCookies != null && setCookies.isNotEmpty) {
      final parts = <String>[];
      for (final h in setCookies) {
        final nv = h.split(';').first.trim();
        if (nv.isNotEmpty) parts.add(nv);
      }
      if (parts.isNotEmpty) {
        sessionManager.updateSessionCookie(parts.join('; '));
      }
    }

    // --- Cas 1 : Page de login détectée → re-auth + retry depuis l'URL d'origine ---
    if (sessionManager.isLoginPage(response.statusCode, body, location)) {
      print('[PROXY] Login page detected: status=${response.statusCode}, location=$location, bodyLen=${body.length}');
      if (loginRetries >= maxLoginRetries) {
        print('[PROXY] Max login retries reached ($maxLoginRetries)');
        break;
      }
      sessionManager.invalidateSession();
      final success = await sessionManager.login();
      if (!success) break;
      // Repartir de l'URL d'origine
      currentUrl = originalUrl;
      currentMethod = clientRequest.method;
      redirectCount = 0;
      loginRetries++;
      print('[PROXY] Re-auth #$loginRetries, retry ${originalUrl.path}');
      continue;
    }

    // --- Cas 2 : Redirection normale → suivre avec le cookie ---
    if (response.statusCode >= 300 &&
        response.statusCode < 400 &&
        location != null &&
        location.isNotEmpty &&
        redirectCount < maxRedirects) {
      currentUrl = currentUrl.resolve(location);
      currentMethod = 'GET';
      redirectCount++;
      print('[PROXY] Redirect #$redirectCount → $currentUrl');
      continue;
    }

    // --- Cas 3 : Réponse finale → envoyer au WebView ---
    _sendResponse(clientRequest.response, response, bytes);
    return bytes;
  }

  // Fallback : max atteint
  print('[PROXY] Max iterations reached for ${originalUrl.path}');
  try {
    clientRequest.response.statusCode = 502;
    clientRequest.response.write('Proxy: max retries');
    await clientRequest.response.close();
  } catch (_) {}
  return null;
}

/// Envoie la réponse proxy au client.
void _sendResponse(HttpResponse clientResponse, HttpClientResponse proxyResponse, List<int> bodyBytes) async {
  try {
    clientResponse.statusCode = proxyResponse.statusCode;

    proxyResponse.headers.forEach((name, values) {
      final lower = name.toLowerCase();
      // Ne pas transférer set-cookie, transfer-encoding, content-encoding, content-length
      if (lower != 'set-cookie' &&
          lower != 'transfer-encoding' &&
          lower != 'content-encoding' &&
          lower != 'content-length') {
        for (var value in values) {
          clientResponse.headers.add(name, value);
        }
      }
    });

    clientResponse.add(bodyBytes);
    await clientResponse.close();
  } catch (_) {}
}

/// Proxy avec Basic Auth classique (ancien firmware).
Future<HttpServer> _startBasicAuthProxy(String targetBaseUrl, String username, String password) async {
  final targetUri = Uri.parse(targetBaseUrl);
  final encoded = base64Encode(utf8.encode('$username:$password'));
  final isHttps = targetBaseUrl.startsWith('https://');

  if (isHttps) {
    // HTTPS + Basic Auth : proxy custom avec HttpClient
    final server = await HttpServer.bind('127.0.0.1', 0);
    final httpClient = HttpClient();
    httpClient.badCertificateCallback = (cert, host, port) => true;

    final rootUri = Uri(scheme: targetUri.scheme, host: targetUri.host, port: targetUri.port, path: '/');
    httpClient.addCredentials(rootUri, '', HttpClientBasicCredentials(username, password));
    httpClient.authenticate = (Uri url, String scheme, String? realm) async {
      httpClient.addCredentials(url, realm ?? '', HttpClientBasicCredentials(username, password));
      return true;
    };

    server.listen((HttpRequest clientRequest) async {
      try {
        final path = clientRequest.uri.toString();
        final url = targetUri.resolve(path);

        final proxyRequest = await httpClient.openUrl(clientRequest.method, url);

        clientRequest.headers.forEach((name, values) {
          final lower = name.toLowerCase();
          if (lower != 'host' && lower != 'authorization' && lower != 'accept-encoding') {
            for (var value in values) {
              proxyRequest.headers.add(name, value);
            }
          }
        });

        proxyRequest.headers.set('Authorization', 'Basic $encoded');
        proxyRequest.headers.set('host', targetUri.host);
        proxyRequest.followRedirects = true;
        proxyRequest.maxRedirects = 5;

        await for (final chunk in clientRequest) {
          proxyRequest.add(chunk);
        }

        final proxyResponse = await proxyRequest.close();
        clientRequest.response.statusCode = proxyResponse.statusCode;

        proxyResponse.headers.forEach((name, values) {
          final lower = name.toLowerCase();
          if (lower != 'www-authenticate' &&
              lower != 'transfer-encoding' &&
              lower != 'content-encoding' &&
              lower != 'content-length') {
            for (var value in values) {
              clientRequest.response.headers.add(name, value);
            }
          }
        });

        await proxyResponse.pipe(clientRequest.response);
      } catch (e) {
        try {
          clientRequest.response.statusCode = 502;
          clientRequest.response.write('Proxy error: $e');
          await clientRequest.response.close();
        } catch (_) {}
      }
    });

    return server;
  } else {
    // HTTP + Basic Auth : shelf_proxy avec middleware
    final handler = const Pipeline()
        .addMiddleware(_authMiddleware(username, password))
        .addHandler(proxyHandler(targetBaseUrl));
    return io.serve(handler, '127.0.0.1', 0);
  }
}

/// Suit les redirections pour trouver l'URL finale.
Future<String> _resolveRedirects(String url) async {
  try {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;

    final request = await client.getUrl(Uri.parse(url));
    request.followRedirects = false;

    final response = await request.close();
    await response.drain();

    if (response.statusCode >= 300 && response.statusCode < 400) {
      final location = response.headers.value('location');
      if (location != null) {
        final resolvedUri = Uri.parse(url).resolve(location);
        final originalUri = Uri.parse(url);
        // Ne suivre que les redirections qui changent le scheme ou le host
        // (ex: HTTP→HTTPS), pas les redirections d'auth (ex: / → /login)
        if (resolvedUri.scheme != originalUri.scheme ||
            resolvedUri.host != originalUri.host) {
          client.close();
          // Ne garder que scheme://host[:port], ignorer le path (souvent /login)
          return resolvedUri.origin;
        }
      }
    }

    client.close();
  } catch (_) {}
  return url;
}

Middleware _authMiddleware(String user, String pass) {
  final encoded = base64Encode(utf8.encode('$user:$pass'));

  return (innerHandler) {
    return (request) {
      final updatedRequest = request.change(headers: {
        ...request.headers,
        'Authorization': 'Basic $encoded',
      });
      return innerHandler(updatedRequest);
    };
  };
}

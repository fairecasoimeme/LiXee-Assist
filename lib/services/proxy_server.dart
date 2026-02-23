import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_proxy/shelf_proxy.dart';

Future<HttpServer> startProxy({
  required String targetBaseUrl,
  String? username,
  String? password,
}) async {
  final resolvedUrl = await _resolveRedirects(targetBaseUrl);

  final isHttps = resolvedUrl.startsWith('https://');
  final hasAuth = username != null && password != null;

  if (isHttps && hasAuth) {
    return _startCustomProxy(resolvedUrl, username, password);
  }

  Handler handler;
  if (hasAuth) {
    handler = const Pipeline()
        .addMiddleware(_authMiddleware(username!, password!))
        .addHandler(proxyHandler(resolvedUrl));
  } else {
    handler = proxyHandler(resolvedUrl);
  }

  final server = await io.serve(handler, '127.0.0.1', 0);
  return server;
}

/// Proxy custom pour HTTPS avec auth — basé directement sur HttpServer
Future<HttpServer> _startCustomProxy(String targetBaseUrl, String username, String password) async {
  final targetUri = Uri.parse(targetBaseUrl);
  final encoded = base64Encode(utf8.encode('$username:$password'));
  final server = await HttpServer.bind('127.0.0.1', 0);

  final httpClient = HttpClient();
  httpClient.badCertificateCallback = (cert, host, port) => true;

  // Pré-enregistrer les credentials pour tout le host (tous les chemins)
  final rootUri = Uri(scheme: targetUri.scheme, host: targetUri.host, port: targetUri.port, path: '/');
  httpClient.addCredentials(
    rootUri,
    '',
    HttpClientBasicCredentials(username, password),
  );

  // Callback de fallback si le serveur challenge avec un realm spécifique
  httpClient.authenticate = (Uri url, String scheme, String? realm) async {
    httpClient.addCredentials(
      url,
      realm ?? '',
      HttpClientBasicCredentials(username, password),
    );
    return true;
  };

  server.listen((HttpRequest clientRequest) async {
    try {
      final path = clientRequest.uri.toString();
      final url = targetUri.resolve(path);

      final proxyRequest = await httpClient.openUrl(clientRequest.method, url);

      // Copier les headers du client (sauf host, authorization, accept-encoding)
      clientRequest.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower != 'host' && lower != 'authorization' && lower != 'accept-encoding') {
          for (var value in values) {
            proxyRequest.headers.add(name, value);
          }
        }
      });

      // Injecter l'auth directement (pré-emptive)
      proxyRequest.headers.set('Authorization', 'Basic $encoded');
      proxyRequest.headers.set('host', targetUri.host);
      proxyRequest.followRedirects = true;
      proxyRequest.maxRedirects = 5;

      // Transférer le body de la requête
      await for (final chunk in clientRequest) {
        proxyRequest.add(chunk);
      }

      final proxyResponse = await proxyRequest.close();

      clientRequest.response.statusCode = proxyResponse.statusCode;

      // Copier les headers de réponse
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
}

/// Suit les redirections pour trouver l'URL finale
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
        final resolved = Uri.parse(url).resolve(location).toString();
        client.close();
        return resolved;
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

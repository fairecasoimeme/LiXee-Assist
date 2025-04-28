import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_proxy/shelf_proxy.dart';

Future<HttpServer> startProxy({
  required String targetBaseUrl,
  String? username,
  String? password,
  int port = 8080,
}) async {
  final handler = (username != null && password != null)
      ? const Pipeline()
      .addMiddleware(_authMiddleware(username, password))
      .addHandler(proxyHandler(targetBaseUrl))
      : proxyHandler(targetBaseUrl);

  final server = await io.serve(handler, '127.0.0.1', port);
  print('🛡️ Proxy actif sur http://localhost:$port → $targetBaseUrl');
  return server;
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

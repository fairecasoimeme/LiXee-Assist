import 'dart:io';
import 'dart:convert';

class BoundHttpClient {
  static Future<String> get(Uri uri, {void Function(String)? onLog}) async {
    try {
      final msg = "🌐 Tentative de GET direct vers ${uri.toString()}";
      print(msg);
      if (onLog != null) onLog(msg);

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);

      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, "application/json");

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      client.close();
      return body;
    } catch (e) {
      final errorMsg = "❌ Erreur HTTP directe : $e";
      print(errorMsg);
      throw SocketException(errorMsg);
    }
  }
}

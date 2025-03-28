import 'dart:convert';
import 'dart:io';

class ESPService {
  static Future<bool> sendWiFiConfigToESP(String ssid, String password) async {
    final uri = Uri.parse("http://192.168.4.1/setConfigWiFi");

    final body = jsonEncode({
      "ssid": ssid,
      "password": password,
    });

    try {
      final request = await HttpClient().postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, "application/json");
      request.add(utf8.encode(body));

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      print("✅ Réponse ESP: $responseBody");
      return response.statusCode == 200;
    } catch (e) {
      print("❌ Erreur POST vers ESP: $e");
      return false;
    }
  }
}

import 'package:flutter/services.dart';

class WifiForceBinder {
  static const _channel = MethodChannel('wifi_force_binder');

  static Future<bool> connectToESPOnly({
    required String ssidAP,
    required String passwordAP,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>(
        "connectToESPOnly",
        {
          "ssidAP": ssidAP,
          "passwordAP": passwordAP,
        },
      );
      return result == "ok";
    } catch (e) {
      print("❌ Connexion ESP échouée : $e");
      return false;
    }
  }

  static Future<bool> sendWiFiConfig({
    required String ssidConfig,
    required String passwordConfig,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>(
        "sendWiFiConfig",
        {
          "ssidConfig": ssidConfig,
          "passwordConfig": passwordConfig,
        },
      );
      return result == "ok";
    } catch (e) {
      print("❌ Envoi config WiFi échoué : $e");
      return false;
    }
  }
}

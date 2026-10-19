// Variante libre : sans Firebase, donc sans notifications push. Ce fichier
// remplace lib/services/push_backend.dart (voir tool/foss.sh) et doit en
// garder l'interface.

/// Notifications push : absentes de la variante libre.
class PushBackend {
  PushBackend._();

  /// Cette variante de l'application reçoit-elle des notifications push ?
  static const bool available = false;

  static Future<void> init() async {}

  static Future<String?> token() async => null;

  static void listen({
    required void Function(String token) onTokenRefresh,
    required void Function(int id, String? title, String? body) onMessage,
  }) {}
}

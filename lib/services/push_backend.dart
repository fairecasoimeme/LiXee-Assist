import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

// Ce fichier est le seul à dépendre de Firebase. La variante libre de
// l'application (voir tool/foss.sh) le remplace par foss/lib/services/
// push_backend.dart, qui ne fait rien.

/// Handler Firebase pour les messages reçus en arrière-plan (doit être top-level).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print('[FCM] ======= BACKGROUND MESSAGE =======');
  print('[FCM] messageId: ${message.messageId}');
  print('[FCM] notification: ${message.notification?.title} / ${message.notification?.body}');
  print('[FCM] data: ${message.data}');
  print('[FCM] ====================================');
}

/// Notifications push, par Firebase Cloud Messaging.
class PushBackend {
  PushBackend._();

  /// Cette variante de l'application reçoit-elle des notifications push ?
  static const bool available = true;

  /// Initialise Firebase et demande la permission d'afficher des
  /// notifications.
  static Future<void> init() async {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  /// Jeton de l'appareil, à enregistrer auprès de remote.lixee-box.fr.
  static Future<String?> token() => FirebaseMessaging.instance.getToken();

  /// Écoute le renouvellement du jeton et les messages reçus au premier plan.
  static void listen({
    required void Function(String token) onTokenRefresh,
    required void Function(int id, String? title, String? body) onMessage,
  }) {
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      print('[FCM] Token refreshed: $newToken');
      onTokenRefresh(newToken);
    });

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('[FCM] ======= MESSAGE REÇU =======');
      print('[FCM] messageId: ${message.messageId}');
      print('[FCM] notification: ${message.notification?.title} / ${message.notification?.body}');
      print('[FCM] data: ${message.data}');
      print('[FCM] from: ${message.from}');
      print('[FCM] ==============================');

      // Extraire titre et body (notification payload OU data payload)
      final title = message.notification?.title ?? message.data['title'];
      final body =
          message.notification?.body ??
          message.data['body'] ??
          message.data['message'];
      onMessage(message.hashCode, title as String?, body as String?);
    });
  }
}

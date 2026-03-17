import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'session_manager.dart';

/// Service d'enregistrement du token FCM auprès de remote.lixee-box.fr.
///
/// Flow :
/// 1. Parcourt les devices sauvegardés pour trouver ceux avec auth
/// 2. Pour chaque device, appelle GET /api/tunnel/credentials sur la box locale
///    (via SessionManager pour le login formulaire, fallback Basic Auth)
/// 3. Appelle POST https://remote.lixee-box.fr/api/push/register avec les headers
///    X-Device-Id / X-Device-Token et le body { token, platform, deviceName }
class PushRegisterService {
  static const String _remoteBaseUrl = 'https://remote.lixee-box.fr';
  static const String _prefsKeyRegistered = 'fcm_registered_devices';

  /// Enregistre le token FCM pour tous les devices qui ont des credentials tunnel.
  /// Appelé au démarrage de l'app et lors d'un refresh de token.
  static Future<void> registerFcmTokenForAllDevices({String? fcmToken}) async {
    // Récupérer le token FCM
    fcmToken ??= await FirebaseMessaging.instance.getToken();
    if (fcmToken == null) {
      print('[PUSH] Pas de token FCM disponible');
      return;
    }
    print('[PUSH] Token FCM: ${fcmToken.substring(0, 20)}...');

    // Nom de l'appareil mobile
    final deviceName = await _getDeviceName();
    final platform = Platform.isAndroid ? 'android' : 'ios';
    print('[PUSH] Device: $deviceName ($platform)');

    // Charger les devices sauvegardés
    final prefs = await SharedPreferences.getInstance();
    final rawDevices = prefs.getStringList('saved_devices') ?? [];
    final registeredDevices =
        List<String>.from(prefs.getStringList(_prefsKeyRegistered) ?? []);

    print('[PUSH] ${rawDevices.length} device(s) sauvegardé(s)');

    for (var entry in rawDevices) {
      final parts = entry.split('|');
      // On ne prend que les devices avec auth (5 parties)
      if (parts.length != 5 || parts[2] != 'auth') {
        print('[PUSH] Skip device sans auth: ${parts[0]}');
        continue;
      }

      final deviceUrl = parts[1];
      final login = parts[3];
      final password = parts[4];

      print('[PUSH] Traitement device: ${parts[0]} ($deviceUrl)');

      try {
        // 1. Récupérer les credentials tunnel depuis la box locale
        final credentials = await _fetchTunnelCredentials(
          deviceUrl: deviceUrl,
          login: login,
          password: password,
        );
        if (credentials == null) {
          print('[PUSH] ❌ Pas de credentials tunnel pour $deviceUrl');
          continue;
        }

        final tunnelClientId = credentials['tunnelClientId'] as String;
        final tunnelToken = credentials['tunnelToken'] as String;
        print('[PUSH] Tunnel credentials: id=$tunnelClientId, token=${tunnelToken.substring(0, 8)}...');

        // Vérifier si déjà enregistré avec ce token + ce device
        final registrationKey = '$tunnelClientId:$fcmToken';
        if (registeredDevices.contains(registrationKey)) {
          print('[PUSH] Déjà enregistré pour device $tunnelClientId, skip');
          continue;
        }

        // 2. Enregistrer le token push sur remote.lixee-box.fr
        final success = await _registerPushToken(
          tunnelClientId: tunnelClientId,
          tunnelToken: tunnelToken,
          fcmToken: fcmToken,
          platform: platform,
          deviceName: deviceName,
        );

        if (success) {
          registeredDevices.add(registrationKey);
          await prefs.setStringList(_prefsKeyRegistered, registeredDevices);
          print('[PUSH] ✅ Enregistré avec succès pour device $tunnelClientId');
        } else {
          print('[PUSH] ❌ Échec enregistrement pour device $tunnelClientId');
        }
      } catch (e) {
        print('[PUSH] ❌ Erreur pour $deviceUrl: $e');
      }
    }
  }

  /// Force le ré-enregistrement (ex: après un refresh de token FCM).
  static Future<void> forceReRegister(String newToken) async {
    print('[PUSH] Force re-register avec nouveau token');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKeyRegistered);
    await registerFcmTokenForAllDevices(fcmToken: newToken);
  }

  /// Récupère tunnelClientId + tunnelToken depuis la box locale.
  /// Tente d'abord le login par formulaire (SessionManager), puis fallback Basic Auth.
  static Future<Map<String, dynamic>?> _fetchTunnelCredentials({
    required String deviceUrl,
    required String login,
    required String password,
  }) async {
    String baseUrl = deviceUrl;
    if (!baseUrl.startsWith('http')) {
      baseUrl = 'http://$baseUrl';
    }

    // Détecter le mode d'auth
    final authMode = await detectAuthMode(baseUrl);
    print('[PUSH] Auth mode pour $baseUrl: $authMode');

    if (authMode == AuthMode.form) {
      // Login par formulaire avec SessionManager
      final session = SessionManager(
        targetBaseUrl: baseUrl,
        username: login,
        password: password,
      );
      try {
        final loginOk = await session.login();
        if (!loginOk) {
          print('[PUSH] Form login échoué pour $baseUrl, essai Basic Auth...');
          session.close();
          return _fetchWithBasicAuth(baseUrl, login, password);
        }

        print('[PUSH] Form login OK, appel /api/tunnel/credentials...');
        final result = await session.authenticatedGet('/api/tunnel/credentials');
        print('[PUSH] Réponse credentials: status=${result.statusCode}, body=${result.body}');

        if (result.statusCode == 200 && result.body.isNotEmpty) {
          final data = jsonDecode(result.body);
          if (data['tunnelClientId'] != null && data['tunnelToken'] != null) {
            return Map<String, dynamic>.from(data);
          }
        }
      } catch (e) {
        print('[PUSH] Erreur SessionManager: $e');
      } finally {
        session.close();
      }
    } else {
      // Basic Auth
      return _fetchWithBasicAuth(baseUrl, login, password);
    }
    return null;
  }

  /// Fallback : récupère les credentials tunnel via Basic Auth.
  static Future<Map<String, dynamic>?> _fetchWithBasicAuth(
      String baseUrl, String login, String password) async {
    print('[PUSH] Tentative Basic Auth pour $baseUrl/api/tunnel/credentials');
    final dio = Dio();
    dio.options.connectTimeout = const Duration(seconds: 5);
    dio.options.receiveTimeout = const Duration(seconds: 5);

    try {
      final response = await dio.get(
        '$baseUrl/api/tunnel/credentials',
        options: Options(
          headers: {
            'Authorization':
                'Basic ${base64Encode(utf8.encode('$login:$password'))}',
          },
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );

      print('[PUSH] Basic Auth réponse: status=${response.statusCode}, data=${response.data}');

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data is String
            ? jsonDecode(response.data)
            : response.data;
        if (data['tunnelClientId'] != null && data['tunnelToken'] != null) {
          return Map<String, dynamic>.from(data);
        }
      }
    } catch (e) {
      print('[PUSH] Basic Auth échoué: $e');
    } finally {
      dio.close(force: true);
    }
    return null;
  }

  /// Enregistre le token FCM sur remote.lixee-box.fr.
  static Future<bool> _registerPushToken({
    required String tunnelClientId,
    required String tunnelToken,
    required String fcmToken,
    required String platform,
    required String deviceName,
  }) async {
    final dio = Dio();
    dio.options.connectTimeout = const Duration(seconds: 10);
    dio.options.receiveTimeout = const Duration(seconds: 10);

    final url = '$_remoteBaseUrl/api/push/register';
    print('[PUSH] POST $url');
    print('[PUSH]   Headers: X-Device-Id=$tunnelClientId, X-Device-Token=${tunnelToken.substring(0, 8)}...');
    print('[PUSH]   Body: token=${fcmToken.substring(0, 20)}..., platform=$platform, deviceName=$deviceName');

    try {
      final response = await dio.post(
        url,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'X-Device-Id': tunnelClientId,
            'X-Device-Token': tunnelToken,
          },
          validateStatus: (status) => true, // Accepter toutes les réponses pour log
        ),
        data: {
          'token': fcmToken,
          'platform': platform,
          'deviceName': deviceName,
        },
      );

      print('[PUSH] Réponse remote: status=${response.statusCode}, body=${response.data}');
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      print('[PUSH] Erreur enregistrement push: $e');
      return false;
    } finally {
      dio.close(force: true);
    }
  }

  /// Retourne un nom lisible pour l'appareil mobile.
  static Future<String> _getDeviceName() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        return '${info.brand} ${info.model}';
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        return info.name;
      }
    } catch (_) {}
    return 'Unknown Device';
  }
}

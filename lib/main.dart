import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:dio/dio.dart';
import 'dart:io';
import 'dart:convert';
import 'screens/wifi_provision_screen.dart';
import 'screens/home_screen.dart';
import 'services/session_manager.dart';
import 'services/push_register_service.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

const String deviceCheckTaskName = 'com.lixee.assist.deviceCheck';

/// Détection TV unifiée (singleton) — initialisé une seule fois dans main().
class TVDetector {
  static bool _isTV = false;
  static bool get isTV => _isTV;

  static Future<void> init() async {
    if (Platform.isAndroid) {
      try {
        final info = await DeviceInfoPlugin().androidInfo;
        _isTV = info.systemFeatures.contains('android.software.leanback');
      } catch (_) {}
    }
  }
}

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

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await checkDeviceStatusBackground();
    } catch (e) {
      // Silently handle errors to avoid crashing the worker
    }
    return Future.value(true);
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialiser Firebase
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Demander la permission notifications push (FCM)
  final messaging = FirebaseMessaging.instance;
  await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  // Récupérer le token FCM et l'enregistrer sur remote.lixee-box.fr
  try {
    final fcmToken = await messaging.getToken();
    print('[FCM] Token: $fcmToken');

    // Enregistrer le token FCM pour tous les devices avec credentials tunnel
    if (fcmToken != null) {
      PushRegisterService.registerFcmTokenForAllDevices(fcmToken: fcmToken);
    }
  } catch (e) {
    print('[FCM] Token unavailable (pas de Play Services ?): $e');
  }

  // Écouter les refresh de token FCM → ré-enregistrer automatiquement
  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
    print('[FCM] Token refreshed: $newToken');
    PushRegisterService.forceReRegister(newToken);
  });

  // Écouter les messages FCM en foreground
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    print('[FCM] ======= MESSAGE REÇU =======');
    print('[FCM] messageId: ${message.messageId}');
    print('[FCM] notification: ${message.notification?.title} / ${message.notification?.body}');
    print('[FCM] data: ${message.data}');
    print('[FCM] from: ${message.from}');
    print('[FCM] ==============================');

    // Extraire titre et body (notification payload OU data payload)
    String? title = message.notification?.title ?? message.data['title'];
    String? body = message.notification?.body ?? message.data['body'] ?? message.data['message'];

    if (title != null || body != null) {
      flutterLocalNotificationsPlugin.show(
        message.hashCode,
        title ?? 'LiXee-Box',
        body ?? '',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'fcm_channel',
            'Notifications Push',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_stat_notify',
            color: Color(0xFF2196F3),
          ),
        ),
      );
    }
  });

  // Initialiser WorkManager
  await Workmanager().initialize(callbackDispatcher);

  // Enregistrer la tâche périodique (minimum 15 minutes sur Android)
  await Workmanager().registerPeriodicTask(
    deviceCheckTaskName,
    deviceCheckTaskName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(
      networkType: NetworkType.connected,
    ),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );

  if (Platform.isAndroid) {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 33) {
      await Permission.notification.request();
    }
  }

  const androidInit = AndroidInitializationSettings('@drawable/ic_stat_notify');
  const iosInit = DarwinInitializationSettings();

  const initSettings = InitializationSettings(
    android: androidInit,
    iOS: iosInit,
  );

  await flutterLocalNotificationsPlugin.initialize(initSettings);

  // Initialisation WebView avec hybrid composition sur Android
  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  // Demande les permissions réseau et localisation
  await Permission.location.request();

  // Détecter si l'appareil est une Android TV (une seule fois)
  await TVDetector.init();

  runApp(MyApp());
}

Future<void> checkDeviceStatusBackground() async {
  // Initialiser les notifications dans le worker (contexte isolé)
  final notifPlugin = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('@drawable/ic_stat_notify');
  const initSettings = InitializationSettings(android: androidInit);
  await notifPlugin.initialize(initSettings);

  SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  List<String> rawDevices = prefs.getStringList('saved_devices') ?? [];

  List<String> validDevices = [];

  for (var entry in rawDevices) {
    List<String> parts = entry.split('|');
    if (parts.length == 2 || (parts.length == 5 && parts[2] == 'auth')) {
      validDevices.add(entry);
    }
  }

  for (var entry in validDevices) {
    List<String> parts = entry.split('|');
    String deviceName = parts[0];
    String deviceUrl = parts[1];
    String? login = parts.length == 5 ? parts[3] : null;
    String? password = parts.length == 5 ? parts[4] : null;

    if (isIPAddress(deviceUrl)) {
      // IP directe : normaliser l'URL
      if (!deviceUrl.startsWith('http')) {
        deviceUrl = "http://$deviceUrl";
      }
    } else if (isDNSName(deviceUrl)) {
      // DNS classique (ex: xxx.lixee-box.fr) : utiliser tel quel
      if (!deviceUrl.startsWith('http')) {
        deviceUrl = "http://$deviceUrl";
      }
    } else {
      // mDNS (.local) : résolution nécessaire
      String? ip = await resolveMdnsIP(deviceName);
      if (ip != null) {
        deviceUrl = "http://$ip";
      } else {
        continue;
      }
    }
    try {
      int statusCode;
      String responseBody;

      if (login != null && password != null) {
        // Détecter le mode auth
        final authMode = await detectAuthMode(deviceUrl);

        if (authMode == AuthMode.form) {
          // Mode formulaire : utiliser SessionManager
          final session = SessionManager(
            targetBaseUrl: deviceUrl,
            username: login,
            password: password,
          );
          try {
            final result = await session.authenticatedGet('/poll');
            statusCode = result.statusCode;
            responseBody = result.body;
          } finally {
            session.close();
          }
        } else {
          // Mode Basic Auth classique
          final dio = Dio();
          try {
            final response = await dio.get(
              "$deviceUrl/poll",
              options: Options(
                sendTimeout: const Duration(seconds: 2),
                receiveTimeout: const Duration(seconds: 5),
                responseType: ResponseType.plain,
                headers: {
                  'Authorization': 'Basic ${base64Encode(utf8.encode('$login:$password'))}',
                },
              ),
            );
            statusCode = response.statusCode ?? 0;
            responseBody = response.data?.toString() ?? '';
          } finally {
            dio.close(force: true);
          }
        }
      } else {
        // Pas d'auth
        final dio = Dio();
        try {
          final response = await dio.get(
            "$deviceUrl/poll",
            options: Options(
              sendTimeout: const Duration(seconds: 2),
              receiveTimeout: const Duration(seconds: 5),
              responseType: ResponseType.plain,
            ),
          );
          statusCode = response.statusCode ?? 0;
          responseBody = response.data?.toString() ?? '';
        } finally {
          dio.close(force: true);
        }
      }

      if (statusCode == 200 && responseBody.isNotEmpty) {
        int notifId = 0;
        final jsonData = jsonDecode(responseBody);
        if (jsonData != null && jsonData['notifications'] != null) {
          List<dynamic> notifications = jsonData['notifications'];

          for (var notif in notifications) {
            var title = "";
            if (notif['type'] == 1) {
              title = "❌ $deviceName - ${notif['title']}";
            }
            if (notif['type'] == 2) {
              title = "⚠️ $deviceName - ${notif['title']}";
            } else if (notif['type'] == 3) {
              title = "️📋 $deviceName - ${notif['title']}";
            }
            await saveNotification(deviceName, notif['timeStamp'], title, notif['message']);
            await notifPlugin.show(
              notifId++,
              title,
              notif['message'] ?? '',
              NotificationDetails(
                android: AndroidNotificationDetails(
                  'lixee_channel_id',
                  'Lixee Notifications',
                  importance: Importance.defaultImportance,
                  priority: Priority.defaultPriority,
                  styleInformation: BigTextStyleInformation(
                    notif['message'] ?? '',
                    summaryText: 'Voir plus',
                  ),
                ),
              ),
            );
          }
        }
      }
    } catch (e) {
      // Silently handle errors
    }
  }
}

// ✅ Définition de `MyApp`
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const lixeeBlue = Color(0xFF1B75BC);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LiXee-Assist',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        focusColor: lixeeBlue.withOpacity(0.2),
        hoverColor: lixeeBlue.withOpacity(0.1),
        // Style de focus global pour les boutons (visible au D-pad TV)
        iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return lixeeBlue.withOpacity(0.25);
              }
              return null;
            }),
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return const BorderSide(color: lixeeBlue, width: 2);
              }
              return null;
            }),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return lixeeBlue.withOpacity(0.15);
              }
              return null;
            }),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return lixeeBlue.withOpacity(0.15);
              }
              return null;
            }),
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return const BorderSide(color: lixeeBlue, width: 2);
              }
              return const BorderSide(color: lixeeBlue);
            }),
          ),
        ),
      ),
      home: HomeScreen(),
    );
  }
}

class ZigPowerApp extends StatelessWidget {
  final GoRouter _router = GoRouter(
    routes: [
      GoRoute(path: '/wifi_provision',builder: (context, state) => WifiProvisionScreen()),
    ],
  );

  ZigPowerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}

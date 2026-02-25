import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'dart:io';
import 'dart:convert';
import 'screens/wifi_provision_screen.dart';
import 'screens/home_screen.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

const String deviceCheckTaskName = 'com.lixee.assist.deviceCheck';

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
    final Dio dio = Dio();
    try {
      final response = await dio.get(
        "$deviceUrl/poll",
        options: Options(
          sendTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 5),
          responseType: ResponseType.plain,
          headers: (login != null && password != null)
              ? {
            'Authorization': 'Basic ${base64Encode(
                utf8.encode('$login:$password'))}',
          }
              : null,
        ),
      );

      if (response.statusCode == 200) {
        int notifId = 0;
        if (response.data != "") {
          List<dynamic> notifications = jsonDecode(
              response.data)['notifications'];

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
    } finally {
      dio.close(force: true);
    }
  }
}

// ✅ Définition de `MyApp`
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LiXee-Assist',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: HomeScreen(), // Assure-toi que HomeScreen est bien défini
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

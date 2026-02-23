import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'screens/wifi_provision_screen.dart';
import 'screens/home_screen.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initializeService();

  if (Platform.isAndroid){

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 33) {
      final status = await Permission.notification.request();
      print("Permission notifications : $status");
    }
  }

  const androidInit = AndroidInitializationSettings('@drawable/ic_stat_notify');
  const iosInit = DarwinInitializationSettings();

  const initSettings = InitializationSettings(
    android: androidInit,
    iOS: iosInit,
  );

  await flutterLocalNotificationsPlugin.initialize(initSettings);

  // ✅ Initialisation WebView avec hybrid composition sur Android
  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }
  // 🔥 Demande les permissions réseau et localisation
  await Permission.location.request();
  await Permission.ignoreBatteryOptimizations.request();

  runApp(MyApp());
}

void checkDeviceStatusBackground() async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  List<String> rawDevices = prefs.getStringList('saved_devices') ?? [];

  List<String> validDevices = [];

  for (var entry in rawDevices) {
    List<String> parts = entry.split('|');
    if (parts.length == 2 || (parts.length == 5 && parts[2] == 'auth')) {
      validDevices.add(entry);
    } else {
      print("⚠ Entrée ignorée (format invalide) : $entry");
    }
  }

  for (var entry in validDevices) {
    List<String> parts = entry.split('|');
    String deviceName = parts[0];
    String deviceUrl = parts[1];
    String? login = parts.length == 5 ? parts[3] : null;
    String? password = parts.length == 5 ? parts[4] : null;

    if (!isIPAddress(deviceUrl)) {

      String? ip = await resolveMdnsIP(deviceName);
      if (ip != null) {
        deviceUrl = "http://$ip";
      } else {
        return;
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
        print("✅ $deviceName est actif");

        int notificationId = 0;
        if (response.data != "") {
          List<dynamic> notifications = jsonDecode(
              response.data)['notifications'];

          for (var notif in notifications) {
            print(notif);
            var title = "";
            if (notif['type'] == 1) {
              title = "❌ $deviceName - ${notif['title']}";
            }
            if (notif['type'] == 2) {
              title = "⚠️ $deviceName - ${notif['title']}";
            } else if (notif['type'] == 3) {
              title = "️📋 $deviceName - ${notif['title']}";
            }
            await saveNotification( deviceName, notif['timeStamp'], title, notif['message']);
            await flutterLocalNotificationsPlugin.show(
              notificationId++,
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
      } else {
        print("❌ $deviceName a répondu avec le code ${response.statusCode}");
      }
    } catch (e) {
      print("❌ Erreur pendant la vérification de $deviceName : $e");
    } finally {
      dio.close(force: true); // 🔒 bonne pratique pour nettoyer
    }

  }

}


const notificationId = 888;
const notificationChannelId = 'my_foreground';
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    notificationChannelId, // id
    'LiXee Foreground Service', // title
    description:
    'Used for alert notifications.', // description
    importance: Importance.low, // importance must be at low or higher level
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
  FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      foregroundServiceTypes: [AndroidForegroundType.specialUse],
      foregroundServiceNotificationId:notificationId,
      initialNotificationTitle: 'LiXee-Assist',
      initialNotificationContent: 'Service de notifications activé ...',

      autoStart: true,

    ),
    iosConfiguration: IosConfiguration(
      /*autoStart: true,
      onForeground: onStartCallback,
      onBackground: onIosBackground,*/
    ),
  );

  await service.startService();
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async{
  DartPluginRegistrant.ensureInitialized();

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  Timer.periodic(Duration(seconds: 30), (timer) async {
    print("⏰ Tâche en arrière-plan lancée !");
    checkDeviceStatusBackground();
  });
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

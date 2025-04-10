import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'screens/wifi_provision_screen.dart';
import 'screens/home_screen.dart';

Future<void> requestPermissions() async {
  await [
    Permission.location,
    Permission.locationWhenInUse,
    Permission.locationAlways,
  ].request();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🔥 Demande les permissions réseau et localisation
  await Permission.location.request();

  runApp(MyApp());
}

// ✅ Définition de `MyApp`
class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ZigPower Connect',
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}

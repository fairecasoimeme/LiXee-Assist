import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class WelcomeScreen extends StatefulWidget {
  @override
  _WelcomeScreenState createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final TextEditingController ssidController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  void startBluetoothProvisioning() {
    print("Lancement du provisioning Bluetooth...");
    context.go('/bluetooth');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Configuration WiFi")),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text("Connectez votre ESP32S3", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            SizedBox(height: 20),
            TextField(
              controller: ssidController,
              decoration: InputDecoration(labelText: "Nom du réseau (SSID)", border: OutlineInputBorder()),
            ),
            SizedBox(height: 10),
            TextField(
              controller: passwordController,
              decoration: InputDecoration(labelText: "Mot de passe WiFi", border: OutlineInputBorder()),
              obscureText: true,
            ),
            SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: startBluetoothProvisioning,
              icon: Icon(Icons.bluetooth),
              label: Text("Connecter via Bluetooth"),
            ),
            ElevatedButton(
              onPressed: () => context.go('/lixee_ble'),
              child: Text("Provisionner LIXEE"),
            ),
            ElevatedButton(
              onPressed: () => context.go('/wifi_provision'),
              child: Text("Provisionner LIXEE wifi"),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../main.dart' show boxListChanged;
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WebViewWifiPostScreen extends StatefulWidget {
  final String ssid;
  final String password;
  final String deviceId; // ✅ Ajout du Device ID

  const WebViewWifiPostScreen({super.key, 
    required this.ssid,
    required this.password,
    required this.deviceId,
  });

  @override
  State<WebViewWifiPostScreen> createState() => _WebViewWifiPostScreenState();
}

class _WebViewWifiPostScreenState extends State<WebViewWifiPostScreen> {
  String statusMessage = "🔧 Configuration en cours...";
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _sendWifiConfig();
  }

  /// 💾 **Sauvegarde de l'appareil sous "LIXEEGW-XXXX"**
  Future<void> _saveDevice() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> devices = prefs.getStringList('saved_devices') ?? [];

    String deviceName = "LIXEEGW-${widget.deviceId}|http://lixeegw-${widget.deviceId}.local"; // 🔥 Format unique !

    if (!devices.contains(deviceName)) {
      devices.add(deviceName);
      await prefs.setStringList('saved_devices', devices);
    boxListChanged();
      print("✅ Appareil enregistré : $deviceName");
    } else {
      print("ℹ Appareil déjà enregistré !");
    }
  }

  /// 🔄 Envoi de la configuration WiFi à l'ESP
  Future<void> _sendWifiConfig() async {
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds:5),
      receiveTimeout: Duration(seconds:5),
    ));
    try {
      print("📡 Envoi des identifiants WiFi via Dio (multipart/form-data)...");

      FormData formData = FormData.fromMap({
        "ssid": widget.ssid,
        "password": widget.password,
      });

      Response response = await dio.post(
        "http://192.168.4.1/setConfigWiFi",
        options: Options(headers: {"Content-Type": "multipart/form-data"}),
        data: formData,
      );

      print("📡 Réponse ESP via Dio : ${response.data}");

      if (response.data != null && response.data["result"] == true) {
        setState(() {
          statusMessage = "✅ Configuration réussie !";
          _isLoading = false;
        });
        _saveDevice(); // ✅ Enregistrer l'appareil automatiquement

        await Future.delayed(const Duration(seconds: 2));
        if (mounted) Navigator.pop(context, true);
      } else {
        setState(() {
          statusMessage = "❌ La configuration a échoué !";
          _isLoading = false;
        });
      }

    } catch (error) {
      print("❌ Erreur Dio : $error");
      setState(() {
        statusMessage = "❌ Erreur de connexion à l'ESP.";
        _isLoading = false;
      });
    }finally{
      dio.close(force: true);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Configuration WiFi")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isLoading) CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(statusMessage, textAlign: TextAlign.center),
            if (!_isLoading)
              Padding(
                padding: const EdgeInsets.only(top: 24.0),
                child: ElevatedButton(
                  child: const Text("Fermer"),
                  onPressed: () => Navigator.pop(context, false),
                ),
              )
          ],
        ),
      ),
    );
  }
}

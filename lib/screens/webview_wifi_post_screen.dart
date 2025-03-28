import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WebViewWifiPostScreen extends StatefulWidget {
  final String ssid;
  final String password;
  final String deviceId; // ✅ Ajout du Device ID

  const WebViewWifiPostScreen({
    required this.ssid,
    required this.password,
    required this.deviceId,
  });

  @override
  State<WebViewWifiPostScreen> createState() => _WebViewWifiPostScreenState();
}

class _WebViewWifiPostScreenState extends State<WebViewWifiPostScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _sendWifiConfig();
          },
        ),
      )
      ..loadHtmlString(_buildHtml());
  }

  /// 💾 **Sauvegarde de l'appareil sous "LIXEEGW-XXXX"**
  void _saveDevice() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> devices = prefs.getStringList('saved_devices') ?? [];

    String deviceName = "LIXEEGW-${widget.deviceId}|http://lixeegw-${widget.deviceId}.local"; // 🔥 Format unique !

    if (!devices.contains(deviceName)) {
      devices.add(deviceName);
      await prefs.setStringList('saved_devices', devices);
      print("✅ Appareil enregistré : $deviceName");
    } else {
      print("ℹ Appareil déjà enregistré !");
    }
  }

  /// 🔄 Envoi de la configuration WiFi à l'ESP
  void _sendWifiConfig() async {
    final dio = Dio();
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
        print("✅ Configuration réussie !");
        _saveDevice(); // ✅ Enregistrer l'appareil automatiquement

        if (mounted) {
          Navigator.pop(context, true); // 🔄 Retourne `true` à HomeScreen
        }
      } else {
        print("❌ La configuration a échoué !");
      }

    } catch (error) {
      print("❌ Erreur Dio : $error");
    }
  }

  /// 🖥 Génération du HTML pour WebView
  String _buildHtml() {
    return '''
      <!DOCTYPE html>
      <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
      </head>
      <body>
        <h2>🔧 Configuration en cours...</h2>
      </body>
      </html>
    ''';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Configuration de l'ESP")),
      body: WebViewWidget(controller: _controller),
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/proxy_server.dart';

class WebViewDeviceScreen extends StatefulWidget {
  final String deviceEntry;
  final String url;

  const WebViewDeviceScreen({
    required this.deviceEntry,
    required this.url,
  });

  @override
  _WebViewDeviceScreenState createState() => _WebViewDeviceScreenState();
}

class _WebViewDeviceScreenState extends State<WebViewDeviceScreen> {
  WebViewController? _controller;
  HttpServer? _proxyServer;

  bool _isLoading = true;
  bool _hasTriedAuth = false;
  bool _proxyReady = false;
  bool _isDisposed = false;

  late String name;
  String? login;
  String? password;

  @override
  void initState() {
    super.initState();

    final parts = widget.deviceEntry.split('|');
    name = parts[0];
    if (parts.length == 5 && parts[2] == 'auth') {
      login = parts[3];
      password = parts[4];
    }

    try {
      startProxy(
        targetBaseUrl: widget.url,
        username: login,
        password: password,
      ).then((server) {
        if (_isDisposed) {
          print("⚠️ Proxy démarré après fermeture : on ne fait rien");
          server.close(force: true);
          return;
        }

        _proxyServer = server;
        final proxyUrl = Uri.parse('http://127.0.0.1:8080/');
        final temp = WebViewController();

        temp
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setNavigationDelegate(
            NavigationDelegate(
              onPageStarted: (_) => setState(() => _isLoading = true),
              onPageFinished: (url) async {
                setState(() => _isLoading = false);

                if (_hasTriedAuth || login != null) return;

                try {
                  final titleRaw =
                  await temp.runJavaScriptReturningResult("document.title");
                  final title = titleRaw.toString().toLowerCase();
                  print("📄 Page title: $title");

                  final suspiciousKeywords = [
                    "unauthorized",
                    "forbidden",
                    "non disponible",
                    "not available",
                    "login",
                  ];

                  if (title.isEmpty || suspiciousKeywords.any((kw) => title.contains(kw))) {
                    print("⚠️ Authentification potentiellement requise (titre vide ou suspect)");
                    _hasTriedAuth = true;
                    await _askForAuthentication();
                  }
                } catch (e) {
                  print("⚠️ Erreur JS lors de l'analyse du titre : $e");
                  // 🔥 Si JavaScript échoue aussi ➔ supposer qu'auth nécessaire
                  if (!_hasTriedAuth && login == null) {
                    _hasTriedAuth = true;
                    await _askForAuthentication();
                  }
                }
              },
              onWebResourceError: (error) {
                print("❌ WebView error: ${error.errorCode} - ${error.description}");
              },
            ),
          )
          ..loadRequest(proxyUrl);

        // 🧙‍♂️ Anti écran noir : léger délai avant affichage du WebView
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!_isDisposed) {
            setState(() {
              _controller = temp;
              _proxyReady = true;
            });
          }
        });
      }).catchError((e) {
        print("❌ Échec du démarrage du proxy : $e");
        Navigator.of(context).pop();
      });
    } catch (e) {
      print("❌ Erreur inattendue au lancement du proxy : $e");
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _controller?.clearCache();
    _controller = null;
    _proxyServer?.close(force: true);
    print("🛑 Proxy arrêté (WebView fermée)");
    super.dispose();
  }


  Future<void> _askForAuthentication() async {
    String tempLogin = "";
    String tempPassword = "";
    bool obscure = true;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text("🔐 Authentification requise"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("Cette page nécessite un identifiant."),
                  SizedBox(height: 12),
                  TextField(
                    decoration: InputDecoration(labelText: "Login"),
                    onChanged: (val) => tempLogin = val,
                  ),
                  TextField(
                    obscureText: obscure,
                    onChanged: (val) => tempPassword = val,
                    decoration: InputDecoration(
                      labelText: "Mot de passe",
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscure ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () =>
                            setState(() => obscure = !obscure),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  child: Text("Annuler"),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                TextButton(
                  child: Text("Valider"),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            );
          },
        );
      },
    );

    if (tempLogin.isEmpty || tempPassword.isEmpty) return;

    final parts = widget.deviceEntry.split('|');
    if (parts.length >= 2) {
      final updatedEntry =
          "${parts[0]}|${parts[1]}|auth|$tempLogin|$tempPassword";

      final prefs = await SharedPreferences.getInstance();
      List<String> saved = prefs.getStringList('saved_devices') ?? [];

      saved.removeWhere((e) => e.startsWith("${parts[0]}|${parts[1]}"));
      saved.add(updatedEntry);
      await prefs.setStringList('saved_devices', saved);

      //Navigator.of(context).pop(); // Fermer WebView
      Navigator.of(context).pop(true); // Retour à HomeScreen
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              Text("🔗 $name"),
              if (login != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6.0),
                  child: Icon(Icons.lock_outline, size: 18),
                ),
            ],
          ),
          actions: [
            IconButton(
              icon: Icon(Icons.refresh),
              tooltip: "Rafraîchir",
              onPressed: () {
                if (_controller != null) {
                  _controller!.reload();
                }
              },
            ),
          ],
        ),
        body: !_proxyReady
            ? const Center(child: CircularProgressIndicator())
            : Stack(
          children: [
            WebViewWidget(controller: _controller!),
            if (_isLoading)
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}

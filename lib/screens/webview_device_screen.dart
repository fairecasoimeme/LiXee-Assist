import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/proxy_server.dart';

class WebViewDeviceScreen extends StatefulWidget {
  final String deviceEntry;
  final String url;

  const WebViewDeviceScreen({
    super.key,
    required this.deviceEntry,
    required this.url,
  });

  @override
  _WebViewDeviceScreenState createState() => _WebViewDeviceScreenState();
}

class _WebViewDeviceScreenState extends State<WebViewDeviceScreen> {
  InAppWebViewController? _controller;
  HttpServer? _proxyServer;
  bool isTVDevice = false;

  final FocusNode _focusNode = FocusNode(
    skipTraversal: true,
    canRequestFocus: true,
  );

  bool _isLoading = true;
  bool _hasTriedAuth = false;
  bool _proxyReady = false;
  bool _isDisposed = false;
  int _loadingProgress = 0;
  int _proxyPort = 0;

  late String name;
  String? login;
  String? password;

  double cursorX = 200;
  double cursorY = 200;
  final double step = 50;

  @override
  void initState() {
    super.initState();

    final parts = widget.deviceEntry.split('|');
    name = parts[0];
    if (parts.length == 5 && parts[2] == 'auth') {
      login = parts[3];
      password = parts[4];
    }
    _detectIfTV();
    _startProxyAndLoad();
  }

  void _detectIfTV() async {
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        final hasLeanback = info.systemFeatures.contains("android.software.leanback");
        if (mounted) {
          setState(() {
            isTVDevice = hasLeanback;
          });
        }
      }
    } catch (e) {
      print("⚠️ Impossible de déterminer si l'appareil est une TV : $e");
    }
  }

  void _startProxyAndLoad() async {
    try {
      final server = await startProxy(
        targetBaseUrl: widget.url,
        username: login,
        password: password,
      );

      if (_isDisposed) {
        server.close(force: true);
        return;
      }

      _proxyServer = server;
      _proxyPort = server.port;

      setState(() => _proxyReady = true);
    } catch (e) {
      print("❌ Erreur proxy : $e");
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _focusNode.dispose();
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

    // Sauvegarder les credentials
    final parts = widget.deviceEntry.split('|');
    if (parts.length >= 2) {
      final updatedEntry =
          "${parts[0]}|${parts[1]}|auth|$tempLogin|$tempPassword";

      final prefs = await SharedPreferences.getInstance();
      List<String> saved = prefs.getStringList('saved_devices') ?? [];

      saved.removeWhere((e) => e.startsWith("${parts[0]}|${parts[1]}"));
      saved.add(updatedEntry);
      await prefs.setStringList('saved_devices', saved);

      // Mettre à jour les credentials en mémoire
      login = tempLogin;
      password = tempPassword;

      // Arrêter l'ancien proxy
      _proxyServer?.close(force: true);

      if (mounted) {
        setState(() {
          _proxyReady = false;
          _isLoading = true;
          _loadingProgress = 0;
        });
      }

      // Relancer le proxy avec les nouveaux credentials
      _startProxyAndLoad();
    }
  }

  /*Future<void> _checkPageForAuth() async {
    try {
      final result = await _controller?.evaluateJavascript(source: "document.title");
      final title = result?.toString().toLowerCase() ?? "";
      print("📄 Page title: $title");

      final suspicious = ["unauthorized", "forbidden", "non disponible", "not available", "login"];

      if (title.isEmpty || suspicious.any((kw) => title.contains(kw))) {
        if (!_hasTriedAuth && login == null) {
          _hasTriedAuth = true;
          await _askForAuthentication();
        }
      }
    } catch (e) {
      print("⚠️ JS error: $e");
      if (!_hasTriedAuth && login == null) {
        _hasTriedAuth = true;
        await _askForAuthentication();
      }
    }
  }*/

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
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
              _controller?.reload();
            },
          ),
        ],
      ),
      body: SafeArea( // ✅ garde la zone sûre
        child: SizedBox.expand( // ✅ prend tout l’espace restant
          child: _proxyReady
              ? (isTVDevice ? _buildTVWebView() : _buildMobileWebView())
              : const Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }



  Widget _buildTVWebView() {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (KeyEvent event) async {
        if (event is KeyDownEvent) {
          final size = MediaQuery.of(context).size;
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            setState(() => cursorY = (cursorY - step).clamp(0, size.height));
          } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            setState(() => cursorY = (cursorY + step).clamp(0, size.height));
          } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            setState(() => cursorX = (cursorX - step).clamp(0, size.width));
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            setState(() => cursorX = (cursorX + step).clamp(0, size.width));
          } else if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            await _simulateClickAt(cursorX, cursorY);
          }
        }
      },
      child: Stack(
        children: [
          _buildInAppWebView(),
          if (_isLoading) _buildLoadingOverlay(),
          Positioned(
            left: cursorX - 8,
            top: cursorY - 8,
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.blue, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileWebView() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        FocusScope.of(context).requestFocus(FocusNode());
      },
      child: Stack(
        children: [
          _buildInAppWebView(),
          if (_isLoading) _buildLoadingOverlay(),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.white,
      child: Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1B75BC)),
          strokeWidth: 3,
        ),
      ),
    );
  }

  Widget _buildInAppWebView() {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri("http://127.0.0.1:$_proxyPort/")),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldOverrideUrlLoading: false,
        useHybridComposition: Platform.isAndroid,
        transparentBackground: false,
        cacheEnabled: true,
        domStorageEnabled: true,
        cacheMode: CacheMode.LOAD_DEFAULT,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
      },
      onLoadStart: (controller, url) {
        if (mounted) {
          setState(() {
            _isLoading = true;
            _loadingProgress = 0;
          });
        }
      },
      onProgressChanged: (controller, progress) {
        if (mounted) {
          setState(() => _loadingProgress = progress);
        }
      },
      onLoadStop: (controller, url) async {
        if (mounted) {
          setState(() => _isLoading = false);
        }
      },
      onReceivedHttpAuthRequest: (controller, challenge) async {
        // Fournir automatiquement les credentials si disponibles
        if (login != null && password != null) {
          print("🔐 Auth demandée par ${challenge.protectionSpace.host} → envoi credentials");
          return HttpAuthResponse(
            username: login!,
            password: password!,
            action: HttpAuthResponseAction.PROCEED,
          );
        }
        print("🔐 Auth demandée mais pas de credentials stockés");
        return HttpAuthResponse(action: HttpAuthResponseAction.CANCEL);
      },
      onLoadError: (controller, url, code, message) {
        print("❌ WebView error: $code - $message");
      },
      onLoadHttpError: (controller, url, statusCode, description) async {
        print("❌ Erreur HTTP $statusCode pour $url");

        // Ne pas demander l'auth si les credentials sont déjà configurés
        if ((statusCode == 401 || statusCode == 403) && !_hasTriedAuth && login == null) {
          _hasTriedAuth = true;
          await _askForAuthentication();
        }
      },

    );
  }

  Future<void> _simulateClickAt(double x, double y) async {
    try {
      await _controller?.evaluateJavascript(source: '''
        var el = document.elementFromPoint($x, $y);
        if (el) el.click();
      ''');
      print('✅ Clic simulé à ($x, $y)');
    } catch (e) {
      print('❌ Erreur clic JS: $e');
    }
  }
}

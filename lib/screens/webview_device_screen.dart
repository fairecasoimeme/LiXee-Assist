import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/proxy_server.dart';
import '../main.dart' show TVDetector;

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
  DateTime? _lastProxyRestart;

  late String name;
  String? login;
  String? password;

  // --- Curseur TV ---
  double cursorX = 200;
  double cursorY = 200;
  double _currentStep = 15; // Vitesse initiale (accélère si touche maintenue)
  DateTime? _lastKeyTime;
  bool _showClickFeedback = false;

  @override
  void initState() {
    super.initState();

    final parts = widget.deviceEntry.split('|');
    name = parts[0];
    if (parts.length == 5 && parts[2] == 'auth') {
      login = parts[3];
      password = parts[4];
    }
    _startProxyAndLoad();
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
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text("Cette page nécessite un identifiant."),
                    SizedBox(height: 12),
                    TextField(
                      decoration: InputDecoration(labelText: "Login"),
                      onChanged: (val) => tempLogin = val,
                      autofocus: true,
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


  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        // TV : pas d'AppBar (plein écran), le bouton Retour de la télécommande suffit
        appBar: TVDetector.isTV
            ? null
            : AppBar(
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
        body: SafeArea(
          child: SizedBox.expand(
            child: _proxyReady
                ? (TVDetector.isTV ? _buildTVWebView() : _buildMobileWebView())
                : const Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
    );
  }



  /// Calcule le step avec accélération : appuis rapides = mouvement plus grand.
  double _getAcceleratedStep() {
    final now = DateTime.now();
    if (_lastKeyTime != null && now.difference(_lastKeyTime!) < const Duration(milliseconds: 200)) {
      // Touche maintenue → accélérer (max 50px)
      _currentStep = (_currentStep + 5).clamp(15, 50);
    } else {
      // Nouvelle pression → reset
      _currentStep = 15;
    }
    _lastKeyTime = now;
    return _currentStep;
  }

  /// Scrolle la page web quand le curseur atteint les bords de l'écran.
  void _scrollWebViewIfNeeded(double step, String direction) {
    const edgeMargin = 60.0; // Zone de bord qui déclenche le scroll
    final size = MediaQuery.of(context).size;
    final scrollAmount = step * 2; // Scroll un peu plus que le mouvement curseur

    if (direction == 'up' && cursorY <= edgeMargin) {
      _controller?.evaluateJavascript(source: 'window.scrollBy(0, -$scrollAmount)');
    } else if (direction == 'down' && cursorY >= size.height - edgeMargin) {
      _controller?.evaluateJavascript(source: 'window.scrollBy(0, $scrollAmount)');
    } else if (direction == 'left' && cursorX <= edgeMargin) {
      _controller?.evaluateJavascript(source: 'window.scrollBy(-$scrollAmount, 0)');
    } else if (direction == 'right' && cursorX >= size.width - edgeMargin) {
      _controller?.evaluateJavascript(source: 'window.scrollBy($scrollAmount, 0)');
    }
  }

  Widget _buildTVWebView() {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (KeyEvent event) async {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          final size = MediaQuery.of(context).size;
          final step = _getAcceleratedStep();
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            setState(() => cursorY = (cursorY - step).clamp(0, size.height));
            _scrollWebViewIfNeeded(step, 'up');
          } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            setState(() => cursorY = (cursorY + step).clamp(0, size.height));
            _scrollWebViewIfNeeded(step, 'down');
          } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            setState(() => cursorX = (cursorX - step).clamp(0, size.width));
            _scrollWebViewIfNeeded(step, 'left');
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            setState(() => cursorX = (cursorX + step).clamp(0, size.width));
            _scrollWebViewIfNeeded(step, 'right');
          } else if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            // Retour visuel au clic
            setState(() => _showClickFeedback = true);
            await _simulateClickAt(cursorX, cursorY);
            await Future.delayed(const Duration(milliseconds: 200));
            if (mounted) setState(() => _showClickFeedback = false);
          }
        }
      },
      child: Stack(
        children: [
          _buildInAppWebView(),
          if (_isLoading) _buildLoadingOverlay(),
          // Curseur TV (plus grand, avec ombre et feedback de clic)
          Positioned(
            left: cursorX - 12,
            top: cursorY - 12,
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                width: _showClickFeedback ? 32 : 24,
                height: _showClickFeedback ? 32 : 24,
                transform: _showClickFeedback
                    ? (Matrix4.identity()..translate(-4.0, -4.0))
                    : Matrix4.identity(),
                decoration: BoxDecoration(
                  color: _showClickFeedback
                      ? Colors.blue.withOpacity(0.5)
                      : Colors.white.withOpacity(0.9),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _showClickFeedback ? Colors.white : const Color(0xFF1B75BC),
                    width: 2.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
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

        // TV : zoom à 60% pour afficher plus de contenu sur grand écran
        if (TVDetector.isTV) {
          await controller.evaluateJavascript(
            source: "document.body.style.zoom = '60%';",
          );
        }

        // Détecter si la page de login ESP32 s'affiche dans la WebView
        final hasLoginForm = await controller.evaluateJavascript(
          source: "document.querySelector('form[action=\"/login\"]') !== null",
        );
        if (hasLoginForm == true || hasLoginForm == 'true') {
          if (login != null && password != null) {
            // Cooldown : éviter les boucles de redémarrage du proxy (10s minimum)
            final now = DateTime.now();
            if (_lastProxyRestart != null && now.difference(_lastProxyRestart!) < const Duration(seconds: 10)) {
              return;
            }
            _lastProxyRestart = now;
            // Credentials déjà sauvegardés mais session expirée : relancer le proxy
            _proxyServer?.close(force: true);
            if (mounted) {
              setState(() {
                _proxyReady = false;
                _isLoading = true;
                _loadingProgress = 0;
              });
            }
            _startProxyAndLoad();
          } else if (!_hasTriedAuth) {
            // Pas de credentials : afficher le dialog d'auth LiXee-Assist
            _hasTriedAuth = true;
            await _askForAuthentication();
          }
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

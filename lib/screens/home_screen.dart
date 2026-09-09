import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ble_provision_screen.dart'; // ✅ Changement: import du BLE au lieu de WiFi
import 'webview_device_screen.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:io';
import 'dart:convert'; // ✅ permet d'utiliser base64Encode et utf8
import 'package:dio/dio.dart';
import 'about_screen.dart';
import '../services/session_manager.dart';
import '../services/session_pool.dart';
import 'package:home_widget/home_widget.dart';
import '../main.dart' show TVDetector;

// ✅ Instance globale des notifications - référence celle du main.dart
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

bool isTV(BuildContext context) {
  return MediaQuery.of(context).size.width > 720;
}

/// 📌 Vérifie si l'URL est une adresse IP
bool isIPAddress(String url) {
  final ipv4Pattern = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
  final ipv6Pattern = RegExp(r'^[0-9a-fA-F:]+$');

  try {
    // 🔍 Extraire ce qui est entre http(s):// et le port (ou le /)
    Uri uri = Uri.parse(url);
    String host = uri.host;

    return ipv4Pattern.hasMatch(host) || ipv6Pattern.hasMatch(host);
  } catch (e) {
    print("❌ Erreur lors de la validation IP : $e");
    return false;
  }
}

/// 📌 Vérifie si l'URL est un nom .local (mDNS)
bool isLocalDomain(String url) {
  try {
    Uri uri = Uri.parse(url);
    return uri.host.endsWith('.local');
  } catch (e) {
    return url.toLowerCase().contains('.local');
  }
}

/// 📌 Vérifie si l'URL est un nom DNS classique
bool isDNSName(String url) {
  try {
    Uri uri = Uri.parse(url);
    String host = uri.host;

    // Pas une IP, pas un .local, et contient au moins un point
    return !isIPAddress(url) &&
        !isLocalDomain(url) &&
        host.contains('.') &&
        !host.startsWith('localhost');
  } catch (e) {
    return false;
  }
}

class UniversalResolver {
  static final Map<String, String> _dnsCache = {};
  static final Map<String, DateTime> _cacheTimestamps = {};
  static const Duration _cacheExpiration = Duration(minutes: 5);

  /// ✅ CORRECTION: Utiliser une clé unique incluant deviceName + URL
  static String _getCacheKey(String address, String? deviceName) {
    return "${deviceName ?? 'unknown'}::$address";
  }

  /// Résout uniquement les adresses qui nécessitent une résolution (IP et mDNS)
  /// Pour les DNS classiques, retourne l'URL originale
  static Future<String?> resolveAddress(String address, {String? deviceName}) async {
    print("🔍 Analyse de l'adresse: $address");

    // Nettoyage du cache expiré
    _cleanExpiredCache();

    String addressType = _getUrlType(address);
    print("📋 Type détecté: $addressType");

    if (isDNSName(address)) {
      // Pour les DNS classiques, on retourne l'adresse originale
      print("🌐 DNS classique détecté - utilisation directe: $address");
      return address;
    }

    // ✅ CORRECTION: Utiliser une clé de cache unique par device
    String cacheKey = _getCacheKey(address, deviceName);
    if (_dnsCache.containsKey(cacheKey)) {
      print("📋 Cache utilisé pour ${deviceName}: $address -> ${_dnsCache[cacheKey]}");
      return _dnsCache[cacheKey];
    }

    String? resolvedAddress;

    if (isIPAddress(address)) {
      print("📍 IP détectée pour ${deviceName}: $address");
      Uri uri = Uri.parse(address.startsWith('http') ? address : 'http://$address');
      // ✅ CORRECTION: Retourner l'URL complète, pas juste l'host
      resolvedAddress = address.startsWith('http') ? address : 'http://$address';

    } else if (isLocalDomain(address)) {
      String hostname = Uri.parse(address.startsWith('http') ? address : 'http://$address').host.replaceAll('.local', '');
      print("🏠 mDNS détecté pour ${deviceName}: $address (hostname: $hostname)");
      String? mdnsResult = await resolveMdnsIP(hostname);
      if (mdnsResult != null) {
        resolvedAddress = mdnsResult.startsWith('http') ? mdnsResult : 'http://$mdnsResult';
      }
    }

    // Mise en cache si succès (uniquement pour IP et mDNS)
    if (resolvedAddress != null) {
      _dnsCache[cacheKey] = resolvedAddress;
      _cacheTimestamps[cacheKey] = DateTime.now();
      print("✅ Résolution réussie pour ${deviceName}: $address -> $resolvedAddress");
    } else {
      print("❌ Échec résolution pour ${deviceName}: $address");
    }

    return resolvedAddress;
  }

  /// Nettoie les entrées expirées du cache
  static void _cleanExpiredCache() {
    final now = DateTime.now();
    final expiredKeys = <String>[];

    _cacheTimestamps.forEach((key, timestamp) {
      if (now.difference(timestamp) > _cacheExpiration) {
        expiredKeys.add(key);
      }
    });

    for (String key in expiredKeys) {
      _dnsCache.remove(key);
      _cacheTimestamps.remove(key);
      print("🗑️ Cache expiré supprimé: $key");
    }
  }

  /// Vide complètement le cache
  static void clearCache() {
    _dnsCache.clear();
    _cacheTimestamps.clear();
    print("🗑️ Cache DNS vidé");
  }
}

/// Helper pour identifier le type d'URL
String _getUrlType(String url) {
  if (isIPAddress(url)) return "IP";
  if (isLocalDomain(url)) return "mDNS (.local)";
  if (isDNSName(url)) return "DNS";
  return "Inconnu";
}

/// 🔍 Normalise une URL pour les requêtes HTTP
String _normalizeUrl(String address) {
  if (address.startsWith('http://') || address.startsWith('https://')) {
    return address;
  }
  return 'http://$address';
}

/// Parse un device entry et retourne ses composants.
/// Formats supportés :
///   name|url                              (2 parts)
///   name|url|fallbackUrl                  (3 parts, parts[2] != 'auth')
///   name|url|auth|login|password          (5 parts)
///   name|url|auth|login|password|fallbackUrl (6 parts)
Map<String, String>? _parseDeviceEntry(String entry) {
  final parts = entry.split('|');
  if (parts.length < 2) return null;

  final result = <String, String>{
    'name': parts[0],
    'url': parts[1],
  };

  if (parts.length == 3 && parts[2] != 'auth') {
    result['fallback'] = parts[2];
  } else if (parts.length == 5 && parts[2] == 'auth') {
    result['login'] = parts[3];
    result['password'] = parts[4];
  } else if (parts.length == 6 && parts[2] == 'auth') {
    result['login'] = parts[3];
    result['password'] = parts[4];
    result['fallback'] = parts[5];
  } else if (parts.length != 2) {
    return null;
  }

  return result;
}

/// Construit un device entry à partir de ses composants.
String _buildDeviceEntry({
  required String name,
  required String url,
  String? login,
  String? password,
  String? fallback,
}) {
  String entry = '$name|$url';
  if (login != null && login.isNotEmpty && password != null && password.isNotEmpty) {
    entry += '|auth|$login|$password';
  }
  if (fallback != null && fallback.isNotEmpty) {
    // Si pas d'auth, ajouter directement le fallback en 3ème position
    if (login == null || login.isEmpty) {
      entry = '$name|$url|$fallback';
    } else {
      entry += '|$fallback';
    }
  }
  return entry;
}

Future<List<String>> _getNotifications(String deviceName) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getStringList('notifications_$deviceName') ?? [];
}

/// 🔍 mDNS lookup avec fallback iOS
Future<String?> resolveMdnsIP(String deviceName) async {
  print("🔍 Tentative de résolution mDNS pour: $deviceName");

  // Détection de la plateforme
  if (Platform.isIOS) {
    print("🍎 iOS détecté - Utilisation de méthodes alternatives");
    return await _resolveMdnsIOS(deviceName);
  } else {
    print("🤖 Android détecté - Utilisation mDNS standard");
    return await _resolveMdnsAndroid(deviceName);
  }
}

/// 🍎 Résolution mDNS spécifique iOS avec fallbacks multiples
Future<String?> _resolveMdnsIOS(String deviceName) async {
  print("🍎 Résolution iOS pour: $deviceName");

  // Méthode 1: Test direct avec .local
  String? ip = await _testDirectConnection(deviceName);
  if (ip != null) {
    print("✅ Résolution directe réussie: $ip");
    return ip;
  }

  // Méthode 2: Scan réseau local
  ip = await _scanLocalNetwork(deviceName);
  if (ip != null) {
    print("✅ Scan réseau réussi: $ip");
    return ip;
  }

  // Méthode 3: mDNS avec gestion d'erreur iOS
  ip = await _tryMdnsWithFallback(deviceName);
  if (ip != null) {
    print("✅ mDNS fallback réussi: $ip");
    return ip;
  }

  print("❌ Toutes les méthodes iOS ont échoué pour: $deviceName");
  return null;
}

/// 🤖 Résolution mDNS standard Android (code original)
Future<String?> _resolveMdnsAndroid(String deviceName) async {
  final client = MDnsClient(
    rawDatagramSocketFactory: (
        host,
        int port, {
          bool reuseAddress = true,
          bool reusePort = false,
          int ttl=255,
        }) {
      return RawDatagramSocket.bind(
        host,
        port,
        reuseAddress: reuseAddress,
        reusePort: false,
      );
    },
  );

  try {
    await client.start();
    print("🔍 Recherche mDNS Android `_http._tcp.local`...");

    await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('_http._tcp.local'),
    )) {
      String serviceName = ptr.domainName.split("._http._tcp.local").first;
      if (serviceName.toLowerCase().trim() == deviceName.toLowerCase().trim()) {
        await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
        )) {
          await for (final IPAddressResourceRecord ip in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
          )) {
            client.stop();
            return ip.address.address;
          }
        }
      }
    }
  } catch (e) {
    print("❌ Erreur mDNS Android : $e");
  } finally {
    client.stop();
  }
  return null;
}

/// 🔗 Test de connexion directe avec .local
Future<String?> _testDirectConnection(String deviceName) async {
  try {
    print("🔗 Test connexion directe: $deviceName.local");

    final dio = Dio();
    dio.options.connectTimeout = Duration(seconds: 3);
    dio.options.receiveTimeout = Duration(seconds: 3);

    // Essayer de se connecter directement
    final response = await dio.get('http://$deviceName.local/poll');

    if (response.statusCode == 200) {
      print("✅ Connexion directe réussie à $deviceName.local");
      // Retourner l'URL complète plutôt que l'IP
      return "$deviceName.local";
    }
  } catch (e) {
    print("❌ Connexion directe échouée: $e");
  }

  return null;
}

/// 🌐 Scan du réseau local pour trouver l'appareil
Future<String?> _scanLocalNetwork(String deviceName) async {
  try {
    print("🌐 Scan réseau local pour: $deviceName");

    // Obtenir l'IP locale de l'appareil
    String? localIP = await _getLocalIP();
    if (localIP == null) {
      print("❌ Impossible d'obtenir l'IP locale");
      return null;
    }

    print("📱 IP locale: $localIP");

    // Extraire le réseau (ex: 192.168.1.xxx)
    List<String> parts = localIP.split('.');
    if (parts.length != 4) return null;

    String networkBase = "${parts[0]}.${parts[1]}.${parts[2]}";
    print("🌐 Scan du réseau: $networkBase.xxx");

    // Scanner les IPs du réseau local (limité pour ne pas être trop long)
    List<Future<String?>> futures = [];
    for (int i = 1; i < 255; i++) {
      String testIP = "$networkBase.$i";
      futures.add(_testDeviceAtIP(testIP, deviceName));
    }

    // Attendre les résultats avec timeout
    List<String?> results = await Future.wait(futures).timeout(
      Duration(seconds: 10),
      onTimeout: () => List.filled(254, null),
    );

    for (String? result in results) {
      if (result != null) {
        print("✅ Appareil trouvé à: $result");
        return result;
      }
    }

  } catch (e) {
    print("❌ Erreur scan réseau: $e");
  }

  return null;
}

/// 📱 Obtenir l'IP locale de l'appareil
Future<String?> _getLocalIP() async {
  try {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          String ip = addr.address;
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
            return ip;
          }
        }
      }
    }
  } catch (e) {
    print("❌ Erreur obtention IP locale: $e");
  }
  return null;
}

/// 🔍 Tester si un appareil LIXEE est à une IP donnée
Future<String?> _testDeviceAtIP(String ip, String deviceName) async {
  try {
    final dio = Dio();
    dio.options.connectTimeout = Duration(milliseconds: 1000);
    dio.options.receiveTimeout = Duration(milliseconds: 1000);

    final response = await dio.get('http://$ip/poll');

    if (response.statusCode == 200) {
      // Vérifier si c'est bien notre appareil
      try {
        final data = jsonDecode(response.data);
        if (data != null && data.toString().contains(deviceName)) {
          return ip;
        }
      } catch (_) {
        // Si ce n'est pas du JSON, vérifier la réponse brute
        if (response.data.toString().toLowerCase().contains(deviceName.toLowerCase())) {
          return ip;
        }
      }
    }
  } catch (e) {
    // Échec silencieux pour le scan
  }

  return null;
}

/// 🔄 mDNS avec gestion spéciale des erreurs iOS
Future<String?> _tryMdnsWithFallback(String deviceName) async {
  try {
    print("🔄 Tentative mDNS avec fallback iOS");

    // Configuration spéciale pour iOS
    final client = MDnsClient(
      rawDatagramSocketFactory: (host, int port, {
        bool reuseAddress = true,
        bool reusePort = false,
        int ttl = 255,
      }) async {
        try {
          // Essayer d'abord avec un port aléatoire
          return await RawDatagramSocket.bind(
            host,
            0, // Port automatique
            reuseAddress: false,
            reusePort: false,
          );
        } catch (e) {
          print("⚠️ Bind sur port auto échoué, essai port standard: $e");
          // Fallback sur port standard avec gestion d'erreur
          return await RawDatagramSocket.bind(
            host,
            port,
            reuseAddress: true,
            reusePort: false,
          );
        }
      },
    );

    await client.start();

    // Timeout plus court pour iOS
    final completer = Completer<String?>();
    late Timer timeoutTimer;

    timeoutTimer = Timer(Duration(seconds: 5), () {
      if (!completer.isCompleted) {
        completer.complete(null);
        client.stop();
      }
    });

    client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('_http._tcp.local'),
    ).listen((ptr) async {
      if (completer.isCompleted) return;

      String serviceName = ptr.domainName.split("._http._tcp.local").first;
      if (serviceName.toLowerCase().trim() == deviceName.toLowerCase().trim()) {
        await for (final srv in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
        )) {
          await for (final ip in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
          )) {
            if (!completer.isCompleted) {
              timeoutTimer.cancel();
              completer.complete(ip.address.address);
              client.stop();
              return;
            }
          }
        }
      }
    });

    return await completer.future;

  } catch (e) {
    print("❌ mDNS fallback iOS échoué: $e");
    return null;
  }
}

// Modification de _resetDeviceConfig
Future<bool> _resetDeviceConfig(String name, String url) async {
  try {
    String finalUrl;

    if (isDNSName(url)) {
      // DNS classique : utilisation directe
      finalUrl = _normalizeUrl(url);
      print("🌐 Reset via DNS direct: $finalUrl");

    } else {
      // IP ou mDNS : résolution si nécessaire
      String? resolvedAddress;

      if (isIPAddress(url)) {
        resolvedAddress = url;
      } else {
        resolvedAddress = await UniversalResolver.resolveAddress(url, deviceName: name);
        if (resolvedAddress == null) {
          print("❌ Impossible de résoudre l'adresse: $url");
          return false;
        }
      }

      finalUrl = _normalizeUrl(resolvedAddress);
    }

    final dio = Dio();
    String resetUrl = "$finalUrl/setResetDevice";

    print("🔧 Envoi de la requête de reset vers $resetUrl...");
    final response = await dio.post(resetUrl);

    if (response.statusCode == 200) {
      print("✅ Appareil réinitialisé avec succès !");
      return true;
    } else {
      print("⚠ Réinitialisation échouée : ${response.statusCode}");
      return false;
    }
  } catch (e) {
    print("❌ Erreur lors de la réinitialisation de l'appareil : $e");
    return false;
  }
}

Future<void> saveNotification(String deviceName,String timestamp, String title, String message) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  String key = 'notifications_$deviceName';

  List<String> existing = prefs.getStringList(key) ?? [];

  // ✅ Vérifier si la notification existe déjà pour éviter les doublons
  final entry = "$timestamp|$title|$message";
  if (!existing.contains(entry)) {
    existing.add(entry);
    await prefs.setStringList(key, existing);
    print("✅ Notification sauvegardée pour $deviceName : $title");
  }
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<String> devices = [];
  Timer? _refreshTimer;
  Map<String, bool> deviceStatuses = {};
  Map<String, bool> deviceOnFallback = {}; // true si le polling utilise le fallback
  bool _initialized = false;

  StreamSubscription<Uri?>? _widgetClicks;

  /// Évite d'empiler deux WebViews : au démarrage à froid, le clic peut
  /// arriver à la fois par l'URI initiale et par le flux.
  bool _openingFromWidget = false;

  /// Box demandée par un widget, le temps d'en résoudre l'URL.
  String? _pendingWidgetDevice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDevices();
    _startAutoRefresh();
    _listenForWidgetLaunch();
  }

  /// Ouvre directement la box choisie quand l'app est lancée depuis un widget.
  ///
  /// Sans cela l'appui retombait sur la liste des box, alors que le widget
  /// désigne déjà la sienne : son nom voyage dans l'URI du PendingIntent, il
  /// suffisait de la consommer.
  void _listenForWidgetLaunch() {
    // Deux sources : l'app démarrée à froid par le widget, et le clic reçu
    // alors qu'elle tournait déjà.
    HomeWidget.initiallyLaunchedFromHomeWidget().then(_openFromWidget);
    _widgetClicks = HomeWidget.widgetClicked.listen(_openFromWidget);
  }

  Future<void> _openFromWidget(Uri? uri) async {
    if (uri == null || uri.host != 'open') return;
    if (_openingFromWidget) return;

    final name = uri.pathSegments.isEmpty
        ? ''
        : Uri.decodeComponent(uri.pathSegments.first);
    if (name.isEmpty || name == 'unconfigured') return;

    _openingFromWidget = true;
    if (mounted) setState(() => _pendingWidgetDevice = name);
    try {
      // Relu depuis les préférences plutôt que de la liste en mémoire : au
      // démarrage à froid, celle-ci n'est pas encore chargée.
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final entry = (prefs.getStringList('saved_devices') ?? []).firstWhere(
        (e) => e.split('|').first == name,
        orElse: () => '',
      );
      if (entry.isEmpty) {
        print('[WIDGET] Box « $name » introuvable, on reste sur la liste');
        return;
      }

      // La confirmation a déjà eu lieu côté natif, avant même que l'app ne
      // démarre : arriver ici veut dire que l'utilisateur a accepté.
      if (!mounted) return;
      await _openDevice(entry);
    } finally {
      _openingFromWidget = false;
      if (mounted) setState(() => _pendingWidgetDevice = null);
    }
  }

  /// Écran d'attente pendant qu'on résout l'URL de la box demandée.
  Widget _buildWidgetLaunchScreen(String name) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/logo.png', height: 72),
              const SizedBox(height: 24),
              Text(
                name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 20),
              const CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1B75BC)),
                strokeWidth: 3,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (!_initialized) {
      final shouldReset = ModalRoute.of(context)?.settings.arguments == true;
      if (shouldReset) {
        _resetStateAfterProvisioning();
      }
      _initialized = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // App en arrière-plan : arrêter le polling
      _refreshTimer?.cancel();
      _refreshTimer = null;
    } else if (state == AppLifecycleState.resumed) {
      // App revenue au premier plan : relancer le polling et rafraîchir
      _loadDevices();
      _startAutoRefresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _widgetClicks?.cancel();
    // Les sessions appartiennent à SessionPool et sont partagées avec le
    // relevé des métriques : cet écran n'a pas à les fermer.
    super.dispose();
  }

  /// Effectue un poll HTTP sur une URL donnée. Retourne (statusCode, body) ou null si échec.
  Future<({int statusCode, String body})?> _pollUrl(String finalUrl, String deviceName, {String? login, String? password}) async {
    try {
      int statusCode;
      String responseBody;

      if (login != null && password != null) {
        var authMode = await SessionPool.authMode(finalUrl);

        if (authMode == AuthMode.form) {
          final sm = SessionPool.session(finalUrl, login, password);
          if (sm.sessionCookie == null) {
            final loginOk = await sm.login();
            if (!loginOk) {
              print('[HOME] Form login failed for $deviceName, fallback to Basic Auth');
              SessionPool.invalidate(finalUrl, login);
              SessionPool.setAuthMode(finalUrl, AuthMode.basic);
              authMode = AuthMode.basic;
            }
          }
        }

        if (authMode == AuthMode.form) {
          final result = await SessionPool.session(finalUrl, login, password)
              .authenticatedGet('/poll');
          statusCode = result.statusCode;
          responseBody = result.body;
        } else {
          final dio = Dio();
          dio.options.connectTimeout = const Duration(seconds: 5);
          try {
            final response = await dio.get(
              "$finalUrl/poll",
              options: Options(
                sendTimeout: const Duration(seconds: 2),
                receiveTimeout: const Duration(seconds: 5),
                responseType: ResponseType.plain,
                validateStatus: (status) => status == 200 || status == 401,
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
        final dio = Dio();
        dio.options.connectTimeout = const Duration(seconds: 5);
        try {
          final response = await dio.get(
            "$finalUrl/poll",
            options: Options(
              sendTimeout: const Duration(seconds: 2),
              receiveTimeout: const Duration(seconds: 5),
              responseType: ResponseType.plain,
              validateStatus: (status) => status == 200 || status == 401,
            ),
          );
          statusCode = response.statusCode ?? 0;
          responseBody = response.data?.toString() ?? '';
        } finally {
          dio.close(force: true);
        }
      }

      if (statusCode == 200 || statusCode == 401) {
        return (statusCode: statusCode, body: responseBody);
      }
    } catch (e) {
      print('[POLL] Echec pour $finalUrl: $e');
    }
    return null;
  }

  // Modification de la fonction checkDeviceStatus existante
  void checkDeviceStatus(String deviceName, String url, String entryKey, {String? login, String? password, String? fallbackUrl}) async {
    print("🔍 Vérification de l'état de l'appareil : $deviceName");

    // Construire la liste des URLs à essayer (primaire + fallback)
    final urlCandidates = [url];
    if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
      urlCandidates.add(fallbackUrl);
    }

    // Essayer chaque URL : résoudre puis poll
    ({int statusCode, String body})? pollResult;
    bool usedFallback = false;
    for (int i = 0; i < urlCandidates.length; i++) {
      final candidate = urlCandidates[i];
      final resolved = await _resolveToFinalUrl(candidate, deviceName);
      if (resolved == null) {
        print("❌ Impossible de résoudre: $candidate, essai suivant...");
        continue;
      }

      pollResult = await _pollUrl(resolved, deviceName, login: login, password: password);
      if (pollResult != null) {
        usedFallback = i > 0;
        print("✅ Poll OK sur $resolved (status=${pollResult.statusCode}) ${usedFallback ? '(FALLBACK)' : '(PRIMAIRE)'}");
        break;
      }
      print("❌ Poll échoué sur $resolved, essai suivant...");
    }

    if (pollResult == null) {
      print("❌ Aucune URL joignable pour $deviceName");
      if (mounted) {
        setState(() {
          deviceStatuses[entryKey] = false;
        });
      }
      return;
    }

    // Mettre à jour le statut fallback pour l'affichage du badge
    if (mounted && fallbackUrl != null && fallbackUrl.isNotEmpty) {
      setState(() {
        deviceOnFallback[entryKey] = usedFallback;
      });
    }

    // Traitement de la réponse
    try {
      final statusCode = pollResult.statusCode;
      final responseBody = pollResult.body;

      if (statusCode == 200 || statusCode == 401) {
        // Traitement des notifications
        if (responseBody.trim().isNotEmpty) {
          try {
            final jsonData = jsonDecode(responseBody);

            if (jsonData != null && jsonData['notifications'] != null) {
              List<dynamic> notifications = jsonData['notifications'];

              for (int i = 0; i < notifications.length; i++) {
                var notif = notifications[i];

                if (notif != null && notif['title'] != null && notif['timeStamp'] != null) {
                  var title = "";
                  int notifType = notif['type'] ?? 0;

                  switch (notifType) {
                    case 1:
                      title = "❌ $deviceName - ${notif['title']}";
                      break;
                    case 2:
                      title = "⚠️ $deviceName - ${notif['title']}";
                      break;
                    case 3:
                      title = "📋 $deviceName - ${notif['title']}";
                      break;
                    default:
                      title = "$deviceName - ${notif['title']}";
                  }

                  await saveNotification(
                      deviceName,
                      notif['timeStamp'].toString(),
                      title,
                      notif['message']?.toString() ?? ''
                  );

                  if (mounted) {
                    try {
                      await flutterLocalNotificationsPlugin.show(
                        DateTime.now().millisecondsSinceEpoch ~/ 1000 + i,
                        title,
                        notif['message']?.toString() ?? '',
                        const NotificationDetails(
                          android: AndroidNotificationDetails(
                            'lixee_channel_id',
                            'Lixee Notifications',
                            importance: Importance.defaultImportance,
                            priority: Priority.defaultPriority,
                            styleInformation: BigTextStyleInformation(''),
                          ),
                        ),
                      );
                    } catch (_) {}
                  }
                }
              }
            }
          } catch (_) {}
        }

        if (mounted) {
          setState(() {
            deviceStatuses[entryKey] = true;
          });
        }
      }
    } catch (e) {
      print('[STATUS] Erreur traitement réponse pour $deviceName: $e');
      if (mounted) {
        setState(() {
          deviceStatuses[entryKey] = false;
        });
      }
    }
  }

  /// Helper pour identifier le type d'URL
  String _getUrlType(String url) {
    if (isIPAddress(url)) return "IP";
    if (isLocalDomain(url)) return "mDNS (.local)";
    if (isDNSName(url)) return "DNS";
    return "Inconnu";
  }

  Future<void> _resetStateAfterProvisioning() async {
    print("♻️ Réinitialisation post-provisioning BLE..."); // ✅ Changement: message BLE
    setState(() {
      devices.clear();
      deviceStatuses.clear();
    });
    await Future.delayed(Duration(milliseconds: 500));
    _loadDevices(); // recharge avec sockets neufs
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(Duration(seconds: 10), (timer) {
      for (int i = 0; i < devices.length; i++) {
        final parsed = _parseDeviceEntry(devices[i]);
        if (parsed != null) {
          checkDeviceStatus(parsed['name']!, parsed['url']!, devices[i],
              login: parsed['login'], password: parsed['password'], fallbackUrl: parsed['fallback']);
        }
      }
    });
  }

  void _loadDevices() async {
    print("🔍 === DEBUT _loadDevices ===");

    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> rawDevices = prefs.getStringList('saved_devices') ?? [];

    print("📋 ${rawDevices.length} devices dans SharedPreferences:");
    for (int i = 0; i < rawDevices.length; i++) {
      print("   [$i] '${rawDevices[i]}'");
    }

    List<String> validDevices = [];

    for (var entry in rawDevices) {
      List<String> parts = entry.split('|');
      if (parts.length == 2) {
        validDevices.add(entry);
        print("✅ Device sans auth: '${parts[0]}' -> '${parts[1]}'");
      } else if (parts.length == 3 && parts[2] != 'auth') {
        validDevices.add(entry);
        print("✅ Device sans auth + fallback: '${parts[0]}' -> '${parts[1]}' (fallback: '${parts[2]}')");
      } else if (parts.length == 5 && parts[2] == 'auth') {
        validDevices.add(entry);
        print("🔐 Device avec auth: '${parts[0]}' -> '${parts[1]}' (login: '${parts[3]}')");
      } else if (parts.length == 6 && parts[2] == 'auth') {
        validDevices.add(entry);
        print("🔐 Device avec auth + fallback: '${parts[0]}' -> '${parts[1]}' (fallback: '${parts[5]}')");
      } else {
        print("⚠️ Format invalide ignoré: '$entry'");
      }
    }

    setState(() {
      devices = validDevices;
    });

    print("📋 ${validDevices.length} devices valides chargés");
    print("🔍 === FIN _loadDevices ===");

    // Vérification des statuts
    for (int i = 0; i < validDevices.length; i++) {
      final parsed = _parseDeviceEntry(validDevices[i]);
      if (parsed != null) {
        checkDeviceStatus(parsed['name']!, parsed['url']!, validDevices[i],
            login: parsed['login'], password: parsed['password'], fallbackUrl: parsed['fallback']);
      }
    }
  }

  void _showEditDialog(String originalEntry) {
    print("🔧 _showEditDialog pour: '$originalEntry'");

    final parsed = _parseDeviceEntry(originalEntry);
    if (parsed == null) return;

    String name = parsed['name']!;
    String url = parsed['url']!;
    String fallback = parsed['fallback'] ?? '';
    bool useAuth = parsed.containsKey('login');
    String login = parsed['login'] ?? '';
    String password = parsed['password'] ?? '';

    bool obscurePassword = true;

    TextEditingController nameController = TextEditingController(text: name);
    TextEditingController urlController = TextEditingController(text: url);
    TextEditingController fallbackController = TextEditingController(text: fallback);
    TextEditingController loginController = TextEditingController(text: login);
    TextEditingController passwordController = TextEditingController(text: password);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Row(
                children: [
                  Image.asset("assets/logo_x.png", height: 32),
                  SizedBox(width: 8),
                  Expanded(child: Text("Modifier $name")),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: InputDecoration(labelText: "Nom"),
                      autofocus: true,
                    ),
                    TextField(
                      controller: urlController,
                      decoration: InputDecoration(
                        labelText: "URL principale",
                        hintText: "ex: https://abc123.lixee-box.fr",
                      ),
                    ),
                    TextField(
                      controller: fallbackController,
                      decoration: InputDecoration(
                        labelText: "URL secondaire (fallback)",
                        hintText: "ex: http://192.168.0.144",
                      ),
                    ),
                    CheckboxListTile(
                      value: useAuth,
                      title: Text("Utiliser l'authentification"),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (val) {
                        setState(() => useAuth = val ?? false);
                      },
                    ),
                    if (useAuth) ...[
                      TextField(
                        controller: loginController,
                        decoration: InputDecoration(labelText: "Login"),
                      ),
                      TextField(
                        controller: passwordController,
                        obscureText: obscurePassword,
                        decoration: InputDecoration(
                          labelText: "Mot de passe",
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscurePassword ? Icons.visibility_off : Icons.visibility,
                            ),
                            onPressed: () {
                              setState(() => obscurePassword = !obscurePassword);
                            },
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                OutlinedButton.icon(
                  icon: Icon(Icons.cancel),
                  label: Text("Annuler"),
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Color(0xFF1B75BC),
                    side: BorderSide(color: Color(0xFF1B75BC)),
                  ),
                ),
                OutlinedButton.icon(
                  icon: Icon(Icons.save_outlined),
                  label: Text("Modifier"),
                  onPressed: () async {
                    String newName = nameController.text.trim();
                    String newUrl = urlController.text.trim();
                    String newFallback = fallbackController.text.trim();
                    String newLogin = loginController.text.trim();
                    String newPass = passwordController.text.trim();

                    if (newName.isEmpty || newUrl.isEmpty) {
                      print("❌ Nom ou URL vide !");
                      return;
                    }

                    String newEntry = _buildDeviceEntry(
                      name: newName,
                      url: newUrl,
                      login: useAuth ? newLogin : null,
                      password: useAuth ? newPass : null,
                      fallback: newFallback,
                    );

                    print("🔧 Modification: '$originalEntry' -> '$newEntry'");

                    SharedPreferences prefs = await SharedPreferences.getInstance();
                    List<String> saved = prefs.getStringList('saved_devices') ?? [];

                    bool removed = saved.remove(originalEntry);
                    print("🗑️ Suppression de l'entrée originale: $removed");

                    saved.add(newEntry);
                    await prefs.setStringList('saved_devices', saved);

                    print("✅ Sauvegardé: $saved");

                    Navigator.of(context).pop();
                    _loadDevices();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Color(0xFF1B75BC),
                    side: BorderSide(color: Color(0xFF1B75BC)),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _confirmForceDelete(String entry) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange),
            SizedBox(width: 8),
            Expanded(child: Text("Suppression forcée ?")),
          ],
        ),
        content: Text(
            "La tentative de reset de l'appareil a échoué.\nSouhaitez-vous quand même forcer la suppression de ce device ?"),
        actions: [
          OutlinedButton.icon(
            icon: Icon(Icons.cancel),
            label: Text("Annuler"),
            onPressed: () => Navigator.of(context).pop(),
            style: OutlinedButton.styleFrom(
              foregroundColor: Color(0xFF1B75BC),
              side: BorderSide(color: Color(0xFF1B75BC)),
            ),
          ),
          OutlinedButton.icon(
            icon: Icon(Icons.delete_forever),
            label: Text("Forcer"),
            onPressed: () {
              Navigator.of(context).pop();
              _removeDevice(entry, force: true);
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              side: BorderSide(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  void _removeDevice(String entry, {bool force = false}) async {
    final parts = entry.split('|');
    if (parts.length < 2) return;

    final name = parts[0];
    final url = parts[1];

    if (!force) {
      final success = await _resetDeviceConfig(name, url);

      if (!success) {
        // 🔁 Échec de reset : demander confirmation de suppression forcée
        _confirmForceDelete(entry);
        return;
      }
    }

    // ✅ Suppression locale (normale ou forcée)
    SharedPreferences prefs = await SharedPreferences.getInstance();
    devices.remove(entry);
    await prefs.setStringList('saved_devices', devices);
    setState(() {});
  }

  // ✅ Changement principal: utilisation de BleProvisionScreen au lieu de WifiProvisionScreen
  void _startProvisioning() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BleProvisionScreen()), // ✅ BLE au lieu de WiFi
    );
    if (result == true) _resetStateAfterProvisioning();
  }

  void _addManualDevice(String name, String url) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> saved = prefs.getStringList('saved_devices') ?? [];
    String entry = "$name|$url";
    if (!saved.contains(entry)) {
      saved.add(entry);
      await prefs.setStringList('saved_devices', saved);
      setState(() => _loadDevices());
    }
  }

  void _showManualAddDialog() {
    String name = "", url = "";
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Image.asset("assets/logo_x.png", height: 32),
            SizedBox(width: 8),
            Expanded(child: Text("Ajouter un appareil")),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: InputDecoration(labelText: "Nom de l'appareil"),
              onChanged: (value) => name = value,
              autofocus: true,
            ),
            TextField(
              decoration: InputDecoration(labelText: "URL de l'appareil"),
              onChanged: (value) => url = value,
            ),
          ],
        ),
        actions: [
          OutlinedButton.icon(
            icon: Icon(Icons.cancel),
            label: Text("Annuler"),
            onPressed: () => Navigator.of(context).pop(),
            style: OutlinedButton.styleFrom(
              foregroundColor: Color(0xFF1B75BC),
              side: BorderSide(color: Color(0xFF1B75BC)),
            ),
          ),
          OutlinedButton.icon(
            icon: Icon(Icons.add),
            label: Text("Ajouter"),
            onPressed: () {
              if (name.isNotEmpty && url.isNotEmpty) {
                _addManualDevice(name.trim(), url.trim());
                Navigator.pop(context);
              }
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: Color(0xFF1B75BC),
              side: BorderSide(color: Color(0xFF1B75BC)),
            ),
          ),
        ],
      ),
    );
  }

  /// Résout une URL (DNS, mDNS, IP) et retourne l'URL HTTP finale, ou null.
  Future<String?> _resolveToFinalUrl(String url, String name) async {
    if (isDNSName(url)) {
      return _normalizeUrl(url);
    }
    String? resolved = await UniversalResolver.resolveAddress(url, deviceName: name);
    if (resolved != null) {
      return _normalizeUrl(resolved);
    }
    return null;
  }

  /// Teste si une URL est joignable (timeout court).
  Future<bool> _isUrlReachable(String url) async {
    print('[REACHABLE] Test de $url...');
    final dio = Dio();
    dio.options.connectTimeout = const Duration(seconds: 5);
    dio.options.sendTimeout = const Duration(seconds: 3);
    dio.options.receiveTimeout = const Duration(seconds: 3);
    try {
      final response = await dio.get(
        url,
        options: Options(
          validateStatus: (status) => true, // Accepter tout statut
          followRedirects: true,
        ),
      );
      print('[REACHABLE] $url → status ${response.statusCode}');
      return response.statusCode != null;
    } catch (e) {
      print('[REACHABLE] $url → ECHEC: $e');
      return false;
    } finally {
      dio.close(force: true);
    }
  }

  /// Vérifie si un tunnel est configuré sur la box locale.
  /// Retourne l'URL tunnel (ex: https://abc123.lixee-box.fr) ou null.
  Future<String?> _fetchTunnelUrl(String localUrl, String login, String password) async {
    String baseUrl = _normalizeUrl(localUrl);
    print('[TUNNEL] Vérification tunnel sur $baseUrl...');

    try {
      final authMode = await detectAuthMode(baseUrl);

      if (authMode == AuthMode.form) {
        final session = SessionManager(
          targetBaseUrl: baseUrl,
          username: login,
          password: password,
        );
        try {
          final loginOk = await session.login();
          if (!loginOk) {
            session.close();
            return _fetchTunnelUrlBasicAuth(baseUrl, login, password);
          }
          final result = await session.authenticatedGet('/api/tunnel/credentials');
          if (result.statusCode == 200 && result.body.isNotEmpty) {
            final data = jsonDecode(result.body);
            if (data['tunnelClientId'] != null) {
              final tunnelUrl = 'https://${data['tunnelClientId']}.lixee-box.fr';
              print('[TUNNEL] Tunnel trouvé: $tunnelUrl');
              return tunnelUrl;
            }
          }
        } finally {
          session.close();
        }
      } else {
        return _fetchTunnelUrlBasicAuth(baseUrl, login, password);
      }
    } catch (e) {
      print('[TUNNEL] Erreur: $e');
    }
    print('[TUNNEL] Pas de tunnel configuré');
    return null;
  }

  Future<String?> _fetchTunnelUrlBasicAuth(String baseUrl, String login, String password) async {
    final dio = Dio();
    dio.options.connectTimeout = const Duration(seconds: 5);
    dio.options.receiveTimeout = const Duration(seconds: 5);
    try {
      final response = await dio.get(
        '$baseUrl/api/tunnel/credentials',
        options: Options(
          headers: {
            'Authorization': 'Basic ${base64Encode(utf8.encode('$login:$password'))}',
          },
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        final data = response.data is String ? jsonDecode(response.data) : response.data;
        if (data['tunnelClientId'] != null) {
          final tunnelUrl = 'https://${data['tunnelClientId']}.lixee-box.fr';
          print('[TUNNEL] Tunnel trouvé (Basic Auth): $tunnelUrl');
          return tunnelUrl;
        }
      }
    } catch (e) {
      print('[TUNNEL] Basic Auth échoué: $e');
    } finally {
      dio.close(force: true);
    }
    return null;
  }

  /// Met à jour l'entrée du device dans SharedPreferences.
  Future<String> _updateDeviceEntry(String originalEntry, String newEntry) async {
    if (originalEntry == newEntry) return newEntry;
    final prefs = await SharedPreferences.getInstance();
    List<String> saved = prefs.getStringList('saved_devices') ?? [];
    final index = saved.indexOf(originalEntry);
    if (index >= 0) {
      saved[index] = newEntry;
    } else {
      saved.add(newEntry);
    }
    await prefs.setStringList('saved_devices', saved);
    print('[DEVICE] Entry mise à jour: $newEntry');
    return newEntry;
  }

  Future<void> _openDevice(String entry) async {
    print("_openDevice DEBUT pour: '$entry'");

    final parsed = _parseDeviceEntry(entry);
    if (parsed == null) {
      print("Format invalide: $entry");
      return;
    }

    final name = parsed['name']!;
    final primaryUrl = parsed['url']!;
    final fallbackUrl = parsed['fallback'];
    final login = parsed['login'];
    final password = parsed['password'];

    // Recharger les devices pour avoir les derniers credentials
    _loadDevices();
    String currentEntry = entry;
    for (String device in devices) {
      final dp = _parseDeviceEntry(device);
      if (dp != null && dp['name'] == name && dp['url'] == primaryUrl) {
        currentEntry = device;
        break;
      }
    }

    // --- Vérification tunnel à chaque ouverture ---
    // Si on a l'auth et une URL locale (IP ou .local), chercher le tunnel
    if (login != null && password != null) {
      // Déterminer l'URL locale (fallback ou primary si c'est une IP/.local)
      String? localUrl;
      if (isIPAddress(primaryUrl) || isLocalDomain(primaryUrl)) {
        localUrl = primaryUrl;
      } else if (fallbackUrl != null && (isIPAddress(fallbackUrl) || isLocalDomain(fallbackUrl))) {
        localUrl = fallbackUrl;
      }

      if (localUrl != null) {
        final localResolved = await _resolveToFinalUrl(localUrl, name);
        if (localResolved != null) {
          final tunnelUrl = await _fetchTunnelUrl(localResolved, login, password);
          if (tunnelUrl != null) {
            // Tunnel trouvé → mettre tunnel en primaire, local en fallback
            final currentParsed = _parseDeviceEntry(currentEntry);
            if (currentParsed != null && currentParsed['url'] != tunnelUrl) {
              final newEntry = _buildDeviceEntry(
                name: name,
                url: tunnelUrl,
                login: login,
                password: password,
                fallback: localUrl,
              );
              currentEntry = await _updateDeviceEntry(currentEntry, newEntry);
              _loadDevices();
            }
          }
        }
      }
    }

    // --- Fallback logic : essayer primaire puis secondaire ---
    // On utilise _pollUrl (vrai test /poll sur la box) au lieu de _isUrlReachable
    // car le serveur tunnel répond toujours (même si le tunnel est coupé)
    final updatedParsed = _parseDeviceEntry(currentEntry)!;
    final updatedLogin = updatedParsed['login'];
    final updatedPassword = updatedParsed['password'];
    final urlsToTry = <String>[updatedParsed['url']!];
    if (updatedParsed['fallback'] != null && updatedParsed['fallback']!.isNotEmpty) {
      urlsToTry.add(updatedParsed['fallback']!);
    }

    String? finalUrl;
    bool isFallback = false;
    for (int i = 0; i < urlsToTry.length; i++) {
      final urlCandidate = urlsToTry[i];
      final resolved = await _resolveToFinalUrl(urlCandidate, name);
      if (resolved == null) {
        print("[FALLBACK] Impossible de résoudre: $urlCandidate");
        continue;
      }
      print("[FALLBACK] Test poll sur $resolved...");
      final pollResult = await _pollUrl(resolved, name, login: updatedLogin, password: updatedPassword);
      if (pollResult != null) {
        finalUrl = resolved;
        isFallback = i > 0;
        print("[FALLBACK] $resolved répond (status=${pollResult.statusCode}) ${isFallback ? '(FALLBACK)' : '(PRIMAIRE)'} !");
        break;
      } else {
        print("[FALLBACK] $resolved ne répond pas, essai suivant...");
      }
    }

    if (finalUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Impossible de joindre $name"))
      );
      return;
    }

    print("LANCEMENT WebView pour '$name' avec URL finale: $finalUrl ${isFallback ? '(FALLBACK)' : '(PRIMAIRE)'}");

    bool result = (await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WebViewDeviceScreen(
          deviceEntry: currentEntry,
          url: finalUrl!,
          isFallback: isFallback,
          hasFallback: urlsToTry.length > 1,
        ),
      ),
    )) == true;

    print("Retour WebView pour '$name', résultat: $result");
    await Future.delayed(Duration(milliseconds: 200));
    _loadDevices();

    if (result) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Configuration mise à jour pour $name"), backgroundColor: Colors.green)
      );
    }
  }


  Future<List<Map<String, String>>> getNotifications(String deviceName) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> raw = prefs.getStringList('notifications_$deviceName') ?? [];

    return raw.map((entry) {
      List<String> parts = entry.split('|');
      if (parts.length >= 3) {
        return {
          "date": parts[0],
          "title": parts[1],
          "message": parts[2],
        };
      }
      return {
        "date": "",
        "title": "Notification malformée",
        "message": entry,
      };
    }).toList();
  }

  void _showNotificationsDialog(String Entry) async {
    List<String> parts = Entry.split("|");
    String name = parts[0];

    List<Map<String, String>> notifications = await getNotifications(name);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("🔔 Notifications - $name"),
          content: notifications.isEmpty
              ? Text("Pas de notifications.")
              : SizedBox(
            width: double.maxFinite,
            height: 400, // ✅ Hauteur fixe pour éviter le débordement
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: notifications.length,
              itemBuilder: (context, index) {
                final notif = notifications[index];
                return Card(
                  margin: EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    title: Text(
                      notif['title'] ?? '',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("🕒 ${notif['date']}"),
                        SizedBox(height: 4),
                        Text("📄 ${notif['message']}"),
                      ],
                    ),
                    isThreeLine: true,
                  ),
                );
              },
            ),
          ),
          actions: [
            if (notifications.isNotEmpty)
              OutlinedButton.icon(
                icon: Icon(Icons.delete,),
                label: Text("Supprimer"),
                onPressed: () async {
                  SharedPreferences prefs = await SharedPreferences.getInstance();
                  await prefs.remove('notifications_$name');

                  Navigator.of(context).pop(); // Ferme le popup
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Notifications supprimées pour $name")),
                  );
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: BorderSide(color: Colors.red),
                ),
              ),
            OutlinedButton.icon(
              icon: Icon(Icons.cancel,),
              label: Text("Fermer"),
              onPressed: () {
                Navigator.of(context).pop();
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: Color(0xFF1B75BC),
                side: BorderSide(color: Color(0xFF1B75BC)),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Bouton AppBar focusable au D-pad, avec fond bleu LiXee.
  Widget _buildAppBarButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Material(
        color: const Color(0xFF1B75BC),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          focusColor: Colors.white.withOpacity(0.3),
          child: Semantics(
            button: true,
            label: tooltip,
            child: Tooltip(
              message: tooltip,
              child: Container(
                padding: EdgeInsets.all(TVDetector.isTV ? 16 : 12),
                child: Icon(icon, color: Colors.white,
                    size: TVDetector.isTV ? 28 : 20),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Dialog de confirmation de suppression d'un device.
  void _showDeleteConfirmDialog(String entry) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Image.asset("assets/logo_x.png", height: 32),
              SizedBox(width: 8),
              Expanded(child: Text("Supprimer l'appareil ?")),
            ],
          ),
          content: Text("Êtes-vous sûr de vouloir supprimer cet appareil ?"),
          actions: [
            OutlinedButton.icon(
              icon: Icon(Icons.cancel),
              label: Text("Annuler"),
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: Color(0xFF1B75BC),
                side: BorderSide(color: Color(0xFF1B75BC)),
              ),
            ),
            OutlinedButton.icon(
              icon: Icon(Icons.check),
              label: Text("Valider"),
              onPressed: () {
                Navigator.of(context).pop();
                _removeDevice(entry);
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: Color(0xFF1B75BC),
                side: BorderSide(color: Color(0xFF1B75BC)),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Menu contextuel long-press pour les actions device sur TV.
  void _showDeviceActionsMenu(BuildContext context, String entry, Offset position) {
    final parts = entry.split('|');
    final name = parts.isNotEmpty ? parts[0] : '';

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx, position.dy, position.dx + 1, position.dy + 1,
      ),
      items: [
        PopupMenuItem(
          value: 'notifications',
          child: Row(children: [
            Icon(Icons.notifications_outlined, color: Color(0xFF1B75BC)),
            SizedBox(width: 12),
            Text('Notifications'),
          ]),
        ),
        PopupMenuItem(
          value: 'edit',
          child: Row(children: [
            Icon(Icons.edit_outlined, color: Color(0xFF1B75BC)),
            SizedBox(width: 12),
            Text('Modifier'),
          ]),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(children: [
            Icon(Icons.delete_outlined, color: Colors.red),
            SizedBox(width: 12),
            Text('Supprimer', style: TextStyle(color: Colors.red)),
          ]),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'notifications':
          _showNotificationsDialog(entry);
          break;
        case 'edit':
          _showEditDialog(entry);
          break;
        case 'delete':
          _showDeleteConfirmDialog(entry);
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Lancement depuis un widget : on ne montre pas la liste des box, sans
    // quoi elle apparaîtrait le temps que la cascade d'URL aboutisse — alors
    // que l'utilisateur a déjà désigné la sienne.
    if (_pendingWidgetDevice != null) {
      return _buildWidgetLaunchScreen(_pendingWidgetDevice!);
    }
    return SafeArea(
        child: Scaffold(
          backgroundColor: Color(0xFFF5F7FA),
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 1,
            title: Row(
              children: [
                Image.asset("assets/logo.png", height: 64),
                SizedBox(width: 10),
                Text("Assist", style: TextStyle(color: Colors.black87)),
              ],
            ),
            actions: [
              _buildAppBarButton(
                icon: Icons.bluetooth,
                tooltip: "Appairer un appareil",
                onPressed: _startProvisioning,
              ),
              _buildAppBarButton(
                icon: Icons.note_add_outlined,
                tooltip: "Ajouter manuellement",
                onPressed: _showManualAddDialog,
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: Color(0xFF1B75BC)),
                tooltip: "Plus d'options",
                onSelected: (value) {
                  switch (value) {
                    case 'about':
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => AboutScreen()),
                      );
                      break;
                    case 'clear_cache':
                      UniversalResolver.clearCache();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Cache DNS vidé"), backgroundColor: Colors.green),
                      );
                      break;
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'about',
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, size: 20, color: Color(0xFF1B75BC)),
                        SizedBox(width: 12),
                        Text('À propos'),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(width: 8),
            ],
          ),
          body: devices.isEmpty
              ? Center(child: Text("Aucun appareil enregistré.",
              style: TextStyle(color: Colors.grey)))
              : ListView.builder(
              padding: EdgeInsets.all(TVDetector.isTV ? 32 : 16),
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final parsed = _parseDeviceEntry(devices[index]);
                if (parsed == null) return const SizedBox.shrink();
                String name = parsed['name']!;
                String url = parsed['url']!;
                String? fallback = parsed['fallback'];
                final bool hasFallback = fallback != null && fallback.isNotEmpty;
                final bool isOnline = deviceStatuses[devices[index]] == true;
                final bool isOnFallback = deviceOnFallback[devices[index]] ?? false;

                // Logique du badge :
                // - hasFallback + online + !fallback → "Tunnel" vert
                // - hasFallback + online + fallback  → "Local" orange
                // - hasFallback + offline            → "Hors ligne" rouge
                // - !hasFallback + online            → "Local" vert
                // - !hasFallback + offline           → "Hors ligne" rouge
                String badgeLabel;
                Color badgeColor;
                if (!isOnline) {
                  badgeLabel = "Hors ligne";
                  badgeColor = Colors.red;
                } else if (hasFallback && !isOnFallback) {
                  badgeLabel = "Tunnel";
                  badgeColor = Colors.green;
                } else if (hasFallback && isOnFallback) {
                  badgeLabel = "Local";
                  badgeColor = Colors.orange;
                } else {
                  badgeLabel = "Local";
                  badgeColor = Colors.green;
                }

                return FutureBuilder<List<String>>(
                  future: _getNotifications(name),
                  builder: (context, snapshot) {
                    final hasNotifications =
                        snapshot.connectionState == ConnectionState.done &&
                            (snapshot.data?.isNotEmpty ?? false);

                    return Focus(
                      autofocus: index == 0,
                      child: Builder(
                        builder: (focusContext) {
                          final bool hasFocus = Focus
                              .of(focusContext)
                              .hasFocus;
                          return GestureDetector(
                            onLongPressStart: TVDetector.isTV
                                ? (details) => _showDeviceActionsMenu(
                                    context, devices[index], details.globalPosition)
                                : null,
                            child: Card(
                              elevation: hasFocus ? 8 : 2,
                              color: Colors.white,
                              margin: EdgeInsets.symmetric(vertical: TVDetector.isTV
                                  ? 16
                                  : 8),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: hasFocus
                                    ? const BorderSide(color: Color(0xFF1B75BC), width: 3)
                                    : BorderSide.none,
                              ),
                              child: ListTile(
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: TVDetector.isTV ? 32 : 16,
                                    vertical: TVDetector.isTV ? 16 : 8),
                                title: Row(
                                  children: [
                                    if (devices[index].contains('|auth|'))
                                      Padding(
                                        padding: const EdgeInsets.only(right: 4.0),
                                        child: Icon(Icons.lock_outline, size: 16,
                                            color: Colors.grey),
                                      ),
                                    Flexible(
                                      child: Text(
                                        name,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontWeight: FontWeight.w600,
                                            fontSize: TVDetector.isTV ? 24 : 16),
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Text(
                                  url,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: TVDetector.isTV ? 20 : 14),
                                ),
                                leading: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.devices_other,
                                      color: deviceStatuses[devices[index]] == true
                                          ? Colors.green
                                          : Colors.red,
                                      size: TVDetector.isTV ? 32 : 24,
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4.0),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: badgeColor.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: badgeColor,
                                            width: 1,
                                          ),
                                        ),
                                        child: Text(
                                          badgeLabel,
                                          style: TextStyle(
                                            fontSize: TVDetector.isTV ? 12 : 9,
                                            fontWeight: FontWeight.w600,
                                            color: badgeColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: TVDetector.isTV
                                    // TV : un seul bouton menu (les actions sont dans le long-press)
                                    ? IconButton(
                                        icon: Icon(Icons.more_vert, color: Color(0xFF1B75BC),
                                            size: TVDetector.isTV ? 32 : 24),
                                        tooltip: "Actions",
                                        onPressed: () {
                                          // Calculer la position du bouton pour le popup
                                          final RenderBox box = focusContext.findRenderObject() as RenderBox;
                                          final Offset pos = box.localToGlobal(
                                            Offset(box.size.width - 48, box.size.height / 2),
                                          );
                                          _showDeviceActionsMenu(context, devices[index], pos);
                                        },
                                      )
                                    // Mobile : les 3 boutons classiques
                                    : Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: Icon(
                                                hasNotifications
                                                    ? Icons.notifications
                                                    : Icons.notifications_outlined,
                                                color: hasNotifications ? Colors.amber : Color(0xFF1B75BC)),
                                            tooltip: "Voir les notifications",
                                            onPressed: () =>
                                                _showNotificationsDialog(devices[index]),
                                          ),
                                          IconButton(
                                            icon: Icon(
                                                Icons.edit_outlined,
                                                color: Color(0xFF1B75BC)),
                                            tooltip: "Modifier",
                                            onPressed: () =>
                                                _showEditDialog(devices[index]),
                                          ),
                                          IconButton(
                                            icon: Icon(Icons.delete_outlined,
                                                color: Color(0xFF1B75BC)),
                                            onPressed: () => _showDeleteConfirmDialog(devices[index]),
                                          ),
                                        ],
                                      ),
                                onTap: () => _openDevice(devices[index]),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                );
              }
          ),
        )
    );
  }
}
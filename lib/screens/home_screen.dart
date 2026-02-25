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
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDevices();
    _startAutoRefresh();
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
    super.dispose();
  }

  // Modification de la fonction checkDeviceStatus existante
  void checkDeviceStatus(String deviceName, String url, String entryKey, {String? login, String? password}) async {
    print("🔍 Vérification de l'état de l'appareil : $deviceName");

    String finalUrl = url;

    // Traitement selon le type d'adresse
    if (isDNSName(url)) {
      // DNS classique : utilisation directe
      finalUrl = _normalizeUrl(url);
      print("🌐 Utilisation DNS directe: $finalUrl");

    } else if (!isIPAddress(url)) {
      // mDNS ou autre : résolution nécessaire
      print("🔄 URL nécessite une résolution, type détecté: ${_getUrlType(url)}");

      String? resolvedAddress = await UniversalResolver.resolveAddress(url, deviceName: deviceName);

      if (resolvedAddress != null) {
        finalUrl = _normalizeUrl(resolvedAddress);
        print("✅ URL résolue: $url -> $finalUrl");
      } else {
        print("❌ Impossible de résoudre: $url");
        if (mounted) {
          setState(() {
            deviceStatuses[entryKey] = false;
          });
        }
        return;
      }
    } else {
      // IP : normalisation simple
      finalUrl = _normalizeUrl(url);
    }

    // Requête de polling
    final Dio dio = Dio();
    try {
      final response = await dio.get(
        "$finalUrl/poll",
        options: Options(
          sendTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 5),
          responseType: ResponseType.plain,
          validateStatus: (status) {
            // Accepter 200 (OK) et 401 (Unauthorized) comme des réponses valides
            return status == 200 || status == 401;
          },
          headers: (login != null && password != null)
              ? {
            'Authorization': 'Basic ${base64Encode(utf8.encode('$login:$password'))}',
          }
              : null,
        ),
      );

      if ((response.statusCode == 200) ||(response.statusCode == 401)) {
        print("✅ $deviceName est actif et authentifié via $finalUrl");

        // Traitement des notifications (votre code existant)
        if (response.data != null && response.data.toString().trim().isNotEmpty) {
          try {
            final jsonData = jsonDecode(response.data);

            if (jsonData != null && jsonData['notifications'] != null) {
              List<dynamic> notifications = jsonData['notifications'];

              for (int i = 0; i < notifications.length; i++) {
                var notif = notifications[i];
                print("📋 Notification reçue: $notif");

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
                      print("✅ Notification affichée: $title");
                    } catch (notifError) {
                      print("❌ Erreur lors de l'affichage de la notification: $notifError");
                    }
                  }
                }
              }
            }
          } catch (jsonError) {
            print("❌ Erreur lors du parsing JSON: $jsonError");
          }
        }

        if (mounted) {
          setState(() {
            deviceStatuses[entryKey] = true;
          });
        }

      } else {
        print("❌ $deviceName a répondu avec le code ${response.statusCode}");
        if (mounted) {
          setState(() {
            deviceStatuses[entryKey] = false;
          });
        }
      }
    } catch (e) {
      // Gérer spécifiquement les erreurs DioException pour 401
      if (e is DioException && e.response?.statusCode == 401) {
        print("🔐 $deviceName est actif mais nécessite une authentification (exception 401)");
        if (mounted) {
          setState(() {
            deviceStatuses[entryKey] = true; // Actif car il répond
          });
        }
      } else {
        print("❌ Erreur lors de la vérification de $deviceName : $e");
        if (mounted) {
          setState(() {
            deviceStatuses[entryKey] = false;
          });
        }
      }
    } finally {
      dio.close(force: true);
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
        List<String> parts = devices[i].split('|');
        if (parts.length == 2 || (parts.length == 5 && parts[2] == 'auth')) {
          String deviceName = parts[0];
          String deviceUrl = parts[1];
          String? login = parts.length == 5 ? parts[3] : null;
          String? password = parts.length == 5 ? parts[4] : null;

          checkDeviceStatus(deviceName, deviceUrl, devices[i], login: login, password: password);
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
      } else if (parts.length == 5 && parts[2] == 'auth') {
        validDevices.add(entry);
        print("🔐 Device avec auth: '${parts[0]}' -> '${parts[1]}' (login: '${parts[3]}')");
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
      final entry = validDevices[i];
      final parts = entry.split('|');
      if (parts.length >= 2) {
        final deviceName = parts[0];
        final deviceUrl = parts[1];
        String? login = (parts.length == 5 && parts[2] == 'auth') ? parts[3] : null;
        String? password = (parts.length == 5 && parts[2] == 'auth') ? parts[4] : null;

        checkDeviceStatus(deviceName, deviceUrl, entry, login: login, password: password);
      }
    }
  }

  void _showEditDialog(String originalEntry) {
    print("🔧 _showEditDialog pour: '$originalEntry'");

    List<String> parts = originalEntry.split("|");
    String name = parts[0];
    String url = parts[1];
    bool useAuth = parts.length == 5 && parts[2] == "auth";
    String login = useAuth ? parts[3] : "";
    String password = useAuth ? parts[4] : "";

    print("📋 Données chargées - Name: '$name', URL: '$url', Auth: $useAuth");
    if (useAuth) {
      print("🔐 Login: '$login', Password: ${password.isNotEmpty ? '[SET]' : '[EMPTY]'}");
    }

    bool obscurePassword = true;

    TextEditingController nameController = TextEditingController(text: name);
    TextEditingController urlController = TextEditingController(text: url);
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
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(labelText: "Nom"),
                  ),
                  TextField(
                    controller: urlController,
                    decoration: InputDecoration(labelText: "URL"),
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
                    String newLogin = loginController.text.trim();
                    String newPass = passwordController.text.trim();

                    if (newName.isEmpty || newUrl.isEmpty) {
                      print("❌ Nom ou URL vide !");
                      return;
                    }

                    String newEntry = "$newName|$newUrl";
                    if (useAuth && newLogin.isNotEmpty && newPass.isNotEmpty) {
                      newEntry += "|auth|$newLogin|$newPass";
                    }

                    print("🔧 Modification: '$originalEntry' -> '$newEntry'");

                    SharedPreferences prefs = await SharedPreferences.getInstance();
                    List<String> saved = prefs.getStringList('saved_devices') ?? [];

                    // ✅ CORRECTION: Supprimer l'entrée EXACTE originale
                    bool removed = saved.remove(originalEntry);
                    print("🗑️ Suppression de l'entrée originale: $removed");

                    // Ajouter la nouvelle
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

  Future<void> _openDevice(String entry) async {
    print("_openDevice DEBUT pour: '$entry'");

    final parts = entry.split('|');
    if (parts.length < 2) {
      print("Format invalide: $entry");
      return;
    }

    final name = parts[0];
    final url = parts[1];

    // Recharger les devices depuis SharedPreferences pour avoir les derniers credentials
    _loadDevices();

    // Trouver l'entrée mise à jour dans la liste rechargée
    String currentEntry = entry;
    for (String device in devices) {
      final deviceParts = device.split('|');
      if (deviceParts.length >= 2 && deviceParts[0] == name && deviceParts[1] == url) {
        currentEntry = device;
        print("Credentials mis à jour trouvés: $currentEntry");
        break;
      }
    }

    print("Device sélectionné: '$name' avec URL: '$url'");

    String finalUrl = url;

    if (isDNSName(url)) {
      finalUrl = _normalizeUrl(url);
      print("DNS direct pour '$name': $finalUrl");

    } else {
      print("Résolution nécessaire pour '$name': $url");
      String? resolved = await UniversalResolver.resolveAddress(url, deviceName: name);

      if (resolved != null) {
        finalUrl = _normalizeUrl(resolved);
        print("URL résolue pour '$name': $url -> $finalUrl");
      } else {
        print("Impossible de résoudre '$name': $url");
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Impossible de résoudre $name ($url)"))
        );
        return;
      }
    }

    print("LANCEMENT WebView pour '$name' avec URL finale: $finalUrl");
    print("Credentials utilisés: $currentEntry");

    bool result = (await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WebViewDeviceScreen(
          deviceEntry: currentEntry,  // Utiliser l'entrée mise à jour
          url: finalUrl,
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

  @override
  Widget build(BuildContext context) {
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Material(
                  color: Color(0xFF1B75BC),
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    onTap: _startProvisioning,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.bluetooth, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Material(
                  color: Color(0xFF1B75BC),
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    onTap: _showManualAddDialog,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.note_add_outlined, color: Colors.white, size: 20),
                    ),
                  ),
                ),
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
              padding: EdgeInsets.all(isTV(context) ? 32 : 16),
              itemCount: devices.length,
              itemBuilder: (context, index) {
                List<String> parts = devices[index].split("|");
                String name = parts[0];
                String url = parts[1];

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
                          return Card(
                            elevation: hasFocus ? 8 : 2,
                            color: Colors.white,
                            margin: EdgeInsets.symmetric(vertical: isTV(context)
                                ? 16
                                : 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            child: ListTile(
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: isTV(context) ? 32 : 16,
                                  vertical: isTV(context) ? 16 : 8),
                              title: Row(
                                children: [
                                  if (devices[index].contains('|auth|'))
                                    Padding(
                                      padding: const EdgeInsets.only(right: 4.0),
                                      child: Icon(Icons.lock_outline, size: 16,
                                          color: Colors.grey),
                                    ),
                                  Text(
                                    name,
                                    style: TextStyle(fontWeight: FontWeight.w600,
                                        fontSize: isTV(context) ? 24 : 16),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                url,
                                style: TextStyle(fontSize: isTV(context) ? 20 : 14),
                              ),
                              //leading: Icon(Icons.devices_other, color: Color(0xFF1B75BC)),
                              leading: Icon(
                                Icons.devices_other,
                                color: deviceStatuses[devices[index]] == true
                                    ? Colors
                                    .green
                                    : Colors.red,
                              ),
                              trailing: Row(
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
                                    onPressed: () {
                                      showDialog(
                                        context: context,
                                        builder: (BuildContext context) {
                                          return AlertDialog(
                                            title: Row(
                                              children: [
                                                Image.asset(
                                                    "assets/logo_x.png",
                                                    height: 32),
                                                SizedBox(width: 8),
                                                Expanded(child: Text(
                                                    "Supprimer l'appareil ?")),
                                              ],
                                            ),
                                            content: Text(
                                                "Êtes-vous sûr de vouloir supprimer cet appareil ?"),
                                            actions: [
                                              OutlinedButton.icon(
                                                icon: Icon(Icons.cancel,),
                                                label: Text("Annuler"),
                                                onPressed: () {
                                                  Navigator.of(context).pop();
                                                },
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: Color(
                                                      0xFF1B75BC),
                                                  side: BorderSide(
                                                      color: Color(0xFF1B75BC)),
                                                ),
                                              ),
                                              OutlinedButton.icon(
                                                icon: Icon(Icons.check),
                                                label: Text("Valider"),
                                                onPressed: () {
                                                  Navigator
                                                      .of(context)
                                                      .pop(); // Fermer le dialogue
                                                  _removeDevice(
                                                      devices[index]); // Supprimer réellement
                                                },
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: Color(
                                                      0xFF1B75BC),
                                                  side: BorderSide(
                                                      color: Color(0xFF1B75BC)),
                                                ),
                                              ),
                                            ],
                                          );
                                        },
                                      );
                                    },
                                  ),
                                ],
                              ),
                              onTap: () => _openDevice(devices[index]),
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
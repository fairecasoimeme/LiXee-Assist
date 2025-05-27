import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'wifi_provision_screen.dart';
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

Future<List<String>> _getNotifications(String deviceName) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getStringList('notifications_$deviceName') ?? [];
}


/// 🔍 mDNS lookup
Future<String?> resolveMdnsIP(String deviceName) async {
  final client = MDnsClient(
    rawDatagramSocketFactory: (
        host,
        int port, {
          bool reuseAddress = true,
          bool reusePort = false, // 👈 ce paramètre est ignoré ici
          int ttl=255,
        }) {
      return RawDatagramSocket.bind(
        host,
        port,
        reuseAddress: reuseAddress,
        // 🛑 🔧 ON FORCE reusePort à false
        reusePort: false,
      );
    },
  );
  try {
    await client.start();
    print("🔍 Recherche mDNS `_http._tcp.local`...");


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
    print("❌ Erreur mDNS : $e");
  }finally{
    client.stop();
  }
  return null;
}

Future<bool> _resetDeviceConfig(String name, String url) async {
  try {
    final String? ip;
    if (isIPAddress(url)) {
      ip = Uri.parse(url).host;
    } else {
      ip = await resolveMdnsIP(name);
      if (ip == null) {
        print("❌ Impossible d'extraire l'IP depuis $url");
        return false;
      }
    }

    final dio = Dio();
    final fullUrl = 'http://$ip/setResetDevice';

    print("🔧 Envoi de la requête de reset vers $fullUrl...");
    final response = await dio.post(fullUrl);

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


class _HomeScreenState extends State<HomeScreen> {
  List<String> devices = [];
  Timer? _refreshTimer;
  Map<String, bool> deviceStatuses = {};
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _loadDevices();
    _startAutoRefresh(); // ✅ start polling
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (!_initialized) {
      final shouldReset = ModalRoute.of(context)?.settings.arguments == true;
      if (shouldReset) {
        print("🔁 Rechargement après provisioning détecté");
        _resetStateAfterProvisioning();
      }
      _initialized = true;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void checkDeviceStatus(String deviceName, String url, String entryKey, {String? login, String? password}) async {
    print("🔍 Vérification de l'état de l'appareil : $deviceName");

    if (!isIPAddress(url)) {
      print("🌐 URL n'est pas une IP, tentative de résolution mDNS...");
      String? ip = await resolveMdnsIP(deviceName);
      if (ip != null) {
        url = "http://$ip";
      } else {
        if (mounted) {
          setState(() {
            deviceStatuses[entryKey] = false;
          });
        }
        return;
      }
    }

    final Dio dio = Dio();
    try {
      final response = await dio.get(
        "$url/poll",
        options: Options(
          sendTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 5),
          responseType: ResponseType.plain,
          headers: (login != null && password != null)
              ? {
            'Authorization': 'Basic ${base64Encode(utf8.encode('$login:$password'))}',
          }
              : null,
        ),
      );

      if (response.statusCode == 200) {
        print("✅ $deviceName est actif");
        print(response.data);
        // ✅ Vérifier si response.data n'est pas null et n'est pas vide
        if (response.data != null && response.data.toString().trim().isNotEmpty) {
          try {
            final jsonData = jsonDecode(response.data);

            // ✅ Vérifier si 'notifications' existe dans la réponse
            if (jsonData != null && jsonData['notifications'] != null) {
              List<dynamic> notifications = jsonData['notifications'];

              for (int i = 0; i < notifications.length; i++) {
                var notif = notifications[i];
                print("📋 Notification reçue: $notif");

                // ✅ Vérification de la structure de la notification
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

                  // ✅ Sauvegarde de la notification
                  await saveNotification(
                      deviceName,
                      notif['timeStamp'].toString(),
                      title,
                      notif['message']?.toString() ?? ''
                  );

                  // ✅ Affichage de la notification uniquement si l'app est active
                  if (mounted) {
                    try {
                      await flutterLocalNotificationsPlugin.show(
                        DateTime.now().millisecondsSinceEpoch ~/ 1000 + i, // ID unique basé sur le timestamp
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
            print("📄 Données reçues: ${response.data}");
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
      print("❌ Erreur lors de la vérification de $deviceName : $e");
      if (mounted) {
        setState(() {
          deviceStatuses[entryKey] = false;
        });
      }
    } finally {
      dio.close(force: true);
    }
  }

  Future<void> _resetStateAfterProvisioning() async {
    print("♻️ Réinitialisation post-provisioning...");
    setState(() {
      devices.clear();
      deviceStatuses.clear();
    });
    await Future.delayed(Duration(milliseconds: 500));
    _loadDevices(); // recharge avec sockets neufs
  }

  void _startAutoRefresh() {
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
    SharedPreferences prefs = await SharedPreferences.getInstance();
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


    setState(() {
      devices = validDevices;
    });

    // ✅ On fait la vérification d’état APRES avoir chargé
    for (int i = 0; i < validDevices.length; i++) {
      List<String> parts = validDevices[i].split('|');
      if (parts.length == 2 || (parts.length == 5 && parts[2] == 'auth')) {
        String deviceName = parts[0];
        String deviceUrl = parts[1];
        String? login = parts.length == 5 ? parts[3] : null;
        String? password = parts.length == 5 ? parts[4] : null;
        checkDeviceStatus(deviceName, deviceUrl, devices[i], login: login, password: password);
      }
    }
    print("📋 Appareils chargés : $devices");
  }


  void _showEditDialog(String originalEntry) {
    List<String> parts = originalEntry.split("|");
    String name = parts[0];
    String url = parts[1];
    bool useAuth = parts.length > 2 && parts[2] == "auth";
    String login = parts.length > 3 ? parts[3] : "";
    String password = parts.length > 4 ? parts[4] : "";
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
                  Expanded(child: Text("Modifier l'appareil")),
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
                    if (useAuth) newEntry += "|auth|$newLogin|$newPass";

                    SharedPreferences prefs = await SharedPreferences.getInstance();
                    devices.remove(originalEntry);
                    devices.add(newEntry);
                    await prefs.setStringList('saved_devices', devices);
                    setState(() {});
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
    if (parts.length != 2) return;

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


  void _startProvisioning() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WifiProvisionScreen()),
    );
    if (result == true) _resetStateAfterProvisioning();
   // if (result == true) _loadDevices();
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
    final parts = entry.split('|');
    if (parts.length < 2) return;

    final name = parts[0];
    String url = parts[1];
    bool result = false;
    if (isIPAddress(url)) {
      result = (await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => WebViewDeviceScreen(deviceEntry: entry, url: url),
        ),
      )) == true;
    } else {
      String? ip = await resolveMdnsIP(name);
      if (ip != null) {
        result = (await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => WebViewDeviceScreen(deviceEntry: entry, url: "http://$ip"),
          ),
        )) == true;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Impossible de résoudre $name"),
        ));
      }
    }

    if (result == true) {
      print("🔁 Rafraîchissement demandé après WebView");
      _loadDevices(); // ou _resetStateAfterProvisioning() selon ton besoin
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
            IconButton(
              icon: Icon(Icons.add),
              tooltip: "Ajout automatique",
              onPressed: _startProvisioning,
            ),
            IconButton(
              icon: Icon(Icons.note_add_outlined),
              tooltip: "Ajout manuel",
              onPressed: _showManualAddDialog,
            ),
            IconButton(
              icon: Icon(Icons.info_outline),
              tooltip: "À propos",
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AboutScreen()),
                );
              },
            ),

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
        floatingActionButton: Focus(
          child: OutlinedButton.icon(
            onPressed: _startProvisioning,
            icon: Icon(Icons.add, size: 32),
            label: Text(""),
            style: OutlinedButton.styleFrom(
              foregroundColor: Color(0xFF1B75BC),
              side: BorderSide(color: Color(0xFF1B75BC)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            ),
          ),
        ),
      )
    );
  }
}

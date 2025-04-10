import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'wifi_provision_screen.dart';
import 'webview_device_screen.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'dart:io';
import 'package:dio/dio.dart';
import 'about_screen.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
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
    final ip;
    if (isIPAddress(url)) {
      ip = isIPAddress(url);
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

  void checkDeviceStatus(String deviceName, String url, String entryKey) async {
    print("🔍 Vérification de l'état de l'appareil : $deviceName");

    if (!isIPAddress(url)) {
      print("🌐 URL n'est pas une IP, tentative de résolution mDNS...");
      String? ip = await resolveMdnsIP(deviceName);
      if (ip != null) {
        url = "http://$ip";
        print("✅ IP résolue : $url");
      } else {
        print("❌ Résolution mDNS échouée pour $deviceName");
        setState(() {
          deviceStatuses[entryKey] = false;
        });
        return;
      }
    }

    final Dio dio = Dio();
    try {
      final response = await dio.get(
        "$url/poll",
        options: Options(
          sendTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
          responseType: ResponseType.plain,
        ),
      );

      if (response.statusCode == 200) {
        print("✅ $deviceName est actif");
        setState(() {
          deviceStatuses[entryKey] = true;
        });
      }else {
        print("❌ $deviceName a répondu avec le code ${response.statusCode}");
        setState(() {
          deviceStatuses[entryKey] = false;
        });
      }
    } catch (e) {
      print("❌ Erreur pendant la vérification de $deviceName : $e");
      setState(() {
        deviceStatuses[entryKey] = false;
      });
    } finally {
      dio.close(force: true); // 🔒 bonne pratique pour nettoyer
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
        if (parts.length == 2) {
          String deviceName = parts[0];
          String deviceUrl = parts[1];
          checkDeviceStatus(deviceName, deviceUrl, devices[i]);
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
      if (parts.length == 2) {
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
      if (parts.length == 2) {
        String deviceName = parts[0];
        String deviceUrl = parts[1];
        checkDeviceStatus(deviceName, deviceUrl, validDevices[i]);
      }
    }
    print("📋 Appareils chargés : $devices");
  }


  void _showEditDialog(String originalEntry) {
    List<String> parts = originalEntry.split("|");
    String name = parts[0];
    String url = parts[1];

    TextEditingController nameController = TextEditingController(text: name);
    TextEditingController urlController = TextEditingController(text: url);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Image.asset("assets/logo_x.png", height: 32),
              SizedBox(width: 8),
              Expanded(child: Text("Modifier l'appareil ?")),
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

                if (newName.isNotEmpty && newUrl.isNotEmpty) {
                  SharedPreferences prefs = await SharedPreferences.getInstance();
                  devices.remove(originalEntry);
                  devices.add("$newName|$newUrl");
                  await prefs.setStringList('saved_devices', devices);
                  setState(() {});
                  Navigator.of(context).pop();
                } else {
                  print("❌ Nom ou URL vide !");
                }
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

  void _removeDevice(String entry) async {

    final parts = entry.split('|');
    if (parts.length != 2) return;

    final name = parts[0];
    final url = parts[1];

    // 🔁 Réinitialisation avant suppression
    final success = await _resetDeviceConfig(name, url);

    // 💾 Suppression locale
    if (success)
    {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      devices.remove(entry);
      await prefs.setStringList('saved_devices', devices);
      setState(() {});
    }

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

  void _openDevice(String name, String url) async {
    if (isIPAddress(url)) {
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => WebViewDeviceScreen(deviceName: name, url: url)));
    } else {
      String? ip = await resolveMdnsIP(name);
      if (ip != null) {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => WebViewDeviceScreen(deviceName: name, url: "http://$ip")));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Impossible de résoudre $name"),
        ));
      }
    }
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
          padding: EdgeInsets.all(16),
          itemCount: devices.length,
          itemBuilder: (context, index) {
            List<String> parts = devices[index].split("|");
            String name = parts[0];
            String url = parts[1];

            return Card(
              elevation: 2,
              margin: EdgeInsets.symmetric(vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                title: Text(name, style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(url),
                //leading: Icon(Icons.devices_other, color: Color(0xFF1B75BC)),
                leading: Icon(
                  Icons.devices_other,
                  color: deviceStatuses[devices[index]] == true ? Colors.green : Colors.red,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(Icons.edit_outlined, color: Color(0xFF1B75BC)),
                      tooltip: "Modifier",
                      onPressed: () => _showEditDialog(devices[index]),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outlined, color: Color(0xFF1B75BC)),
                      onPressed: () {
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
                                  icon: Icon(Icons.cancel,),
                                  label: Text("Annuler"),
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                  },
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Color(0xFF1B75BC),
                                    side: BorderSide(color: Color(0xFF1B75BC)),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  icon: Icon(Icons.check),
                                  label: Text("Valider"),
                                  onPressed: () {
                                    Navigator.of(context).pop(); // Fermer le dialogue
                                    _removeDevice(devices[index]); // Supprimer réellement
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
                    ),
                  ],
                ),
                onTap: () => _openDevice(name, url),
              ),
            );
          },
        ),
        floatingActionButton: OutlinedButton.icon(
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
    );
  }
}

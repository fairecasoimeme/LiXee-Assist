import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'wifi_provision_screen.dart';
import 'webview_device_screen.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'dart:io';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

/// 📌 Vérifie si l'URL est une adresse IP
bool isIPAddress(String url) {
  final ipv4Pattern = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
  final ipv6Pattern = RegExp(r'^[0-9a-fA-F:]+$');
  Uri? parsedUri = Uri.tryParse(url);
  if (parsedUri == null) return false;
  String host = parsedUri.host;
  return ipv4Pattern.hasMatch(host) || ipv6Pattern.hasMatch(host);
}

/// 🔍 mDNS lookup
Future<String?> resolveMdnsIP(String deviceName) async {
  final MDnsClient client = MDnsClient();
  await client.start();
  print("🔍 Recherche mDNS `_http._tcp.local`...");

  try {
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
  }

  client.stop();
  return null;
}



class _HomeScreenState extends State<HomeScreen> {
  List<String> devices = [];
  Map<String, bool> deviceStatuses = {};

  @override
  void initState() {
    super.initState();
    _loadDevices();
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

    try {
      final result = await HttpClient()
          .getUrl(Uri.parse(url))
          .then((req) => req.close().timeout(Duration(seconds: 2)));

      if (result.statusCode == 200) {
        print("✅ Appareil actif : $url");
        setState(() {
          deviceStatuses[entryKey] = true;
        });
      } else {
        print("❌ Appareil injoignable : $url");
        setState(() {
          deviceStatuses[entryKey] = false;
        });
      }
    } catch (e) {
      print("❌ Erreur pendant la vérification de $url : $e");
      setState(() {
        deviceStatuses[entryKey] = false;
      });
    }
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
    if (result == true) _loadDevices();
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
    return Scaffold(
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
    );
  }
}

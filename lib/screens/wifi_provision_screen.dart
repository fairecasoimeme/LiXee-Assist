import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wifi_iot/wifi_iot.dart';
import 'webview_wifi_post_screen.dart';

class WifiProvisionScreen extends StatefulWidget {
  const WifiProvisionScreen({super.key});

  @override
  _WifiProvisionScreenState createState() => _WifiProvisionScreenState();
}

class _WifiProvisionScreenState extends State<WifiProvisionScreen> {
  List<WifiNetwork> networks = [];
  static bool _globalConnectingLock = false;

  @override
  void initState() {
    super.initState();
    _scanForWifiNetworks();
  }

  /// 🔍 Scan des réseaux WiFi disponibles
  void _scanForWifiNetworks() async {
    print("📡 Scan des réseaux WiFi en cours...");

    try {
      List<WifiNetwork> wifiList = await WiFiForIoTPlugin.loadWifiList();

      // 🔥 Filtrer les doublons en utilisant un Set
      Set<String> uniqueSSIDs = {};
      List<WifiNetwork> filteredList = wifiList.where((net) {
        if (net.ssid != null && uniqueSSIDs.add(net.ssid!)) {
          return true;
        }
        return false;
      }).toList();

      print("📡 Réseaux uniques détectés : ${filteredList.length}");

      for (var net in filteredList) {
        print("📶 ${net.ssid}");
      }

      setState(() {
        networks = filteredList.where((net) => net.ssid!.startsWith("LIXEEGW")).toList();
      });

      if (networks.isEmpty) {
        print("❌ Aucun réseau `LIXEEGW` détecté !");
      } else {
        print("✅ Réseaux `LIXEEGW` trouvés !");
      }
    } catch (e) {
      print("❌ Erreur lors du scan WiFi : $e");
    }
  }

  /// 🔌 Connexion à l'ESP et affichage du popup après succès
  void _connectToEsp(String ssid) async {
    String last4Chars = ssid.substring(ssid.length - 4);
    String password = "admin$last4Chars";

    print("🔌 Tentative de connexion à $ssid avec le mot de passe : $password");

    try {
      if (!_globalConnectingLock)
      {
        bool connected = await WiFiForIoTPlugin.connect(
          ssid,
          password: password,
          joinOnce: true,
          security: NetworkSecurity.WPA,
          withInternet: false, // 🔥 Empêche Android de couper la connexion
        );

        if (connected) {
          print("✅ Connecté à $ssid !");

          final bool success = (await MethodChannel('wifi_force_binder')
              .invokeMethod<bool>('bindNetwork', {"ssid": ssid})) ?? false;

          if (success) {
            print("✅ Connexion forcée au réseau $ssid !");
          } else {
            print("⚠ Échec du binding réseau, mais WiFi connecté.");
          }
          setState(() => _globalConnectingLock = false);
          // 👉 Afficher le popup après confirmation de connexion
          _showConfigWifiDialog(last4Chars);
        } else {
          print("❌ Échec de la connexion WiFi !");
        }
      }else{
        _showConfigWifiDialog(last4Chars);
      }
    } catch (e) {
      print("❌ Erreur de connexion WiFi : $e");
    }
  }

  /// 📌 Affichage du popup pour entrer les infos WiFi avec liste filtrée
  void _showConfigWifiDialog(String last4Chars) async {
    List<WifiNetwork> availableNetworks = [];

    try {
      List<WifiNetwork> wifiList = await WiFiForIoTPlugin.loadWifiList();
      Set<String> uniqueSSIDs = {};
      availableNetworks = wifiList.where((net) {
        if (net.ssid != null && uniqueSSIDs.add(net.ssid!)) return true;
        return false;
      }).toList();
    } catch (e) {
      print("❌ Erreur lors du scan WiFi : $e");
    }

    String? selectedSSID;
    String password = "";

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        bool obscurePassword = true;

        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(Icons.wifi, color: Color(0xFF1B75BC)),
                  SizedBox(width: 8),
                  Expanded(child: Text("Scan du WiFi")),
                  IconButton(
                    icon: Icon(Icons.info_outline, color: Colors.grey),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          content: Text("💡 Choisissez le réseau WiFi auquel l'appareil LIXEE devra se connecter après le provisioning. Entrez le mot de passe associé pour finaliser la configuration."),
                        ),
                      );
                    },
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: "Sélectionnez un réseau WiFi",
                      border: OutlineInputBorder(),
                    ),
                    items: availableNetworks.map((net) {
                      return DropdownMenuItem(
                        value: net.ssid,
                        child: Text(net.ssid ?? "SSID inconnu"),
                      );
                    }).toList(),
                    onChanged: (value) => selectedSSID = value,
                  ),
                  SizedBox(height: 12),
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Mot de passe WiFi",
                      border: OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscurePassword ? Icons.visibility_off : Icons.visibility,
                          color: Colors.grey,
                        ),
                        onPressed: () {
                          setState(() {
                            obscurePassword = !obscurePassword;
                          });
                        },
                      ),
                    ),
                    onChanged: (value) => password = value,
                    obscureText: obscurePassword,
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
                  icon: Icon(Icons.send),
                  label: Text("Envoyer"),
                  onPressed: () {
                    if (selectedSSID != null && password.isNotEmpty) {
                      Navigator.of(context).pop();
                      _startProvisioning(selectedSSID!, password, last4Chars);
                    } else {
                      print("❌ SSID ou mot de passe manquant");
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
      },
    );
  }

  void _startProvisioning(String ssid, String password, String last4Chars) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WebViewWifiPostScreen(
          ssid: ssid,
          password: password,
          deviceId: last4Chars
        ),
      ),
    );

    if (result == true) {
      print("📡 Provisioning réussi, ajout de l'appareil...");

      print("📡 Provisioning réussi, retour à HomeScreen...");

      Navigator.pop(context, true);

      try {
        final bool success = await MethodChannel('wifi_force_binder')
            .invokeMethod<bool>('unbindNetwork') ?? false;
        print(success
            ? "🔓 Débind réussi, retour au réseau par défaut."
            : "⚠️ Aucun réseau à débind.");
      } catch (e) {
        print("❌ Erreur lors du débind : $e");
      }

    } else {
      print("❌ Provisioning échoué, aucun appareil enregistré.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(title: Text("🔍 Appareils LiXee découverts")),
        body: Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: networks.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    title: Text(networks[index].ssid ?? "SSID inconnu"),
                    trailing: Icon(Icons.wifi,color: Color(0xFF1B75BC)),
                    onTap: () => _connectToEsp(networks[index].ssid ?? ""),
                  );
                },
              ),
            ),
          ],

        ),
        floatingActionButton: OutlinedButton.icon(
          onPressed: _scanForWifiNetworks,
          icon: Icon(Icons.refresh,size: 32),
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wifi_iot/wifi_iot.dart';
import 'webview_wifi_post_screen.dart';
import 'dart:io';

class WifiProvisionScreen extends StatefulWidget {
  const WifiProvisionScreen({super.key});

  @override
  _WifiProvisionScreenState createState() => _WifiProvisionScreenState();
}

class _WifiProvisionScreenState extends State<WifiProvisionScreen> {
  List<WifiNetwork> networks = [];
  List<String> manualNetworks = []; // Pour iOS - liste manuelle
  static bool _globalConnectingLock = false;
  bool isScanning = false;

  @override
  void initState() {
    super.initState();
    // Différer l'exécution du scan après que le widget soit complètement initialisé
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scanForWifiNetworks();
    });
  }

  /// 🔍 Scan des réseaux WiFi disponibles (Android) ou gestion manuelle (iOS)
  void _scanForWifiNetworks() async {
    setState(() => isScanning = true);
    print("📡 Scan des réseaux WiFi en cours...");

    if (Platform.isAndroid) {
      await _scanWifiAndroid();
    } else if (Platform.isIOS) {
      await _handleWifiIOS();
    }

    setState(() => isScanning = false);
  }

  /// 🤖 Scan WiFi pour Android
  Future<void> _scanWifiAndroid() async {
    try {
      List<WifiNetwork> wifiList = await WiFiForIoTPlugin.loadWifiList();

      // Filtrer les doublons
      Set<String> uniqueSSIDs = {};
      List<WifiNetwork> filteredList = wifiList.where((net) {
        if (net.ssid != null && uniqueSSIDs.add(net.ssid!)) {
          return true;
        }
        return false;
      }).toList();

      print("📡 Réseaux uniques détectés : ${filteredList.length}");

      setState(() {
        networks = filteredList
            .where((net) => net.ssid!.startsWith("LIXEEGW"))
            .toList();
      });

      if (networks.isEmpty) {
        print("❌ Aucun réseau `LIXEEGW` détecté !");
      } else {
        print("✅ Réseaux `LIXEEGW` trouvés : ${networks.length}");
        for (var net in networks) {
          print("📶 ${net.ssid}");
        }
      }
    } catch (e) {
      print("❌ Erreur lors du scan WiFi Android : $e");
      _showErrorDialog("Erreur de scan WiFi", "Impossible de scanner les réseaux WiFi. Vérifiez les permissions de localisation.");
    }
  }

  /// 🍎 Gestion WiFi pour iOS
  Future<void> _handleWifiIOS() async {
    print('📱 Mode iOS : Scan WiFi non disponible - approche manuelle disponible via le bouton +');

    // Sur iOS, on n'affiche pas automatiquement le dialog au démarrage
    // L'utilisateur devra utiliser le bouton d'ajout manually
    // Cela évite les problèmes de contexte dans initState()
  }

  /// 📝 Saisie manuelle de réseau pour iOS
  Future<void> _showManualNetworkInput() async {
    // Vérifier que le widget est toujours monté
    if (!mounted) return;

    String networkName = "";

    final result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.wifi_find, color: Color(0xFF1B75BC)),
              SizedBox(width: 8),
              Expanded(child: Text("Recherche d'appareil LiXee")),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Sur iOS, veuillez saisir le nom du réseau LiXee :",
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              ),
              SizedBox(height: 16),
              TextField(
                decoration: InputDecoration(
                  labelText: "Nom du réseau (ex: LIXEEGW1234)",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.wifi),
                  hintText: "LIXEEGW...",
                ),
                onChanged: (value) => networkName = value,
                autofocus: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text("Annuler"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(networkName),
              child: Text("Rechercher"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFF1B75BC),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        );
      },
    );

    if (result != null && result.isNotEmpty) {
      if (result.startsWith("LIXEEGW")) {
        setState(() {
          manualNetworks = [result];
          // Pour iOS, on utilise une approche simplifiée sans créer de WifiNetwork
          // On stocke juste le SSID et on l'affiche directement
        });
        print("✅ Réseau ajouté manuellement : $result");
      } else {
        _showErrorDialog("Format incorrect", "Le nom du réseau doit commencer par 'LIXEEGW'");
      }
    }
  }

  /// 🔌 Connexion à l'ESP avec gestion plateforme
  void _connectToEsp(String ssid) async {
    String last4Chars = ssid.substring(ssid.length - 4);
    String password = "admin$last4Chars";

    print("🔌 Tentative de connexion à $ssid");
    print("📱 Plateforme détectée : ${Platform.isIOS ? 'iOS' : 'Android'}");

    try {
      if (!_globalConnectingLock) {
        setState(() => _globalConnectingLock = true);

        bool connected = false;

        if (Platform.isAndroid) {
          print("🤖 Utilisation de la connexion Android");
          connected = await _connectAndroidWifi(ssid, password);
        } else if (Platform.isIOS) {
          print("🍎 Utilisation de la connexion iOS");
          connected = await _connectIOSWifi(ssid, password);
        }

        setState(() => _globalConnectingLock = false);

        if (connected) {
          print("✅ Processus de connexion terminé avec succès");
          // Attendre un peu avant de continuer pour laisser le temps à l'utilisateur
          await Future.delayed(Duration(seconds: 2));
          _showConfigWifiDialog(last4Chars);
        } else {
          print("❌ Échec du processus de connexion");
          _showErrorDialog("Connexion échouée", "Impossible de se connecter au réseau $ssid");
        }
      } else {
        print("🔒 Connexion déjà en cours, passage direct à la configuration");
        _showConfigWifiDialog(last4Chars);
      }
    } catch (e) {
      setState(() => _globalConnectingLock = false);
      print("❌ Erreur de connexion WiFi : $e");
      _showErrorDialog("Erreur de connexion", "Erreur lors de la connexion : ${e.toString()}");
    }
  }

  /// 🤖 Connexion WiFi Android
  Future<bool> _connectAndroidWifi(String ssid, String password) async {
    try {
      bool connected = await WiFiForIoTPlugin.connect(
        ssid,
        password: password,
        joinOnce: true,
        security: NetworkSecurity.WPA,
        withInternet: false,
      );

      if (connected) {
        // Binding réseau spécifique Android
        try {
          final bool success = (await MethodChannel('wifi_force_binder')
              .invokeMethod<bool>('bindNetwork', {"ssid": ssid})) ?? false;

          if (success) {
            print("✅ Connexion forcée au réseau $ssid !");
          } else {
            print("⚠ Échec du binding réseau, mais WiFi connecté.");
          }
        } catch (e) {
          print("⚠️ Binding réseau non disponible : $e");
        }
      }

      return connected;
    } catch (e) {
      print("❌ Erreur connexion Android : $e");
      return false;
    }
  }

  /// 🍎 Connexion WiFi iOS
  Future<bool> _connectIOSWifi(String ssid, String password) async {
    print("🍎 Connexion iOS à $ssid");

    try {
      // Sur iOS, on essaie d'abord la connexion automatique
      bool connected = await WiFiForIoTPlugin.connect(
        ssid,
        password: password,
        joinOnce: true,
        security: NetworkSecurity.WPA,
      );

      if (connected) {
        print("✅ Connexion automatique iOS réussie à $ssid");
        return true;
      } else {
        print("⚠️ Connexion automatique échouée sur iOS (normal)");
        // Sur iOS, on procède directement à la configuration manuelle
        // L'utilisateur se connectera manuellement et on continue le processus
        await _showIOSWifiInstructions(ssid, password);
        return true; // On considère que l'utilisateur peut se connecter
      }
    } catch (e) {
      print("❌ Erreur connexion iOS : $e");
      // Même en cas d'erreur, on continue avec les instructions manuelles
      await _showIOSWifiInstructions(ssid, password);
      return true;
    }
  }

  /// 📱 Instructions de connexion manuelle pour iOS
  Future<void> _showIOSWifiInstructions(String ssid, String password) async {
    await showDialog(
      context: context,
      barrierDismissible: false, // Force l'utilisateur à lire les instructions
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.settings, color: Color(0xFF1B75BC)),
              SizedBox(width: 8),
              Expanded(child: Text("Connexion manuelle requise")),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange[200]!),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info, color: Colors.orange[700]),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Sur iOS, la connexion automatique n'est pas disponible",
                          style: TextStyle(color: Colors.orange[800], fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 16),
                Text("Connectez-vous manuellement au réseau :"),
                SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.wifi, size: 16),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              "Réseau : $ssid",
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.lock, size: 16),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              "Mot de passe : $password",
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  "📱 Étapes à suivre :",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "1. Allez dans Réglages > WiFi\n2. Sélectionnez $ssid\n3. Entrez le mot de passe\n4. Revenez dans l'app",
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                ),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.green[50],
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    "💡 Une fois connecté, appuyez sur 'Continuer' pour poursuivre la configuration",
                    style: TextStyle(fontSize: 12, color: Colors.green[700]),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            OutlinedButton.icon(
              icon: Icon(Icons.settings),
              label: Text("Ouvrir Réglages"),
              onPressed: () async {
                try {
                  // Essayer d'ouvrir les réglages WiFi
                  await MethodChannel('system_settings')
                      .invokeMethod('openWifiSettings');
                } catch (e) {
                  print("Impossible d'ouvrir les réglages automatiquement");
                }
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey[600],
                side: BorderSide(color: Colors.grey[400]!),
              ),
            ),
            ElevatedButton.icon(
              icon: Icon(Icons.arrow_forward),
              label: Text("Continuer"),
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFF1B75BC),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 📌 Dialog de configuration WiFi adapté pour iOS
  void _showConfigWifiDialog(String last4Chars) async {
    List<WifiNetwork> availableNetworks = [];

    if (Platform.isAndroid) {
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
    } else {
      // Pour iOS, utiliser une saisie manuelle
      await _showIOSWifiConfigDialog(last4Chars);
      return;
    }

    // Dialog Android (code existant)
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
                  Expanded(child: Text("Configuration WiFi")),
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

  /// 🍎 Dialog de configuration WiFi pour iOS (saisie manuelle)
  Future<void> _showIOSWifiConfigDialog(String last4Chars) async {
    String ssid = "";
    String password = "";

    final result = await showDialog<Map<String, String>>(
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
                  Expanded(child: Text("Configuration WiFi")),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Entrez les informations du réseau WiFi auquel l'appareil LiXee doit se connecter :",
                    style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Nom du réseau WiFi (SSID)",
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.wifi),
                    ),
                    onChanged: (value) => ssid = value,
                  ),
                  SizedBox(height: 12),
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Mot de passe WiFi",
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock),
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
                    if (ssid.isNotEmpty && password.isNotEmpty) {
                      Navigator.of(context).pop({"ssid": ssid, "password": password});
                    } else {
                      _showErrorDialog("Champs requis", "Veuillez remplir tous les champs");
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

    if (result != null) {
      _startProvisioning(result["ssid"]!, result["password"]!, last4Chars);
    }
  }

  /// 🚀 Démarrage du provisioning
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
      print("📡 Provisioning réussi, retour à HomeScreen...");
      Navigator.pop(context, true);

      // Débind réseau (Android seulement)
      if (Platform.isAndroid) {
        try {
          final bool success = await MethodChannel('wifi_force_binder')
              .invokeMethod<bool>('unbindNetwork') ?? false;
          print(success
              ? "🔓 Débind réussi, retour au réseau par défaut."
              : "⚠️ Aucun réseau à débind.");
        } catch (e) {
          print("❌ Erreur lors du débind : $e");
        }
      }
    } else {
      print("❌ Provisioning échoué, aucun appareil enregistré.");
    }
  }

  /// 🚨 Affichage des erreurs
  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.error, color: Colors.red),
              SizedBox(width: 8),
              Expanded(child: Text(title)),
            ],
          ),
          content: Text(message),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text("OK"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFF1B75BC),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 📱 Helper methods pour gérer les différences iOS/Android
  List<dynamic> _getNetworkList() {
    if (Platform.isIOS) {
      return manualNetworks;
    } else {
      return networks;
    }
  }

  String _getNetworkName(int index) {
    if (Platform.isIOS) {
      return index < manualNetworks.length ? manualNetworks[index] : "";
    } else {
      return index < networks.length ? (networks[index].ssid ?? "") : "";
    }
  }

  /// 🔍 Vérifier la connexion actuelle (utile pour iOS)
  Future<bool> _checkCurrentConnection(String expectedSSID) async {
    try {
      String? currentSSID = await WiFiForIoTPlugin.getSSID();
      print("📡 SSID actuel : ${currentSSID ?? 'null'}");
      print("📡 SSID attendu : $expectedSSID");

      if (currentSSID != null && currentSSID.contains(expectedSSID)) {
        print("✅ Connecté au bon réseau !");
        return true;
      } else {
        print("⚠️ Pas connecté au bon réseau");
        return false;
      }
    } catch (e) {
      print("❌ Impossible de vérifier la connexion : $e");
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: Text(Platform.isIOS
              ? "🔍 Recherche d'appareils LiXee"
              : "🔍 Appareils LiXee découverts"),
          backgroundColor: Color(0xFF1B75BC),
          foregroundColor: Colors.white,
        ),
        body: Column(
          children: [
            // Indicateur de scan
            if (isScanning)
              Container(
                padding: EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF1B75BC)),
                    SizedBox(width: 16),
                    Expanded(child: Text("Recherche en cours...")),
                  ],
                ),
              ),

            // Message d'aide pour iOS
            if (Platform.isIOS && _getNetworkList().isEmpty && !isScanning)
              Container(
                margin: EdgeInsets.all(16),
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info, color: Color(0xFF1B75BC)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "Information iOS",
                            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue[800]),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      "Sur iOS, la recherche automatique des réseaux WiFi n'est pas disponible. Appuyez sur le bouton 'Ajouter' pour saisir manuellement le nom de votre appareil LiXee.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.blue[800]),
                    ),
                  ],
                ),
              ),

            // Liste des réseaux
            Expanded(
              child: _getNetworkList().isEmpty && !isScanning
                  ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.wifi_off, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text(
                      Platform.isIOS
                          ? "Aucun appareil ajouté.\nUtilisez le bouton de recherche."
                          : "Aucun appareil LiXee détecté.\nAssurez-vous qu'ils sont en mode provisioning.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              )
                  : ListView.builder(
                itemCount: _getNetworkList().length,
                itemBuilder: (context, index) {
                  String networkName = _getNetworkName(index);
                  return Card(
                    margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: ListTile(
                      leading: Icon(Icons.router, color: Color(0xFF1B75BC)),
                      title: Text(networkName.isNotEmpty ? networkName : "SSID inconnu"),
                      subtitle: Text("Appareil LiXee détecté"),
                      trailing: Icon(Icons.arrow_forward_ios, color: Color(0xFF1B75BC)),
                      onTap: () => _connectToEsp(networkName),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: isScanning ? null : () {
            if (Platform.isIOS) {
              _showManualNetworkInput();
            } else {
              _scanForWifiNetworks();
            }
          },
          backgroundColor: Color(0xFF1B75BC),
          foregroundColor: Colors.white,
          icon: isScanning
              ? SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          )
              : Icon(Platform.isIOS ? Icons.add : Icons.refresh),
          label: Text(isScanning
              ? "Recherche..."
              : Platform.isIOS
              ? "Ajouter"
              : "Actualiser"),
        ),
      ),
    );
  }
}
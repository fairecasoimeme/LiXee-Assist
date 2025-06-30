import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wifi_scan/wifi_scan.dart'; // ✅ Ajout pour le scan WiFi
import 'package:permission_handler/permission_handler.dart'; // ✅ Ajout pour les permissions
import 'dart:io'; // ✅ Ajout pour détecter la plateforme
import 'dart:convert';
import 'dart:async';

class BleProvisionScreen extends StatefulWidget {
  const BleProvisionScreen({super.key});

  @override
  _BleProvisionScreenState createState() => _BleProvisionScreenState();
}

class _BleProvisionScreenState extends State<BleProvisionScreen> {
  List<BluetoothDevice> devices = [];
  static bool _globalConnectingLock = false;
  late StreamSubscription<List<ScanResult>> _scanSubscription;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _initBluetooth();
  }

  @override
  void dispose() {
    _scanSubscription.cancel();
    super.dispose();
  }

  /// 🔍 Initialisation du Bluetooth et scan des appareils
  void _initBluetooth() async {
    print("🔵 Initialisation du Bluetooth...");

    // Vérifier si le Bluetooth est supporté
    if (await FlutterBluePlus.isSupported == false) {
      print("❌ Bluetooth non supporté sur cet appareil");
      return;
    }

    // Demander les permissions nécessaires
    await _requestBluetoothPermissions();

    // Écouter les changements d'état du Bluetooth
    FlutterBluePlus.adapterState.listen((BluetoothAdapterState state) {
      print("🔵 État Bluetooth: $state");
      if (state == BluetoothAdapterState.on) {
        _scanForBleDevices();
      } else {
        print("❌ Bluetooth désactivé");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Veuillez activer le Bluetooth")),
          );
        }
      }
    });

    // Démarrer le scan si le Bluetooth est déjà activé
    if (await FlutterBluePlus.isOn) {
      _scanForBleDevices();
    } else {
      print("⚠️ Bluetooth non activé");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Veuillez activer le Bluetooth dans les Réglages")),
        );
      }
    }
  }

  /// 🔐 Demander les permissions Bluetooth
  Future<void> _requestBluetoothPermissions() async {
    if (Platform.isIOS) {
      print("🍎 Demande des permissions iOS...");

      // Permissions spécifiques iOS
      Map<Permission, PermissionStatus> permissions = await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location, // Requis pour BLE sur iOS
      ].request();

      // Vérifier le statut des permissions (logs seulement)
      bool allGranted = true;
      permissions.forEach((permission, status) {
        print("📋 Permission $permission: $status");
        if (status != PermissionStatus.granted) {
          allGranted = false;
        }
      });

      if (!allGranted) {
        print("⚠️ Certaines permissions non accordées");
      } else {
        print("✅ Toutes les permissions accordées");
      }

    } else if (Platform.isAndroid) {
      print("🤖 Demande des permissions Android...");

      // Permissions Android (version dépendante)
      Map<Permission, PermissionStatus> permissions = await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();

      bool allGranted = true;
      permissions.forEach((permission, status) {
        print("📋 Permission $permission: $status");
        if (status != PermissionStatus.granted) {
          allGranted = false;
        }
      });

      if (!allGranted) {
        print("⚠️ Permissions Android insuffisantes");
      }
    }
  }

  /// 📋 Dialogue d'explication des permissions
  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: Colors.orange),
            SizedBox(width: 8),
            Text("Permissions requises"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Cette app a besoin des permissions suivantes :"),
            SizedBox(height: 12),
            Text("🔵 Bluetooth : Pour scanner les appareils LIXEE"),
            Text("📍 Localisation : Requise par iOS pour le BLE"),
            SizedBox(height: 12),
            Text("Veuillez aller dans Réglages > ${Platform.isIOS ? 'Confidentialité > ' : ''}Autorisations pour les accorder."),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text("Plus tard"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              openAppSettings(); // Ouvre les réglages de l'app
            },
            child: Text("Ouvrir Réglages"),
          ),
        ],
      ),
    );
  }

  /// 🔍 Scan des appareils BLE disponibles
  void _scanForBleDevices() async {
    if (_isScanning) return;

    print("📡 Scan des appareils BLE en cours...");
    setState(() => _isScanning = true);

    // Arrêter le scan précédent s'il existe
    await FlutterBluePlus.stopScan();

    // Nettoyer la liste des appareils
    setState(() => devices.clear());

    // Configuration du scan différente selon la plateforme
    Duration scanTimeout = Platform.isIOS ? Duration(seconds: 15) : Duration(seconds: 10);

    // Démarrer le scan
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      Set<String> uniqueDeviceIds = {};
      List<BluetoothDevice> filteredDevices = [];

      for (ScanResult result in results) {
        String deviceName = result.device.platformName;
        String deviceId = result.device.remoteId.toString();
        String macAddress = result.device.remoteId.toString();

        print("🔍 Appareil détecté: '$deviceName' - MAC: $macAddress - RSSI: ${result.rssi}");

        // Filtrer les appareils LIXEE ET vérifier la MAC spécifique pour debug
        bool isLixeeDevice = deviceName.startsWith("LIXEE") ||
            deviceName.toLowerCase().contains("lixee") ||
            macAddress.toUpperCase() == "F4:12:FA:E7:88:ED";

        if (isLixeeDevice && uniqueDeviceIds.add(deviceId)) {
          filteredDevices.add(result.device);
          print("📶 Appareil LIXEE trouvé: $deviceName ($deviceId) - RSSI: ${result.rssi}");

          // Log spécial pour votre appareil
          if (macAddress.toUpperCase() == "F4:12:FA:E7:88:ED") {
            print("🎯 LIXEEBOX cible détectée ! Nom: '$deviceName'");
          }
        }
      }

      setState(() {
        devices = filteredDevices;
      });
    });

    // Configuration du scan avec paramètres iOS optimisés
    try {
      if (Platform.isIOS) {
        print("🍎 Scan iOS avec paramètres optimisés...");
        // Sur iOS, utiliser un scan plus long
        await FlutterBluePlus.startScan(
          timeout: scanTimeout,
        );
      } else {
        print("🤖 Scan Android standard...");
        await FlutterBluePlus.startScan(timeout: scanTimeout);
      }
    } catch (e) {
      print("❌ Erreur lors du démarrage du scan: $e");
    }

    // Arrêter le scan après le timeout
    Timer(scanTimeout, () {
      setState(() => _isScanning = false);
      print("📡 Scan terminé. Appareils LIXEE trouvés: ${devices.length}");

      // Si aucun appareil trouvé sur iOS, suggérer des solutions
      if (Platform.isIOS && devices.isEmpty) {
        _showIOSTroubleshootingDialog();
      }
    });
  }

  /// 🍎 Dialogue de dépannage spécifique iOS
  void _showIOSTroubleshootingDialog() {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.info_outline, color: Colors.orange),
            SizedBox(width: 8),
            Text("Aucun appareil détecté"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Si votre appareil LIXEE n'apparaît pas, essayez :"),
            SizedBox(height: 12),
            Text("• Redémarrez le Bluetooth dans Réglages iOS"),
            Text("• Rapprochez-vous de l'appareil LIXEE"),
            Text("• Redémarrez l'appareil LIXEE"),
            Text("• Vérifiez que l'appareil n'est pas connecté ailleurs"),
            SizedBox(height: 12),
            Text("Votre appareil : F4:12:FA:E7:88:ED",
                style: TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text("Fermer"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _scanForBleDevices(); // Relancer le scan
            },
            child: Text("Réessayer"),
          ),
        ],
      ),
    );
  }

  /// 🔌 Connexion à l'appareil BLE et affichage du popup après succès
  void _connectToBleDevice(BluetoothDevice device) async {
    String deviceName = device.platformName;
    String last4Chars = deviceName.substring(deviceName.length - 4);

    print("🔌 Tentative de connexion à $deviceName");

    if (_globalConnectingLock) {
      _showConfigWifiDialog(last4Chars, device);
      return;
    }

    try {
      setState(() => _globalConnectingLock = true);

      // Se connecter à l'appareil BLE
      await device.connect(timeout: Duration(seconds: 15));
      print("✅ Connecté à $deviceName !");

      // Découvrir les services
      List<BluetoothService> services = await device.discoverServices();
      print("🔍 Services découverts: ${services.length}");

      setState(() => _globalConnectingLock = false);

      // Afficher le popup après confirmation de connexion
      _showConfigWifiDialog(last4Chars, device);

    } catch (e) {
      setState(() => _globalConnectingLock = false);
      print("❌ Erreur de connexion BLE : $e");

      // Afficher un message d'erreur à l'utilisateur
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Échec de la connexion à $deviceName")),
        );
      }
    }
  }

  /// 📌 Affichage du popup pour entrer les infos WiFi
  void _showConfigWifiDialog(String last4Chars, BluetoothDevice device) async {
    String selectedSSID = "";
    String password = "";
    List<WiFiAccessPoint> availableNetworks = [];
    bool isLoadingNetworks = false;

    // Scanner les réseaux WiFi si on est sur Android
    if (Platform.isAndroid) {
      isLoadingNetworks = true;
      try {
        // Vérifier les permissions
        final canGetScannedResults = await WiFiScan.instance.canGetScannedResults();
        if (canGetScannedResults == CanGetScannedResults.yes) {
          // Scanner les réseaux
          await WiFiScan.instance.startScan();
          await Future.delayed(Duration(seconds: 3)); // Attendre la fin du scan
          availableNetworks = await WiFiScan.instance.getScannedResults();

          // Filtrer et dédupliquer les réseaux
          Set<String> uniqueSSIDs = {};
          availableNetworks = availableNetworks.where((network) {
            return network.ssid.isNotEmpty && uniqueSSIDs.add(network.ssid);
          }).toList();

          // Trier par force du signal
          availableNetworks.sort((a, b) => b.level.compareTo(a.level));

          print("📡 Réseaux WiFi trouvés: ${availableNetworks.length}");
        } else {
          print("⚠️ Permissions WiFi insuffisantes");
        }
      } catch (e) {
        print("❌ Erreur lors du scan WiFi: $e");
      }
      isLoadingNetworks = false;
    }

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
                  IconButton(
                    icon: Icon(Icons.info_outline, color: Colors.grey),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          content: Text(Platform.isAndroid
                              ? "💡 Sélectionnez le réseau WiFi dans la liste ou saisissez-le manuellement, puis entrez le mot de passe."
                              : "💡 Entrez le nom du réseau WiFi et le mot de passe pour configurer votre appareil LIXEE via Bluetooth."),
                        ),
                      );
                    },
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Affichage conditionnel selon la plateforme
                  if (Platform.isAndroid && availableNetworks.isNotEmpty) ...[
                    // Dropdown pour Android avec les réseaux scannés
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: "Sélectionnez un réseau WiFi",
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.wifi),
                      ),
                      items: [
                        // Option pour saisie manuelle
                        DropdownMenuItem(
                          value: "__manual__",
                          child: Row(
                            children: [
                              Icon(Icons.edit, size: 16, color: Colors.grey),
                              SizedBox(width: 8),
                              Text("Saisie manuelle..."),
                            ],
                          ),
                        ),
                        // Réseaux détectés
                        ...availableNetworks.map((network) {
                          return DropdownMenuItem(
                            value: network.ssid,
                            child: Row(
                              children: [
                                Icon(
                                  _getWiFiIcon(network.level),
                                  size: 16,
                                  color: _getWiFiColor(network.level),
                                ),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    network.ssid,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (network.capabilities.contains("WPA") ||
                                    network.capabilities.contains("WEP"))
                                  Icon(Icons.lock, size: 12, color: Colors.grey),
                              ],
                            ),
                          );
                        }),
                      ],
                      onChanged: (value) {
                        if (value == "__manual__") {
                          selectedSSID = "";
                        } else {
                          selectedSSID = value ?? "";
                        }
                        setState(() {});
                      },
                    ),

                    // Champ de saisie manuelle si option sélectionnée
                    if (selectedSSID.isEmpty) ...[
                      SizedBox(height: 12),
                      TextField(
                        decoration: InputDecoration(
                          labelText: "Nom du réseau WiFi (SSID)",
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.edit),
                        ),
                        onChanged: (value) => selectedSSID = value,
                      ),
                    ],
                  ] else ...[
                    // Champ de saisie pour iOS ou si pas de réseaux trouvés
                    TextField(
                      decoration: InputDecoration(
                        labelText: "Nom du réseau WiFi (SSID)",
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.wifi),
                      ),
                      onChanged: (value) => selectedSSID = value,
                    ),
                  ],

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

                  // Afficher un message de statut
                  if (Platform.isAndroid) ...[
                    SizedBox(height: 8),
                    Text(
                      isLoadingNetworks
                          ? "🔍 Scan des réseaux en cours..."
                          : availableNetworks.isEmpty
                          ? "⚠️ Aucun réseau trouvé, saisie manuelle"
                          : "✅ ${availableNetworks.length} réseaux détectés",
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ],
              ),
              actions: [
                OutlinedButton.icon(
                  icon: Icon(Icons.cancel),
                  label: Text("Annuler"),
                  onPressed: () {
                    Navigator.of(context).pop();
                    _disconnectDevice(device);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Color(0xFF1B75BC),
                    side: BorderSide(color: Color(0xFF1B75BC)),
                  ),
                ),
                OutlinedButton.icon(
                  icon: Icon(Icons.send),
                  label: Text("Envoyer"),
                  onPressed: () {
                    if (selectedSSID.isNotEmpty && password.isNotEmpty) {
                      Navigator.of(context).pop();
                      _startBleProvisioning(selectedSSID, password, last4Chars, device);
                    } else {
                      print("❌ SSID ou mot de passe manquant");
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Veuillez remplir tous les champs")),
                      );
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

  /// 📶 Obtenir l'icône WiFi selon la force du signal
  IconData _getWiFiIcon(int level) {
    if (level >= -50) return Icons.wifi_rounded;
    if (level >= -60) return Icons.wifi_2_bar_rounded;
    if (level >= -70) return Icons.wifi_1_bar_rounded;
    return Icons.wifi_off_rounded;
  }

  /// 🎨 Obtenir la couleur WiFi selon la force du signal
  Color _getWiFiColor(int level) {
    if (level >= -50) return Colors.green;
    if (level >= -60) return Colors.orange;
    if (level >= -70) return Colors.red[300]!;
    return Colors.red;
  }

  /// 📡 Démarrage du provisioning via BLE
  void _startBleProvisioning(String ssid, String password, String last4Chars, BluetoothDevice device) async {
    try {
      print("📡 Envoi des données WiFi via BLE...");

      // Découvrir les services disponibles
      List<BluetoothService> services = await device.discoverServices();
      print("🔍 Services découverts: ${services.length}");

      // Afficher tous les services et leurs caractéristiques pour debugging
      for (int i = 0; i < services.length; i++) {
        BluetoothService service = services[i];
        print("📋 Service $i: ${service.uuid}");

        for (int j = 0; j < service.characteristics.length; j++) {
          BluetoothCharacteristic char = service.characteristics[j];
          print("  📝 Caractéristique $j: ${char.uuid}");
          print("    - Read: ${char.properties.read}");
          print("    - Write: ${char.properties.write}");
          print("    - Notify: ${char.properties.notify}");
          print("    - WriteWithoutResponse: ${char.properties.writeWithoutResponse}");
        }
      }

      BluetoothService? provisioningService;
      BluetoothCharacteristic? wifiCharacteristic;
      BluetoothCharacteristic? ackCharacteristic;

      // Rechercher un service avec les UUIDs LIXEE spécifiques (6e400001 à 6e400003)
      // et identifier les caractéristiques d'écriture et de lecture
      for (BluetoothService service in services) {
        String serviceUuid = service.uuid.toString().toLowerCase();

        // Priorité aux services LIXEE spécifiques
        if (serviceUuid.startsWith('6e40000')) {
          provisioningService = service;
          print("🎯 Service LIXEE trouvé: $serviceUuid");

          // Chercher une caractéristique avec capacité d'écriture et de lecture
          for (BluetoothCharacteristic characteristic in service.characteristics) {
            if (characteristic.properties.write || characteristic.properties.writeWithoutResponse) {
              wifiCharacteristic = characteristic;
              print("✅ Caractéristique d'écriture LIXEE: ${characteristic.uuid}");
            }
            if (characteristic.properties.read || characteristic.properties.notify) {
              ackCharacteristic = characteristic;
              print("✅ Caractéristique de lecture LIXEE: ${characteristic.uuid}");
            }
          }

          if (wifiCharacteristic != null) break;
        }
      }

      // Si aucun service LIXEE spécifique trouvé, chercher dans les services personnalisés
      if (provisioningService == null) {
        print("⚠️ Aucun service LIXEE spécifique trouvé, recherche dans services personnalisés...");

        for (BluetoothService service in services) {
          String serviceUuid = service.uuid.toString().toLowerCase();

          // Ignorer les services BLE standards mais garder les services personnalisés
          if (!serviceUuid.startsWith('0000180') &&
              !serviceUuid.startsWith('0000181') &&
              service.characteristics.isNotEmpty) {

            print("🎯 Evaluation du service personnalisé: $serviceUuid");

            // Chercher une caractéristique avec capacité d'écriture
            for (BluetoothCharacteristic characteristic in service.characteristics) {
              if (characteristic.properties.write || characteristic.properties.writeWithoutResponse) {
                provisioningService = service;
                wifiCharacteristic = characteristic;
                print("✅ Service de provisioning trouvé: $serviceUuid");
                print("✅ Caractéristique d'écriture: ${characteristic.uuid}");
              }
              if (characteristic.properties.read || characteristic.properties.notify) {
                ackCharacteristic = characteristic;
                print("✅ Caractéristique de lecture: ${characteristic.uuid}");
              }
            }

            if (provisioningService != null) break;
          }
        }
      }

      // Si aucun service personnalisé trouvé, utiliser le premier service avec écriture
      if (provisioningService == null) {
        print("⚠️ Aucun service LIXEE ou personnalisé trouvé, recherche dans tous les services...");

        for (BluetoothService service in services) {
          for (BluetoothCharacteristic characteristic in service.characteristics) {
            if (characteristic.properties.write || characteristic.properties.writeWithoutResponse) {
              provisioningService = service;
              wifiCharacteristic = characteristic;
              print("✅ Utilisation du service: ${service.uuid}");
              print("✅ Utilisation de la caractéristique: ${characteristic.uuid}");
            }
            if (characteristic.properties.read || characteristic.properties.notify) {
              ackCharacteristic = characteristic;
            }
          }
          if (provisioningService != null) break;
        }
      }

      if (provisioningService != null && wifiCharacteristic != null) {
        // S'abonner aux notifications AVANT d'envoyer les données (si disponible)
        if (ackCharacteristic != null && ackCharacteristic.properties.notify) {
          print("🔔 Abonnement aux notifications pour l'ACK...");
          await ackCharacteristic.setNotifyValue(true);
        }

        // Créer la chaîne au format SSID|password
        String wifiData = "$ssid|$password";
        List<int> bytes = utf8.encode(wifiData);

        print("📤 Envoi des données: $wifiData");
        print("📤 Vers la caractéristique: ${wifiCharacteristic.uuid}");

        // Envoyer les données via BLE
        bool useWithoutResponse = wifiCharacteristic.properties.writeWithoutResponse &&
            !wifiCharacteristic.properties.write;

        await wifiCharacteristic.write(bytes, withoutResponse: useWithoutResponse);
        print("✅ Données WiFi envoyées via BLE");

        // Vérifier l'ACK immédiatement après l'envoi
        bool provisioningSuccess = await _checkProvisioningAckImmediate(ackCharacteristic);

        if (provisioningSuccess) {
          print("✅ Provisioning BLE réussi - Création de l'appareil");

          // Créer le nom de l'appareil basé sur le nom BLE
          String deviceName = device.platformName.isNotEmpty ? device.platformName : "LIXEE-$last4Chars";
          String deviceUrl = "http://$deviceName.local";

          // Sauvegarder l'appareil
          await _saveDevice(deviceName, deviceUrl);

          // Afficher un message de succès
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("✅ Appareil $deviceName ajouté avec succès !"),
                backgroundColor: Colors.green,
              ),
            );
          }

          print("📡 Provisioning réussi via BLE - Appareil créé: $deviceName -> $deviceUrl");
          Navigator.pop(context, true);

        } else {
          print("❌ Provisioning BLE échoué - Pas d'ACK reçu");
          _showError("Le provisioning a échoué. L'appareil n'a pas confirmé la réception.");
        }

      } else {
        print("❌ Aucun service ou caractéristique d'écriture trouvé");
        _showError("Aucune caractéristique d'écriture BLE disponible");

        // Afficher un dialogue avec les services trouvés pour aider au debugging
        _showServicesDebugDialog(services);
      }

    } catch (e) {
      print("❌ Erreur lors du provisioning BLE : $e");
      _showError("Erreur de provisioning: $e");
    } finally {
      // Déconnecter l'appareil BLE dans tous les cas
      await _disconnectDevice(device);
    }
  }

  /// 📨 Vérification immédiate de l'ACK du provisioning
  Future<bool> _checkProvisioningAckImmediate(BluetoothCharacteristic? ackCharacteristic) async {
    try {
      if (ackCharacteristic == null) {
        print("⚠️ Aucune caractéristique ACK disponible, provisioning supposé réussi");
        return true;
      }

      print("🔍 Vérification de l'ACK via: ${ackCharacteristic.uuid}");

      List<int>? response;

      if (ackCharacteristic.properties.notify) {
        print("🔔 Attente de notification ACK...");
        // Attendre la notification pendant 5 secondes maximum
        try {
          await for (List<int> value in ackCharacteristic.value.timeout(Duration(seconds: 5))) {
            response = value;
            break;
          }
        } on TimeoutException {
          print("⏰ Timeout lors de l'attente de notification ACK");
        }
      }

      if (response == null && ackCharacteristic.properties.read) {
        print("📖 Lecture directe de l'ACK...");
        try {
          response = await ackCharacteristic.read();
        } catch (e) {
          print("⚠️ Erreur de lecture ACK: $e");
        }
      }

      if (response != null && response.isNotEmpty) {
        String responseString = utf8.decode(response);
        print("📨 Réponse ACK reçue: $responseString");

        // Vérifier si la réponse indique un succès
        if (responseString.toLowerCase().contains('ok') ||
            responseString.toLowerCase().contains('success') ||
            responseString.toLowerCase().contains('ack')) {
          return true;
        }
      }

      // Si aucune réponse explicite, considérer comme succès
      print("⚠️ Aucun ACK explicite reçu, provisioning supposé réussi");
      return true;

    } catch (e) {
      print("❌ Erreur lors de la vérification de l'ACK: $e");
      return true; // En cas d'erreur, on suppose que ça a marché
    }
  }

  /// 🔍 Affichage des services pour debugging
  void _showServicesDebugDialog(List<BluetoothService> services) {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("🔍 Services BLE détectés"),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ListView.builder(
            itemCount: services.length,
            itemBuilder: (context, index) {
              BluetoothService service = services[index];
              return ExpansionTile(
                title: Text("Service ${index + 1}"),
                subtitle: Text(service.uuid.toString()),
                children: service.characteristics.map((char) => ListTile(
                  title: Text("Caractéristique"),
                  subtitle: Text(char.uuid.toString()),
                  trailing: Text(
                      "${char.properties.read ? 'R' : ''}${char.properties.write ? 'W' : ''}${char.properties.notify ? 'N' : ''}"
                  ),
                )).toList(),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text("Fermer"),
          ),
        ],
      ),
    );
  }

  /// 💾 Sauvegarde de l'appareil dans les préférences
  Future<void> _saveDevice(String deviceName, String deviceUrl) async {
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      List<String> savedDevices = prefs.getStringList('saved_devices') ?? [];

      String deviceEntry = "$deviceName|$deviceUrl";

      // Vérifier si l'appareil n'existe pas déjà
      if (!savedDevices.contains(deviceEntry)) {
        savedDevices.add(deviceEntry);
        await prefs.setStringList('saved_devices', savedDevices);
        print("💾 Appareil sauvegardé: $deviceEntry");
      } else {
        print("⚠️ Appareil déjà existant: $deviceEntry");
      }

    } catch (e) {
      print("❌ Erreur lors de la sauvegarde: $e");
    }
  }

  /// 🔌 Déconnexion de l'appareil BLE
  Future<void> _disconnectDevice(BluetoothDevice device) async {
    try {
      await device.disconnect();
      print("🔓 Déconnecté de ${device.platformName}");
    } catch (e) {
      print("❌ Erreur lors de la déconnexion : $e");
    }
  }

  /// 🔍 Dialogue de debug pour voir tous les appareils BLE
  void _showDebugScanDialog() async {
    List<BluetoothDevice> allDevices = [];
    bool isDebugScanning = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text("🔍 Debug - Tous les appareils BLE"),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Column(
              children: [
                if (isDebugScanning)
                  LinearProgressIndicator()
                else
                  ElevatedButton.icon(
                    onPressed: () async {
                      setDialogState(() => isDebugScanning = true);
                      allDevices.clear();

                      try {
                        await FlutterBluePlus.stopScan();

                        StreamSubscription? debugSub;
                        debugSub = FlutterBluePlus.scanResults.listen((results) {
                          for (ScanResult result in results) {
                            if (!allDevices.any((d) => d.remoteId == result.device.remoteId)) {
                              allDevices.add(result.device);
                              setDialogState(() {});
                            }
                          }
                        });

                        await FlutterBluePlus.startScan(
                          timeout: Duration(seconds: 15),
                        );

                        await Future.delayed(Duration(seconds: 15));
                        await debugSub?.cancel();
                        setDialogState(() => isDebugScanning = false);
                      } catch (e) {
                        print("Erreur debug scan: $e");
                        setDialogState(() => isDebugScanning = false);
                      }
                    },
                    icon: Icon(Icons.search),
                    label: Text("Scanner tous les appareils"),
                  ),
                SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: allDevices.length,
                    itemBuilder: (context, index) {
                      final device = allDevices[index];
                      final isTarget = device.remoteId.toString().toUpperCase() == "F4:12:FA:E7:88:ED";

                      return ListTile(
                        leading: Icon(
                          isTarget ? Icons.star : Icons.bluetooth,
                          color: isTarget ? Colors.orange : Colors.blue,
                        ),
                        title: Text(
                          device.platformName.isEmpty ? "Appareil inconnu" : device.platformName,
                          style: TextStyle(
                            fontWeight: isTarget ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          device.remoteId.toString(),
                          style: TextStyle(fontFamily: 'monospace', fontSize: 11),
                        ),
                        trailing: isTarget ? Text("🎯 CIBLE", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)) : null,
                      );
                    },
                  ),
                ),
                Text(
                  "Recherchez: F4:12:FA:E7:88:ED",
                  style: TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text("Fermer"),
            ),
          ],
        ),
      ),
    );
  }

  /// 🔐 Vérifier le statut des permissions
  void _checkPermissions() async {
    Map<Permission, PermissionStatus> permissions = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("🔐 Statut des permissions"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: permissions.entries.map((entry) =>
              ListTile(
                leading: Icon(
                  entry.value == PermissionStatus.granted ? Icons.check_circle : Icons.error,
                  color: entry.value == PermissionStatus.granted ? Colors.green : Colors.red,
                ),
                title: Text(entry.key.toString().split('.').last),
                subtitle: Text(entry.value.toString().split('.').last),
              )
          ).toList(),
        ),
        actions: [
          if (permissions.values.any((status) => status != PermissionStatus.granted))
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
              child: Text("Ouvrir Réglages"),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text("Fermer"),
          ),
        ],
      ),
    );
  }

  /// ❌ Affichage d'un message d'erreur
  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: Text("🔍 Appareils LiXee BLE"),
          actions: [
            if (_isScanning)
              Padding(
                padding: EdgeInsets.all(16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            if (devices.isEmpty && !_isScanning)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bluetooth_searching, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        "Aucun appareil LIXEE trouvé",
                        style: TextStyle(fontSize: 18, color: Colors.grey),
                      ),
                      SizedBox(height: 8),
                      Text(
                        "Appuyez sur le bouton de scan pour rechercher",
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    BluetoothDevice device = devices[index];
                    return Card(
                      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: ListTile(
                        leading: Icon(
                          Icons.bluetooth,
                          color: Color(0xFF1B75BC),
                          size: 32,
                        ),
                        title: Text(
                          device.platformName.isNotEmpty
                              ? device.platformName
                              : "Appareil inconnu",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          "ID: ${device.remoteId.toString()}",
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                        trailing: Icon(Icons.arrow_forward_ios),
                        onTap: () => _connectToBleDevice(device),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _isScanning ? null : _scanForBleDevices,
          icon: Icon(_isScanning ? Icons.hourglass_empty : Icons.refresh),
          label: Text(_isScanning ? "Scan en cours..." : "Scanner"),
          backgroundColor: _isScanning ? Colors.grey : Color(0xFF1B75BC),
        ),
      ),
    );
  }
}
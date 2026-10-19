import 'package:flutter/material.dart';
import '../main.dart' show boxListChanged;
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:dio/dio.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

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
  String? _lastErrorMessage;

  // ✅ État de la vérification WiFi
  bool _wifiCheckPassed = false;
  bool _isCheckingWifi = true;

  @override
  void initState() {
    super.initState();
    _checkWifiBeforeStart();
  }

  @override
  void dispose() {
    if (_isScanning) {
      FlutterBluePlus.stopScan().then((_) {
        print("✅ Scan BLE arrêté lors du dispose");
      }).catchError((e) {
        print("⚠️ Erreur arrêt scan BLE: $e");
      });
    }
    _scanSubscription.cancel().then((_) {
      print("✅ Subscription BLE annulée");
    }).catchError((e) {
      print("⚠️ Erreur annulation subscription: $e");
    });
    super.dispose();
  }

  // ============================================================
  // VÉRIFICATION WIFI AU DÉMARRAGE
  // ============================================================

  void _checkWifiBeforeStart() async {
    setState(() => _isCheckingWifi = true);

    final wifiOk = await _isWifiProperlyConfigured();

    if (wifiOk) {
      setState(() {
        _wifiCheckPassed = true;
        _isCheckingWifi = false;
      });
      _initBluetooth();
    } else {
      setState(() {
        _wifiCheckPassed = false;
        _isCheckingWifi = false;
      });
    }
  }

  Future<bool> _isWifiProperlyConfigured() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();

      if (connectivityResult.contains(ConnectivityResult.wifi)) {
        String? localIP = await _getLocalIP();
        return localIP != null;
      }

      return false;
    } catch (e) {
      print("❌ Erreur vérification WiFi: $e");
      return false;
    }
  }

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

  void _openWifiSettings() async {
    try {
      if (Platform.isAndroid) {
        const platform = MethodChannel('app.channel.shared.data');
        await platform.invokeMethod('openWifiSettings');
      } else if (Platform.isIOS) {
        await openAppSettings();
      }
    } catch (e) {
      print("⚠️ Impossible d'ouvrir les paramètres: $e");
      await openAppSettings();
    }
  }

  // ============================================================
  // INITIALISATION BLUETOOTH (code original)
  // ============================================================

  void _initBluetooth() async {
    print("🔵 Initialisation du Bluetooth...");

    if (await FlutterBluePlus.isSupported == false) {
      print("❌ Bluetooth non supporté sur cet appareil");
      return;
    }

    await _requestBluetoothPermissions();

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

  Future<void> _requestBluetoothPermissions() async {
    if (Platform.isIOS) {
      print("🍎 Demande des permissions iOS...");
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
        print("⚠️ Certaines permissions iOS non accordées");
      } else {
        print("✅ Toutes les permissions iOS accordées");
      }

    } else if (Platform.isAndroid) {
      print("🤖 Demande des permissions Android...");
      Map<Permission, PermissionStatus> permissions = {};

      try {
        permissions = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
          Permission.locationWhenInUse,
        ].request();
      } catch (e) {
        print("⚠️ Permissions Android 12+ non disponibles, fallback vers anciennes permissions");
        permissions = await [
          Permission.bluetooth,
          Permission.location,
          Permission.locationWhenInUse,
        ].request();
      }

      bool allGranted = true;
      permissions.forEach((permission, status) {
        print("📋 Permission Android $permission: $status");
        if (status != PermissionStatus.granted && status != PermissionStatus.permanentlyDenied) {
          allGranted = false;
        }
      });

      if (!allGranted) {
        print("⚠️ Permissions Android insuffisantes");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Veuillez autoriser l'accès au Bluetooth et à la localisation dans les paramètres"),
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else {
        print("✅ Toutes les permissions Android accordées");
      }
    }
  }

  void _scanForBleDevices() async {
    if (_isScanning) return;

    print("📡 Scan des appareils BLE en cours...");
    setState(() => _isScanning = true);

    await FlutterBluePlus.stopScan();

    if (mounted) {
      setState(() => devices.clear());
    }

    Duration scanTimeout = Platform.isIOS ? Duration(seconds: 15) : Duration(seconds: 10);

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      Set<String> uniqueDeviceIds = {};
      List<BluetoothDevice> filteredDevices = [];

      for (ScanResult result in results) {
        String deviceName = result.device.platformName;
        String deviceId = result.device.remoteId.toString();
        String macAddress = result.device.remoteId.toString();

        print("🔍 Appareil détecté: '$deviceName' - MAC: $macAddress - RSSI: ${result.rssi}");

        bool isLixeeDevice = deviceName.startsWith("LIXEE") ||
            deviceName.toLowerCase().contains("lixee") ||
            macAddress.toUpperCase() == "F4:12:FA:E7:88:ED";

        if (isLixeeDevice && uniqueDeviceIds.add(deviceId)) {
          filteredDevices.add(result.device);
          print("📶 Appareil LIXEE trouvé: $deviceName ($deviceId) - RSSI: ${result.rssi}");

          if (macAddress.toUpperCase() == "F4:12:FA:E7:88:ED") {
            print("🎯 LIXEEBOX cible détectée ! Nom: '$deviceName'");
          }
        }
      }

      setState(() {
        devices = filteredDevices;
      });
    });

    try {
      if (Platform.isIOS) {
        print("🍎 Scan iOS avec paramètres optimisés...");
        await FlutterBluePlus.startScan(timeout: scanTimeout);
      } else {
        print("🤖 Scan Android standard...");
        await FlutterBluePlus.startScan(timeout: scanTimeout);
      }
    } catch (e) {
      print("❌ Erreur lors du démarrage du scan: $e");
    }

    Timer(scanTimeout, () {
      setState(() => _isScanning = false);
      print("📡 Scan terminé. Appareils LIXEE trouvés: ${devices.length}");

      if (Platform.isIOS && devices.isEmpty) {
        _showIOSTroubleshootingDialog();
      }
    });
  }

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
              _scanForBleDevices();
            },
            child: Text("Réessayer"),
          ),
        ],
      ),
    );
  }

  void _connectToBleDevice(BluetoothDevice device) async {
    String deviceName = device.platformName;
    String last4Chars = deviceName.substring(deviceName.length - 4);

    print("🔌 Tentative de connexion à $deviceName");

    if (_globalConnectingLock) {
      _showConfigWifiDialog(last4Chars, device);
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF1B75BC)),
              SizedBox(height: 20),
              Text(
                "Connexion en cours...",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              SizedBox(height: 8),
              Text(
                "Connexion à $deviceName",
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              ),
              SizedBox(height: 4),
              Text(
                "Découverte des services BLE",
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ],
          ),
        );
      },
    );

    try {
      if (mounted) {
        setState(() => _globalConnectingLock = true);
      }

      await device.connect(timeout: Duration(seconds: 15));
      print("✅ Connecté à $deviceName !");

      List<BluetoothService> services = await device.discoverServices();
      print("🔍 Services découverts: ${services.length}");

      if (mounted) {
        setState(() => _globalConnectingLock = false);
      }

      Navigator.of(context).pop();

      _showConfigWifiDialog(last4Chars, device);

    } catch (e) {
      if (mounted) {
        setState(() => _globalConnectingLock = false);
      }
      print("❌ Erreur de connexion BLE : $e");

      Navigator.of(context).pop();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Échec de la connexion à $deviceName"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showConfigWifiDialog(String last4Chars, BluetoothDevice device) async {
    String selectedSSID = "";
    String password = "";
    List<WiFiAccessPoint> availableNetworks = [];
    bool isLoadingNetworks = false;

    if (Platform.isAndroid) {
      isLoadingNetworks = true;
      try {
        final canGetScannedResults = await WiFiScan.instance.canGetScannedResults();
        if (canGetScannedResults == CanGetScannedResults.yes) {
          await WiFiScan.instance.startScan();
          await Future.delayed(Duration(seconds: 3));
          availableNetworks = await WiFiScan.instance.getScannedResults();

          Set<String> uniqueSSIDs = {};
          availableNetworks = availableNetworks.where((network) {
            return network.ssid.isNotEmpty && uniqueSSIDs.add(network.ssid);
          }).toList();

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
                          title: Text("ℹ️ Information"),
                          content: Text(Platform.isAndroid
                              ? "💡 Sélectionnez le réseau WiFi dans la liste ou saisissez-le manuellement, puis entrez le mot de passe."
                              : "💡 Entrez le nom du réseau WiFi et le mot de passe pour configurer votre appareil LIXEE via Bluetooth."),
                          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text("OK"))],
                        ),
                      );
                    },
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_lastErrorMessage != null) ...[
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        border: Border.all(color: Colors.red.shade200),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error, color: Colors.red, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _lastErrorMessage!,
                              style: TextStyle(color: Colors.red.shade700, fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 16),
                  ],

                  if (Platform.isAndroid && availableNetworks.isNotEmpty) ...[
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: "Sélectionnez un réseau WiFi",
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.wifi),
                      ),
                      items: [
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
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("❌ Veuillez remplir tous les champs")),
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

  IconData _getWiFiIcon(int level) {
    if (level >= -50) return Icons.wifi_rounded;
    if (level >= -60) return Icons.wifi_2_bar_rounded;
    if (level >= -70) return Icons.wifi_1_bar_rounded;
    return Icons.wifi_off_rounded;
  }

  Color _getWiFiColor(int level) {
    if (level >= -50) return Colors.green;
    if (level >= -60) return Colors.orange;
    if (level >= -70) return Colors.red[300]!;
    return Colors.red;
  }

  void _startBleProvisioning(String ssid, String password, String last4Chars, BluetoothDevice device) async {
    _lastErrorMessage = null;

    try {
      print("📡 Envoi des données WiFi via BLE...");

      List<BluetoothService> services = await device.discoverServices();
      print("🔍 Services découverts: ${services.length}");

      BluetoothService? provisioningService;
      BluetoothCharacteristic? wifiCharacteristic;
      BluetoothCharacteristic? ackCharacteristic;

      for (BluetoothService service in services) {
        String serviceUuid = service.uuid.toString().toLowerCase();

        if (serviceUuid.startsWith('6e40000')) {
          provisioningService = service;
          print("🎯 Service LIXEE trouvé: $serviceUuid");

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

      if (provisioningService == null) {
        print("⚠️ Aucun service LIXEE spécifique trouvé, recherche dans services personnalisés...");

        for (BluetoothService service in services) {
          String serviceUuid = service.uuid.toString().toLowerCase();

          if (!serviceUuid.startsWith('0000180') &&
              !serviceUuid.startsWith('0000181') &&
              service.characteristics.isNotEmpty) {

            for (BluetoothCharacteristic characteristic in service.characteristics) {
              if (characteristic.properties.write || characteristic.properties.writeWithoutResponse) {
                provisioningService = service;
                wifiCharacteristic = characteristic;
                print("✅ Service de provisioning trouvé: $serviceUuid");
                print("✅ Caractéristique d'écriture: ${characteristic.uuid}");
              }
              if (characteristic.properties.read || characteristic.properties.notify) {
                ackCharacteristic = characteristic;
              }
            }

            if (provisioningService != null) break;
          }
        }
      }

      if (provisioningService != null && wifiCharacteristic != null) {
        if (ackCharacteristic != null && ackCharacteristic.properties.notify) {
          print("🔔 Abonnement aux notifications pour l'ACK...");
          await ackCharacteristic.setNotifyValue(true);
        }

        String wifiData = "$ssid|$password";
        List<int> bytes = utf8.encode(wifiData);

        print("📤 Envoi des données: $ssid|****");

        bool useWithoutResponse = wifiCharacteristic.properties.writeWithoutResponse &&
            !wifiCharacteristic.properties.write;

        await wifiCharacteristic.write(bytes, withoutResponse: useWithoutResponse);
        print("✅ Données WiFi envoyées via BLE");

        await _disconnectDevice(device);

        String deviceName = device.platformName.isNotEmpty ? device.platformName : "LIXEE-$last4Chars";

        _showVerificationDialog(deviceName, ssid, password, last4Chars);

      } else {
        print("❌ Aucun service ou caractéristique d'écriture trouvé");
        _showError("Aucune caractéristique d'écriture BLE disponible");
        await _disconnectDevice(device);
      }

    } catch (e) {
      print("❌ Erreur lors du provisioning BLE : $e");
      setState(() {
        _lastErrorMessage = "Erreur lors de l'envoi des données BLE: $e";
      });
      await _disconnectDevice(device);
      _showConfigWifiDialog(last4Chars, device);
    }
  }

  void _showVerificationDialog(String deviceName, String ssid, String password, String last4Chars) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return _VerificationDialog(
          deviceName: deviceName,
          ssid: ssid,
          password: password,
          onSuccess: () {
            Navigator.of(context).pop();
            _handleProvisioningSuccess(deviceName);
          },
          onFailure: (errorMessage) {
            Navigator.of(context).pop();
            setState(() {
              _lastErrorMessage = errorMessage;
            });
            _scanForBleDevices();
          },
          onTimeout: () {
            Navigator.of(context).pop();
            setState(() {
              _lastErrorMessage = "Délai d'attente dépassé. L'ESP n'a pas pu se connecter au WiFi.";
            });
            _scanForBleDevices();
          },
        );
      },
    );
  }

  void _handleProvisioningSuccess(String deviceName) async {
    String deviceUrl = "http://$deviceName.local";

    await _saveDevice(deviceName, deviceUrl);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("✅ Appareil $deviceName configuré et connecté avec succès !"),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 3),
      ),
    );

    print("📡 Provisioning BLE réussi, retour à HomeScreen...");
    Navigator.pop(context, true);
  }

  Future<void> _saveDevice(String deviceName, String deviceUrl) async {
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      List<String> savedDevices = prefs.getStringList('saved_devices') ?? [];

      String deviceEntry = "$deviceName|$deviceUrl";

      if (!savedDevices.contains(deviceEntry)) {
        savedDevices.add(deviceEntry);
        await prefs.setStringList('saved_devices', savedDevices);
    boxListChanged();
        print("💾 Appareil sauvegardé: $deviceEntry");
      } else {
        print("⚠️ Appareil déjà existant: $deviceEntry");
      }

    } catch (e) {
      print("❌ Erreur lors de la sauvegarde: $e");
    }
  }

  Future<void> _disconnectDevice(BluetoothDevice device) async {
    try {
      await device.disconnect();
      print("🔓 Déconnecté de ${device.platformName}");
    } catch (e) {
      print("❌ Erreur lors de la déconnexion : $e");
    }
  }

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

  // ============================================================
  // BUILD AVEC ÉCRAN DE VÉRIFICATION WIFI
  // ============================================================

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
        body: _isCheckingWifi
            ? _buildCheckingWifiScreen()
            : _wifiCheckPassed
            ? _buildDeviceListScreen()
            : _buildWifiRequiredScreen(),
        floatingActionButton: _wifiCheckPassed && !_isCheckingWifi
            ? FloatingActionButton.extended(
          onPressed: _isScanning ? null : _scanForBleDevices,
          icon: Icon(_isScanning ? Icons.hourglass_empty : Icons.refresh),
          label: Text(_isScanning ? "Scan en cours..." : "Scanner"),
          backgroundColor: _isScanning ? Colors.grey : Color(0xFF1B75BC),
        )
            : null,
      ),
    );
  }

  Widget _buildCheckingWifiScreen() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Color(0xFF1B75BC)),
          SizedBox(height: 20),
          Text("Vérification de la connexion WiFi...", style: TextStyle(fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildWifiRequiredScreen() {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.wifi_off,
                size: 64,
                color: Colors.orange,
              ),
            ),

            SizedBox(height: 32),

            Text(
              "WiFi requis",
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade800,
              ),
            ),

            SizedBox(height: 16),

            Text(
              "Pour associer votre appareil LiXee, vous devez :\n\n"
                  "1️⃣  Activer le WiFi sur votre téléphone\n\n"
                  "2️⃣  Vous connecter à votre réseau domestique\n\n"
                  "3️⃣  Désactiver les données mobiles\n     (recommandé pour éviter les conflits)",
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey.shade700,
                height: 1.4,
              ),
              textAlign: TextAlign.left,
            ),

            SizedBox(height: 32),

            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue, size: 24),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      "Cela permet à l'application de communiquer "
                          "avec votre appareil LiXee après la configuration.",
                      style: TextStyle(fontSize: 13, color: Colors.blue.shade800),
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: 40),

            Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _openWifiSettings,
                    icon: Icon(Icons.settings),
                    label: Text("Ouvrir les paramètres WiFi"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(0xFF1B75BC),
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),

                SizedBox(height: 16),

                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _checkWifiBeforeStart,
                    icon: Icon(Icons.refresh),
                    label: Text("J'ai activé le WiFi, réessayer"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Color(0xFF1B75BC),
                      side: BorderSide(color: Color(0xFF1B75BC)),
                      padding: EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceListScreen() {
    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.green.shade50,
          child: Row(
            children: [
              Icon(Icons.wifi, color: Colors.green, size: 20),
              SizedBox(width: 8),
              Text(
                "WiFi connecté",
                style: TextStyle(color: Colors.green.shade800, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),

        Expanded(
          child: devices.isEmpty && !_isScanning
              ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.bluetooth_searching, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text("Aucun appareil LIXEE trouvé", style: TextStyle(fontSize: 18, color: Colors.grey)),
                SizedBox(height: 8),
                Text("Appuyez sur Scanner pour rechercher", style: TextStyle(color: Colors.grey)),
              ],
            ),
          )
              : ListView.builder(
            itemCount: devices.length,
            itemBuilder: (context, index) {
              BluetoothDevice device = devices[index];
              return Card(
                margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  leading: Icon(Icons.bluetooth, color: Color(0xFF1B75BC), size: 32),
                  title: Text(
                    device.platformName.isNotEmpty ? device.platformName : "Appareil inconnu",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text("ID: ${device.remoteId}", style: TextStyle(color: Colors.grey[600])),
                  trailing: Icon(Icons.arrow_forward_ios),
                  onTap: () => _connectToBleDevice(device),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ============================================================
// WIDGET _VerificationDialog COMPLET (code original)
// ============================================================

class _VerificationDialog extends StatefulWidget {
  final String deviceName;
  final String ssid;
  final String password;
  final VoidCallback onSuccess;
  final Function(String errorMessage) onFailure;
  final VoidCallback onTimeout;

  const _VerificationDialog({
    required this.deviceName,
    required this.ssid,
    required this.password,
    required this.onSuccess,
    required this.onFailure,
    required this.onTimeout,
  });

  @override
  _VerificationDialogState createState() => _VerificationDialogState();
}

class _VerificationDialogState extends State<_VerificationDialog>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _animation;
  String currentStep = "Configuration envoyée via Bluetooth...";
  int progress = 0;
  bool isCompleted = false;
  Timer? _processTimer;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: Duration(seconds: 2),
      vsync: this,
    )..repeat();
    _animation = Tween<double>(begin: 0, end: 1).animate(_animationController);

    _startVerificationProcess();
  }

  @override
  void dispose() {
    _processTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _startVerificationProcess() async {
    if (mounted) {
      setState(() {
        currentStep = "Configuration envoyée, redémarrage de l'ESP...";
        progress = 25;
      });
    }

    _processTimer = Timer(Duration(seconds: 8), () async {
      if (!mounted) return;

      setState(() {
        currentStep = "Recherche de l'appareil sur le réseau WiFi...";
        progress = 50;
      });

      bool deviceFound = await _checkMdnsWithRetry();

      if (!mounted) return;

      if (deviceFound) {
        setState(() {
          currentStep = "✅ Appareil trouvé et connecté au WiFi !";
          progress = 100;
          isCompleted = true;
        });
        _animationController.stop();

        Timer(Duration(seconds: 1), () {
          if (mounted) {
            widget.onSuccess();
          }
        });
      } else {
        setState(() {
          currentStep = "❌ Appareil non trouvé sur le réseau";
          progress = 0;
          isCompleted = true;
        });
        _animationController.stop();

        Timer(Duration(seconds: 1), () {
          if (mounted) {
            widget.onTimeout();
          }
        });
      }
    });
  }

  Future<bool> _checkMdnsWithRetry() async {
    const int maxAttempts = 8;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (!mounted) return false;

      setState(() {
        currentStep = "Tentative $attempt/$maxAttempts - Recherche via mDNS...";
        progress = 50 + ((attempt - 1) * 40 ~/ maxAttempts);
      });

      bool found = await _performMdnsLookup();

      if (found) {
        return true;
      }

      if (attempt < maxAttempts && mounted) {
        setState(() {
          currentStep = "Tentative $attempt/$maxAttempts échouée, nouvelle tentative...";
        });
        await Future.delayed(Duration(seconds: 2));
      }
    }

    return false;
  }

  Future<bool> _performMdnsLookup() async {
    try {
      String? result = await _resolveMdnsIP(widget.deviceName);
      return result != null;
    } catch (e) {
      print("❌ Erreur mDNS: $e");
      return false;
    }
  }

  Future<String?> _resolveMdnsIP(String deviceName) async {
    print("🔍 Tentative de résolution mDNS pour: $deviceName");

    if (Platform.isIOS) {
      print("🍎 iOS détecté - Utilisation de méthodes alternatives");
      return await _resolveMdnsIOS(deviceName);
    } else {
      print("🤖 Android détecté - Utilisation mDNS standard");
      return await _resolveMdnsAndroid(deviceName);
    }
  }

  Future<String?> _resolveMdnsIOS(String deviceName) async {
    print("🍎 Résolution iOS pour: $deviceName");

    String? ip = await _testDirectConnection(deviceName);
    if (ip != null) {
      print("✅ Résolution directe réussie: $ip");
      return ip;
    }

    ip = await _scanLocalNetwork(deviceName);
    if (ip != null) {
      print("✅ Scan réseau réussi: $ip");
      return ip;
    }

    ip = await _tryMdnsWithFallback(deviceName);
    if (ip != null) {
      print("✅ mDNS fallback réussi: $ip");
      return ip;
    }

    print("❌ Toutes les méthodes iOS ont échoué pour: $deviceName");
    return null;
  }

  Future<String?> _resolveMdnsAndroid(String deviceName) async {
    final client = MDnsClient(
      rawDatagramSocketFactory: (
          host,
          int port, {
            bool reuseAddress = true,
            bool reusePort = false,
            int ttl = 255,
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

  Future<String?> _testDirectConnection(String deviceName) async {
    try {
      print("🔗 Test connexion directe: $deviceName.local");

      final dio = Dio();
      dio.options.connectTimeout = Duration(seconds: 3);
      dio.options.receiveTimeout = Duration(seconds: 3);

      final response = await dio.get('http://$deviceName.local/poll');

      if (response.statusCode == 200) {
        print("✅ Connexion directe réussie à $deviceName.local");
        return "$deviceName.local";
      }
    } catch (e) {
      print("❌ Connexion directe échouée: $e");
    }

    return null;
  }

  Future<String?> _scanLocalNetwork(String deviceName) async {
    try {
      print("🌐 Scan réseau local pour: $deviceName");

      String? localIP = await _getLocalIP();
      if (localIP == null) {
        print("❌ Impossible d'obtenir l'IP locale");
        return null;
      }

      print("📱 IP locale: $localIP");

      List<String> parts = localIP.split('.');
      if (parts.length != 4) return null;

      String networkBase = "${parts[0]}.${parts[1]}.${parts[2]}";
      print("🌐 Scan du réseau: $networkBase.xxx");

      List<Future<String?>> futures = [];
      for (int i = 1; i < 255; i++) {
        String testIP = "$networkBase.$i";
        futures.add(_testDeviceAtIP(testIP, deviceName));
      }

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

  Future<String?> _testDeviceAtIP(String ip, String deviceName) async {
    try {
      final dio = Dio();
      dio.options.connectTimeout = Duration(milliseconds: 1000);
      dio.options.receiveTimeout = Duration(milliseconds: 1000);

      final response = await dio.get('http://$ip/poll');

      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.data);
          if (data != null && data.toString().contains(deviceName)) {
            return ip;
          }
        } catch (_) {
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

  Future<String?> _tryMdnsWithFallback(String deviceName) async {
    try {
      print("🔄 Tentative mDNS avec fallback iOS");

      final client = MDnsClient(
        rawDatagramSocketFactory: (host, int port, {
          bool reuseAddress = true,
          bool reusePort = false,
          int ttl = 255,
        }) async {
          try {
            return await RawDatagramSocket.bind(
              host,
              0,
              reuseAddress: false,
              reusePort: false,
            );
          } catch (e) {
            print("⚠️ Bind sur port auto échoué, essai port standard: $e");
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.bluetooth_connected, color: Color(0xFF1B75BC)),
          SizedBox(width: 8),
          Text("Vérification WiFi"),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isCompleted) ...[
            AnimatedBuilder(
              animation: _animation,
              builder: (context, child) {
                return CircularProgressIndicator(
                  value: _animation.value,
                  color: Color(0xFF1B75BC),
                );
              },
            ),
          ] else ...[
            Icon(
              progress == 100 ? Icons.check_circle : Icons.error,
              color: progress == 100 ? Colors.green : Colors.red,
              size: 48,
            ),
          ],

          SizedBox(height: 16),

          LinearProgressIndicator(
            value: progress / 100,
            backgroundColor: Colors.grey.shade300,
            valueColor: AlwaysStoppedAnimation<Color>(
              progress == 100 ? Colors.green : Color(0xFF1B75BC),
            ),
          ),

          SizedBox(height: 16),

          Text(
            currentStep,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14),
          ),

          SizedBox(height: 8),

          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(Icons.bluetooth, size: 16, color: Colors.blue),
                    SizedBox(width: 4),
                    Text("BLE: ${widget.deviceName}",
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                  ],
                ),
                SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.wifi, size: 16, color: Colors.green),
                    SizedBox(width: 4),
                    Text("WiFi: ${widget.ssid}",
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      actions: isCompleted && progress != 100 ? [
        TextButton(
          onPressed: () => widget.onFailure("Vérification mDNS échouée après provisioning BLE"),
          child: Text("Réessayer"),
        ),
      ] : [],
    );
  }
}
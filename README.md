# 📱 LiXee-Assist

**LiXee-Assist** est une application mobile (Android / iOS) développée en Flutter permettant de détecter, configurer et gérer des appareils **LiXeeGW** via BLE et WiFi. Elle propose un provisioning intelligent, une interface intuitive, un proxy WebView intégré pour accéder aux interfaces embarquées (HTTP/HTTPS avec authentification), et un système de notifications en arrière-plan.

---

## 📸 Aperçu

<img src="doc/img/lixee-assist-dashboard.jpg" width="250px" />
<img src="doc/img/lixee-assist-provisioning-wifi.jpg" width="250px" />
<img src="doc/img/lixee-assist-ajout-appareil.jpg" width="250px" />
<img src="doc/img/lixee-assist-webview.jpg" width="250px" />
---

## ⚙️ Fonctionnalités

- 🔵 **Provisioning BLE** : configuration WiFi des modules LiXee via Bluetooth Low Energy
- 🔍 **Scan automatique des modules LiXee (SSID: LIXEEGW-xxxx)**
- 📶 **Connexion WiFi automatique avec mot de passe pré-rempli**
- 🌐 **Envoi de la configuration WiFi à l'appareil**
- 💾 **Sauvegarde des modules configurés (nom + URL)**
- 🖥 **Proxy WebView intégré** : accès aux interfaces des modules avec support HTTP, HTTPS et authentification Basic
- 🌍 **Résolution mDNS** (pour les noms `*.local`)
- 🔔 **Notifications** : surveillance périodique des appareils en arrière-plan via WorkManager
- 🛠 **Ajout manuel d'un appareil (nom + IP ou URL)**
- 📺 **Support Android TV**
- 🧼 **Interface épurée, flat design, logo officiel LiXee intégré**

---

## 🏗 Technologies

- Flutter (Dart)
- Plugins principaux :
    - [`flutter_blue_plus`](https://pub.dev/packages/flutter_blue_plus) - Communication BLE
    - [`wifi_iot`](https://pub.dev/packages/wifi_iot) - Gestion WiFi
    - [`flutter_inappwebview`](https://pub.dev/packages/flutter_inappwebview) - WebView avancée
    - [`workmanager`](https://pub.dev/packages/workmanager) - Taches en arriere-plan (polling)
    - [`flutter_local_notifications`](https://pub.dev/packages/flutter_local_notifications) - Notifications
    - [`multicast_dns`](https://pub.dev/packages/multicast_dns) - Resolution mDNS
    - [`shared_preferences`](https://pub.dev/packages/shared_preferences) - Stockage local
    - [`dio`](https://pub.dev/packages/dio) - Client HTTP

---

## 🚀 Installation & Deploiement

### 💻 Pre-requis

- Flutter SDK (v3.7.2+)
- Android Studio / Xcode
- Android 5.0+ / iOS 13+

### 🔧 Installation locale

```bash
git clone https://github.com/fairecasoimeme/lixee-assist.git
cd lixee-assist
flutter pub get
flutter run
```

## 📄 Licence
Ce projet est sous licence MIT 


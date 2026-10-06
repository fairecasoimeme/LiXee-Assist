import 'package:flutter/material.dart';

// Variante libre : sans lecteur de QR code intégré, qui dépend d'une
// bibliothèque Google. Ce fichier remplace lib/screens/qr_scan_screen.dart
// (voir tool/foss.sh) et doit en garder l'interface.

/// Le téléphone sait-il lire un QR code depuis l'application ?
const bool qrScanAvailable = false;

/// À la place du viseur : la marche à suivre avec l'appareil photo du
/// téléphone, dont le lien rouvre LiXee-Assist.
class QrScanScreen extends StatelessWidget {
  /// Rend l'adresse d'appairage d'un code lu, ou `null` s'il n'en est pas un.
  final Uri? Function(String raw) accept;

  const QrScanScreen({super.key, required this.accept});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Envoyer vers une TV')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Cette version de LiXee-Assist n\'a pas de lecteur de QR code.\n\n'
            'Scannez le code de la TV ou du panneau avec l\'appareil photo du '
            'téléphone, puis touchez « Ouvrir dans LiXee-Assist » dans la page '
            'qui s\'affiche.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16),
          ),
        ),
      ),
    );
  }
}

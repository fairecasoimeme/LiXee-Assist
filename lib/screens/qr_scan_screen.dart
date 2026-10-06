import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

// Ce fichier est le seul à dépendre du lecteur de QR code. La variante libre
// de l'application (voir tool/foss.sh) le remplace par foss/lib/screens/
// qr_scan_screen.dart, qui n'en a pas.

/// Le téléphone sait-il lire un QR code depuis l'application ?
const bool qrScanAvailable = true;

/// Viseur plein écran. Il ne retient que les QR codes d'appairage LiXee :
/// un autre code passe sans rien déclencher.
class QrScanScreen extends StatefulWidget {
  /// Rend l'adresse d'appairage d'un code lu, ou `null` s'il n'en est pas un.
  final Uri? Function(String raw) accept;

  const QrScanScreen({super.key, required this.accept});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;
  bool _wrongCode = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final base =
          code.rawValue == null ? null : widget.accept(code.rawValue!);
      if (base != null) {
        _done = true;
        Navigator.of(context).pop(base);
        return;
      }
    }
    if (!_wrongCode) setState(() => _wrongCode = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Envoyer vers une TV'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder:
                (context, error) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      error.errorCode == MobileScannerErrorCode.permissionDenied
                          ? 'LiXee-Assist n\'a pas accès à l\'appareil photo. '
                              'Autorisez-le dans les réglages du téléphone.'
                          : 'L\'appareil photo ne répond pas.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                ),
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Text(
              _wrongCode
                  ? 'Ce n\'est pas le QR code d\'une TV LiXee. Sur la TV : '
                      'Ajouter une box, puis choisissez la box.'
                  : 'Visez le QR code affiché par la TV, dans l\'écran « Ajouter une box ».',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}

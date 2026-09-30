import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import 'tv_discovery.dart';
import 'tv_manual_add_screen.dart';
import 'tv_pairing_server.dart';
import 'tv_theme.dart';

/// Ajout de box à la TV, en deux façons :
///
/// - depuis le téléphone : un QR code, et LiXee-Assist envoie toutes ses box
///   d'un coup (ou, sans l'app, le navigateur ouvre un formulaire) ;
/// - à la télécommande : adresse, identifiant et mot de passe saisis sur la
///   TV, pour qui n'a pas le téléphone sous la main.
class TvPairingScreen extends StatefulWidget {
  const TvPairingScreen({super.key});

  @override
  State<TvPairingScreen> createState() => _TvPairingScreenState();
}

class _TvPairingScreenState extends State<TvPairingScreen> {
  List<FoundBox> _found = [];
  bool _scanning = true;
  TvPairingServer? _server;
  Uri? _url;
  String? _message;
  bool _messageIsError = false;
  Timer? _rescan;
  Timer? _expiry;

  /// Le QR code est renouvelé à intervalles : son adresse secrète ne vaut
  /// que pour cette session d'ajout.
  static const _validity = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    _startServer();
    _scan();
    _rescan = Timer.periodic(const Duration(seconds: 15), (_) => _scan());
  }

  @override
  void dispose() {
    _rescan?.cancel();
    _expiry?.cancel();
    _server?.stop();
    super.dispose();
  }

  /// Les box du réseau ne servent qu'à préremplir les formulaires : l'ajout
  /// depuis LiXee-Assist n'en a pas besoin.
  Future<void> _scan() async {
    final found = await TvDiscovery.scan();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      if (found.isNotEmpty) _found = found;
    });
  }

  Future<void> _startServer() async {
    await _server?.stop();
    final server = TvPairingServer(
      suggestions: () => _found,
      onOutcome: _onOutcome,
    );
    final url = await server.start();
    if (!mounted) {
      await server.stop();
      return;
    }
    setState(() {
      _server = server;
      _url = url;
      if (url == null) {
        _message = 'La TV n\'est pas connectée au réseau local.';
        _messageIsError = true;
      }
    });
    _expiry?.cancel();
    _expiry = Timer(_validity, () {
      if (mounted) _startServer();
    });
  }

  void _onOutcome(PairingOutcome outcome) {
    if (!mounted) return;
    setState(() {
      _message = outcome.message;
      _messageIsError = !outcome.ok;
    });
    if (outcome.ok) {
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (mounted) Navigator.of(context).pop(true);
      });
    }
  }

  Future<void> _manual() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => TvManualAddScreen(found: _found)),
    );
    if (added == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TvColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(48, 28, 48, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const TvHeader(trail: ['Ajouter une box']),
              const SizedBox(height: 24),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 10, child: _choices()),
                    const SizedBox(width: 40),
                    Expanded(flex: 11, child: _qrPanel()),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TvHints([
                const ('↑ ↓', 'Choisir'),
                const ('OK', 'Valider'),
                ('', 'QR code renouvelé toutes les ${_validity.inMinutes} min'),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _choices() {
    return ListView(
      clipBehavior: Clip.none,
      padding: const EdgeInsets.all(6),
      children: [
        TvFocusable(
          autofocus: true,
          focusScale: 1.02,
          focusedColor: TvColors.panelHigh,
          child: const _Choice(
            icon: Icons.qr_code_2,
            title: 'Depuis le téléphone',
            subtitle:
                'Scannez le QR code avec LiXee-Assist : '
                'toutes vos box arrivent sur la TV.',
            badge: 'Recommandé',
          ),
        ),
        const SizedBox(height: 14),
        TvFocusable(
          focusScale: 1.02,
          focusedColor: TvColors.panelHigh,
          onSelect: _manual,
          child: const _Choice(
            icon: Icons.settings_remote,
            title: 'Saisie à la télécommande',
            subtitle: 'Adresse, identifiant et mot de passe de la box.',
          ),
        ),
        const SizedBox(height: 22),
        Text(
          _scanning
              ? 'Recherche des box sur ce réseau…'
              : _found.isEmpty
              ? 'Aucune box trouvée sur ce réseau.'
              : 'Sur ce réseau : ${_found.map((b) => b.name).join(', ')}',
          style: const TextStyle(fontSize: 15, color: TvColors.muted),
        ),
        const SizedBox(height: 14),
        // Une box neuve, en mode Bluetooth, n'est pas encore sur le réseau :
        // la TV ne peut pas la voir, et lui donner le WiFi demanderait de
        // taper le mot de passe à la télécommande.
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.bluetooth, color: TvColors.muted, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Box neuve, pas encore sur le WiFi ? Configurez-la d\'abord avec '
                'LiXee-Assist sur le téléphone.',
                style: TextStyle(fontSize: 15, color: TvColors.muted),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _qrPanel() {
    final url = _url;
    final server = _server;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (url == null || server == null)
          const Text(
            'Préparation du QR code…',
            style: TextStyle(fontSize: 18, color: TvColors.muted),
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 200,
                height: 200,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: CustomPaint(painter: _QrPainter(url.toString())),
              ),
              const SizedBox(width: 22),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '1. Sur le téléphone, ouvrez LiXee-Assist, menu ⋮, '
                      'puis Envoyer vers une TV.',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '2. Scannez ce code, puis choisissez les box à envoyer.',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Sans l\'app : l\'appareil photo du téléphone ouvre un '
                      'formulaire.',
                      style: TextStyle(fontSize: 14, color: TvColors.muted),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Code de vérification',
                      style: TextStyle(fontSize: 14, color: TvColors.muted),
                    ),
                    Text(
                      '${server.code.substring(0, 3)} ${server.code.substring(3)}',
                      style: const TextStyle(
                        fontSize: 26,
                        fontFamily: 'monospace',
                        letterSpacing: 3,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        if (_message != null) ...[
          const SizedBox(height: 18),
          Text(
            _message!,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: _messageIsError ? TvColors.bad : TvColors.ok,
            ),
          ),
        ],
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? badge;

  const _Choice({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 36, color: TvColors.focus),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (badge != null) ...[
                    const SizedBox(width: 10),
                    TvPill(badge!, TvColors.ok),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 15, color: TvColors.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _QrPainter extends CustomPainter {
  final String data;
  late final QrImage _image = QrImage(
    QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
  );

  _QrPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    final count = _image.moduleCount;
    final cell = size.width / count;
    final paint = Paint()..color = const Color(0xFF0E141B);
    for (var y = 0; y < count; y++) {
      for (var x = 0; x < count; x++) {
        if (_image.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.data != data;
}

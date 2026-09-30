import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/box_client.dart';

/// Envoie une box enregistrée sur le téléphone vers une TV en cours d'ajout.
///
/// Déclenché par le lien `lixee://pair?u=<adresse>` de la page qu'ouvre le QR
/// code de la TV. L'adresse est celle du serveur d'appairage de la TV, sur
/// le réseau local ; la TV vérifie elle-même les identifiants avant de
/// les garder.
Future<void> showSendToTv(BuildContext context, Uri link) async {
  final target = link.queryParameters['u'];
  final base = target == null ? null : pairingAddress(target);
  if (base == null) return;
  await _send(context, base);
}

/// Adresse d'appairage d'une TV, telle que la porte son QR code :
/// `http://<ip>:<port>/p/<jeton>`. `null` pour tout autre contenu.
Uri? pairingAddress(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'http') return null;
  final s = uri.pathSegments;
  final ok = s.length == 2 && s[0] == 'p' && RegExp(r'^[0-9a-f]{32}$').hasMatch(s[1]);
  return ok ? uri.replace(query: null, fragment: null) : null;
}

/// Ouvre l'appareil photo sur le QR code de la TV, puis propose l'envoi.
Future<void> scanAndSendToTv(BuildContext context) async {
  final base = await Navigator.of(context).push<Uri>(
    MaterialPageRoute(builder: (_) => const _ScanTvScreen()),
  );
  if (base != null && context.mounted) await _send(context, base);
}

Future<void> _send(BuildContext context, Uri base) async {
  final messenger = ScaffoldMessenger.of(context);
  final info = await _getJson(base.replace(path: '${base.path}/info'));
  if (info == null) {
    messenger.showSnackBar(const SnackBar(
      content: Text('La TV ne répond pas. Rouvrez l\'écran d\'ajout sur la TV et rescannez le code.'),
    ));
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final entries = prefs.getStringList('saved_devices') ?? const <String>[];
  final boxes = [
    for (final e in entries)
      if (BoxDevice.tryParse(e) case final d?) (entry: e, device: d),
  ];
  if (!context.mounted) return;
  if (boxes.isEmpty) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Aucune box enregistrée sur ce téléphone : saisissez les identifiants dans la page ouverte par le QR code.'),
    ));
    return;
  }

  final wanted = '${info['box']}'.toLowerCase();
  final initial = boxes.indexWhere((b) => b.device.name.toLowerCase() == wanted);
  final chosen = await showDialog<String>(
    context: context,
    builder: (context) => _SendDialog(
      boxes: [for (final b in boxes) (entry: b.entry, name: b.device.name)],
      initial: initial < 0 ? 0 : initial,
      code: '${info['code']}',
      tvBox: '${info['box']}',
    ),
  );
  if (chosen == null) return;

  messenger.showSnackBar(const SnackBar(content: Text('Envoi vers la TV…')));
  final result = await _postJson(
    base.replace(path: '${base.path}/entry'),
    {'entry': chosen},
  );
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Text(result == null
        ? 'La TV ne répond plus.'
        : '${result['message'] ?? (result['ok'] == true ? 'Box envoyée.' : 'Échec.')}'),
    backgroundColor: result?['ok'] == true ? Colors.green : null,
  ));
}

/// Viseur plein écran. Il ne retient que les QR codes d'appairage LiXee :
/// un autre code passe sans rien déclencher.
class _ScanTvScreen extends StatefulWidget {
  const _ScanTvScreen();

  @override
  State<_ScanTvScreen> createState() => _ScanTvScreenState();
}

class _ScanTvScreenState extends State<_ScanTvScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
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
      final base = code.rawValue == null ? null : pairingAddress(code.rawValue!);
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
            errorBuilder: (context, error) => Center(
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

class _SendDialog extends StatefulWidget {
  final List<({String entry, String name})> boxes;
  final int initial;
  final String code;
  final String tvBox;

  const _SendDialog({
    required this.boxes,
    required this.initial,
    required this.code,
    required this.tvBox,
  });

  @override
  State<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends State<_SendDialog> {
  late int _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    final code = widget.code.length == 6
        ? '${widget.code.substring(0, 3)} ${widget.code.substring(3)}'
        : widget.code;
    return AlertDialog(
      title: const Text('Envoyer vers la TV'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('La TV attend ${widget.tvBox}.'),
            const SizedBox(height: 6),
            Text.rich(TextSpan(children: [
              const TextSpan(text: 'Code affiché sur la TV : '),
              TextSpan(
                text: code,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  letterSpacing: 2,
                ),
              ),
            ])),
            const SizedBox(height: 12),
            for (final (i, box) in widget.boxes.indexed)
              RadioListTile<int>(
                value: i,
                groupValue: _selected,
                onChanged: (v) => setState(() => _selected = v ?? _selected),
                title: Text(box.name),
                contentPadding: EdgeInsets.zero,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, widget.boxes[_selected].entry),
          child: const Text('Envoyer'),
        ),
      ],
    );
  }
}

Future<Map<String, dynamic>?> _getJson(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(url);
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(await utf8.decoder.bind(response).join());
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// La TV vérifie les identifiants auprès de la box avant de répondre : on
/// lui laisse le temps d'un login par le tunnel.
Future<Map<String, dynamic>?> _postJson(Uri url, Map<String, Object?> body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.postUrl(url);
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(const Duration(seconds: 30));
    final decoded = jsonDecode(await utf8.decoder.bind(response).join());
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

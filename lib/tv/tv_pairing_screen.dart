import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../services/box_client.dart';
import 'tv_data.dart';
import 'tv_discovery.dart';
import 'tv_pairing_server.dart';
import 'tv_theme.dart';

/// Ajout d'une box sans clavier : la TV trouve les box du réseau, puis le
/// téléphone envoie les identifiants par un QR code.
class TvPairingScreen extends StatefulWidget {
  const TvPairingScreen({super.key});

  @override
  State<TvPairingScreen> createState() => _TvPairingScreenState();
}

class _TvPairingScreenState extends State<TvPairingScreen> {
  List<FoundBox> _found = [];
  Set<String> _known = {};
  bool _scanning = true;
  FoundBox? _target;
  TvPairingServer? _server;
  Uri? _url;
  String? _message;
  bool _messageIsError = false;
  Timer? _rescan;
  Timer? _expiry;
  Timer? _focusDebounce;

  /// Un QR code resté affiché trop longtemps est renouvelé : son adresse
  /// secrète ne vaut que pour cette session d'ajout.
  static const _validity = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    _loadKnown();
    _scan();
    _rescan = Timer.periodic(const Duration(seconds: 15), (_) => _scan());
  }

  @override
  void dispose() {
    _rescan?.cancel();
    _expiry?.cancel();
    _focusDebounce?.cancel();
    _server?.stop();
    super.dispose();
  }

  Future<void> _loadKnown() async {
    final boxes = await TvData.load();
    if (mounted)
      setState(() => _known = boxes.map((b) => b.name.toLowerCase()).toSet());
  }

  Future<void> _scan() async {
    final found = await TvDiscovery.scan();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      // Ne jamais faire disparaître la box en cours d'ajout sur un balayage
      // qui l'aurait manquée.
      final keep =
          _target != null && !found.any((f) => f.name == _target!.name)
              ? [_target!]
              : <FoundBox>[];
      _found = [...found, ...keep];
    });
  }

  bool _isKnown(FoundBox box) => _known.contains(box.name.toLowerCase());

  /// La box sélectionnée devient la cible du QR code, après un court délai
  /// pour ne pas relancer le serveur à chaque cran de flèche.
  void _focusBox(FoundBox box) {
    _focusDebounce?.cancel();
    _focusDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _startFor(box),
    );
  }

  Future<void> _startFor(FoundBox box) async {
    if (_target?.name == box.name && _url != null) return;
    await _server?.stop();
    final server = TvPairingServer(target: box, onOutcome: _onOutcome);
    final url = await server.start();
    if (!mounted) {
      await server.stop();
      return;
    }
    setState(() {
      _target = box;
      _server = server;
      _url = url;
      _message =
          url == null ? 'La TV n\'est pas connectée au réseau local.' : null;
      _messageIsError = url == null;
    });
    _expiry?.cancel();
    _expiry = Timer(_validity, () {
      _url = null;
      if (mounted) _startFor(box);
    });
  }

  void _onOutcome(PairingOutcome outcome) {
    if (!mounted) return;
    setState(() {
      _message = outcome.message;
      _messageIsError = !outcome.ok;
    });
    if (outcome.ok) {
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (mounted) Navigator.of(context).pop(true);
      });
    }
  }

  /// OK sur une box sans mot de passe l'ajoute tout de suite.
  Future<void> _addDirectly(FoundBox box) async {
    setState(() {
      _message = 'Vérification de ${box.name}…';
      _messageIsError = false;
    });
    final check = await TvPairingServer.verify(
      BoxDevice(name: box.name, primaryUrl: box.url),
    );
    if (!mounted) return;
    if (check == null) {
      await TvData.upsert('${box.name}|${box.url}');
      _onOutcome(
        PairingOutcome.success(null, '${box.name} est ajoutée à la TV.'),
      );
    } else {
      setState(() {
        _message =
            check.startsWith('Cette box demande')
                ? 'Cette box a un mot de passe : scannez le QR code avec le téléphone.'
                : check;
        _messageIsError = !check.startsWith('Cette box demande');
      });
    }
  }

  /// Box d'un autre réseau, ou que la recherche ne voit pas : le seul cas où
  /// il faut taper quelque chose.
  Future<void> _manual() async {
    final controller = TextEditingController(text: '192.168.');
    final address = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Adresse de la box'),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontSize: 20),
              decoration: const InputDecoration(
                hintText: '192.168.1.20 ou lixeebox-8bf0.local',
              ),
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
            actions: [
              TvFocusable(
                color: TvColors.panelHigh,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                onSelect: () => Navigator.pop(context),
                child: const Text('Annuler', style: TextStyle(fontSize: 16)),
              ),
              TvFocusable(
                color: TvColors.focus.withValues(alpha: 0.25),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                onSelect: () => Navigator.pop(context, controller.text),
                child: const Text('Continuer', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
    );
    final host = address
        ?.trim()
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/+$'), '');
    if (host == null || host.isEmpty || !mounted) return;
    final parts = host.split(':');
    final box = FoundBox(
      name:
          parts.first.split('.').first.toUpperCase().startsWith('LIXEE')
              ? parts.first.split('.').first.toUpperCase()
              : parts.first,
      ip: parts.first,
      port: parts.length > 1 ? int.tryParse(parts[1]) ?? 80 : 80,
    );
    setState(() {
      if (!_found.any((f) => f.name == box.name)) _found = [..._found, box];
    });
    _startFor(box);
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
                    Expanded(flex: 11, child: _list()),
                    const SizedBox(width: 40),
                    Expanded(flex: 9, child: _qrPanel()),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TvHints([
                const ('↑ ↓', 'Choisir la box'),
                const ('OK', 'Ajouter une box sans mot de passe'),
                ('', 'QR code valable ${_validity.inMinutes} min'),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list() {
    final items = <Widget>[
      Text(
        _scanning
            ? 'Recherche des box sur ce réseau…'
            : 'Box trouvées sur ce réseau',
        style: const TextStyle(fontSize: 16, color: TvColors.muted),
      ),
      const SizedBox(height: 12),
      if (!_scanning && _found.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Aucune box trouvée. Vérifiez que la TV est sur le même réseau que la box, '
            'ou saisissez son adresse.',
            style: TextStyle(fontSize: 17),
          ),
        ),
      for (final (i, box) in _found.indexed) ...[
        TvFocusable(
          autofocus: i == 0,
          onFocusChange: (focused) {
            if (focused) _focusBox(box);
          },
          onSelect: () => _addDirectly(box),
          focusScale: 1.02,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      box.name,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      box.url.replaceFirst('http://', ''),
                      style: const TextStyle(
                        fontSize: 14,
                        color: TvColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              _isKnown(box)
                  ? const TvPill('Déjà ajoutée', TvColors.ok)
                  : const TvPill('Nouvelle', TvColors.warn),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
      TvFocusable(
        autofocus: !_scanning && _found.isEmpty,
        onSelect: _manual,
        focusScale: 1.02,
        child: const Row(
          children: [
            Icon(Icons.keyboard, color: TvColors.muted),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Saisir une adresse',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'Box introuvable ou sur un autre réseau',
                    style: TextStyle(fontSize: 14, color: TvColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      // Une box neuve, en mode Bluetooth, n'est pas encore sur le réseau :
      // la TV ne peut pas la voir, et lui donner le WiFi demanderait de taper
      // le mot de passe à la télécommande.
      const Padding(
        padding: EdgeInsets.only(top: 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.bluetooth, color: TvColors.muted, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Box neuve, pas encore sur le WiFi ? Configurez-la d\'abord avec '
                'LiXee-Assist sur le téléphone : elle apparaîtra ensuite ici.',
                style: TextStyle(fontSize: 15, color: TvColors.muted),
              ),
            ),
          ],
        ),
      ),
    ];
    return ListView(
      clipBehavior: Clip.none,
      padding: const EdgeInsets.all(6),
      children: items,
    );
  }

  /// QR code à gauche, marche à suivre à droite : empilés, ils débordaient
  /// d'un écran 720p.
  Widget _qrPanel() {
    final url = _url;
    final server = _server;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (url == null || server == null)
          Text(
            _target == null
                ? 'Choisissez une box à gauche.'
                : 'Préparation du QR code…',
            style: const TextStyle(fontSize: 18, color: TvColors.muted),
          )
        else ...[
          Text(
            'Ajouter ${_target!.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
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
                      '1. Scannez ce code avec le téléphone.',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '2. Envoyez la box depuis LiXee-Assist, ou saisissez '
                      'ses identifiants dans la page qui s\'ouvre.',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 16),
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
        ],
        if (_message != null) ...[
          const SizedBox(height: 16),
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

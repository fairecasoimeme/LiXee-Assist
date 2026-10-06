import 'dart:async';

import 'package:flutter/material.dart';

import '../tv/tv_discovery.dart';
import '../tv/tv_pairing_screen.dart' show TvQrPainter;
import '../tv/tv_pairing_server.dart';
import '../tv/tv_theme.dart';
import 'panel_widgets.dart';

/// Ajout de box au panneau : un QR code à scanner avec LiXee-Assist sur le
/// téléphone, qui envoie ses box d'un coup, ou une saisie au clavier
/// tactile.
class PanelAddScreen extends StatefulWidget {
  /// Premier lancement : pas de retour possible tant qu'aucune box n'existe.
  final bool first;

  const PanelAddScreen({super.key, this.first = false});

  @override
  State<PanelAddScreen> createState() => _PanelAddScreenState();
}

class _PanelAddScreenState extends State<PanelAddScreen> {
  List<FoundBox> _found = [];
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

  /// Les box du réseau servent à préremplir la saisie manuelle.
  Future<void> _scan() async {
    final found = await TvDiscovery.scan();
    if (!mounted) return;
    if (found.isNotEmpty) setState(() => _found = found);
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
        _message = 'Le panneau n\'est pas connecté au WiFi.';
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
      Future<void>.delayed(const Duration(seconds: 2), _finish);
    }
  }

  void _finish() {
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _manual() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PanelManualAddScreen(found: _found)),
    );
    if (added == true) _finish();
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    final server = _server;
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Le QR code prend la hauteur disponible, sans dépasser 210.
                Flexible(
                  flex: 10,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 210),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child:
                            url == null
                                ? const SizedBox()
                                : CustomPaint(
                                  painter: TvQrPainter(url.toString()),
                                ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 11,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sur le téléphone, ouvrez LiXee-Assist, puis le menu '
                        '« Envoyer vers une TV », et scannez ce code.',
                        style: TextStyle(fontSize: 14, height: 1.25),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Code de vérification',
                        style: TextStyle(fontSize: 12, color: TvColors.muted),
                      ),
                      Text(
                        server == null
                            ? '— — —'
                            : '${server.code.substring(0, 3)} '
                                '${server.code.substring(3)}',
                        style: const TextStyle(
                          fontSize: 24,
                          fontFamily: 'monospace',
                          letterSpacing: 2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _message!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _messageIsError ? TvColors.bad : TvColors.ok,
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: PanelButton(
                  label: 'Saisie manuelle',
                  icon: Icons.keyboard,
                  color: TvColors.panelHigh,
                  textColor: TvColors.text,
                  onTap: _manual,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (!widget.first) return PanelPage(title: 'Ajouter une box', child: body);
    return Scaffold(
      backgroundColor: TvColors.background,
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TvHeader(trail: ['Ajouter une box']),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// Adresse, identifiant et mot de passe d'une box, au clavier tactile.
class PanelManualAddScreen extends StatefulWidget {
  final List<FoundBox> found;

  const PanelManualAddScreen({super.key, this.found = const []});

  @override
  State<PanelManualAddScreen> createState() => _PanelManualAddScreenState();
}

class _PanelManualAddScreenState extends State<PanelManualAddScreen> {
  final _address = TextEditingController();
  final _login = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void dispose() {
    _address.dispose();
    _login.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _message = 'Vérification auprès de la box…';
      _messageIsError = false;
    });
    final outcome = await TvPairingServer.addWithCredentials(
      address: _address.text.trim(),
      login: _login.text.trim(),
      password: _password.text,
      name: _name.text.trim(),
      known: widget.found,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = outcome.message;
      _messageIsError = !outcome.ok;
    });
    if (outcome.ok) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  InputDecoration _decoration(String label, {String? hint, Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: TvColors.panel,
        suffixIcon: suffix,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return PanelPage(
      title: 'Saisie manuelle',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          if (widget.found.isNotEmpty) ...[
            const Text(
              'Sur ce réseau',
              style: TextStyle(fontSize: 12, color: TvColors.muted),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final box in widget.found)
                  PanelTap(
                    color: TvColors.panelHigh,
                    radius: 10,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    onTap:
                        () => setState(() {
                          _address.text = box.url;
                          if (_name.text.isEmpty) _name.text = box.name;
                        }),
                    child: Text(box.name, style: const TextStyle(fontSize: 14)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          TextField(
            controller: _address,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: _decoration('Adresse', hint: '192.168.1.50'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _login,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: _decoration('Identifiant (si protégé)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _password,
            obscureText: !_showPassword,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: _decoration(
              'Mot de passe',
              suffix: IconButton(
                icon: Icon(
                  _showPassword ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _busy ? null : _add(),
            decoration: _decoration('Nom (facultatif)'),
          ),
          const SizedBox(height: 12),
          PanelButton(
            label: _busy ? 'Vérification…' : 'Ajouter',
            icon: Icons.check,
            onTap: _busy ? null : _add,
          ),
          if (_message != null) ...[
            const SizedBox(height: 10),
            Text(
              _message!,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: _messageIsError ? TvColors.bad : TvColors.ok,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

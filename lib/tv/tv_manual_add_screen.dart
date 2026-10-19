import 'package:flutter/material.dart';

import 'tv_discovery.dart';
import 'tv_pairing_server.dart';
import 'tv_theme.dart';

/// Ajout d'une box à la télécommande : adresse, identifiant, mot de passe.
///
/// Chaque champ est une ligne qu'on sélectionne aux flèches ; OK ouvre le
/// clavier pour ce champ seulement, et Valider le referme. L'adresse se
/// choisit d'abord parmi les box trouvées sur le réseau, pour n'avoir à la
/// taper qu'en dernier recours.
class TvManualAddScreen extends StatefulWidget {
  final List<FoundBox> found;

  const TvManualAddScreen({super.key, required this.found});

  @override
  State<TvManualAddScreen> createState() => _TvManualAddScreenState();
}

class _TvManualAddScreenState extends State<TvManualAddScreen> {
  String _address = '';
  String _login = '';
  String _password = '';
  String _name = '';
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    if (widget.found.length == 1) {
      _address = widget.found.first.url.replaceFirst('http://', '');
      _name = widget.found.first.name;
    }
  }

  Future<void> _chooseAddress() async {
    if (widget.found.isEmpty) {
      final typed = await _type(
        'Adresse de la box',
        _address,
        hint: '192.168.1.20 ou lixeebox-8bf0.local',
        keyboard: TextInputType.url,
      );
      if (typed != null) setState(() => _address = typed.trim());
      return;
    }
    final choice = await showDialog<Object>(
      context: context,
      builder:
          (context) => SimpleDialog(
            title: const Text('Adresse de la box'),
            children: [
              for (final (i, box) in widget.found.indexed)
                _dialogOption(
                  context,
                  autofocus: i == 0,
                  value: box,
                  label: '${box.name} · ${box.ip}',
                ),
              _dialogOption(context, value: 'other', label: 'Autre adresse…'),
            ],
          ),
    );
    if (!mounted || choice == null) return;
    if (choice is FoundBox) {
      setState(() {
        _address = choice.url.replaceFirst('http://', '');
        if (_name.isEmpty || widget.found.any((b) => b.name == _name)) {
          _name = choice.name;
        }
      });
    } else {
      final typed = await _type(
        'Adresse de la box',
        _address,
        hint: '192.168.1.20 ou lixeebox-8bf0.local',
        keyboard: TextInputType.url,
      );
      if (typed != null) setState(() => _address = typed.trim());
    }
  }

  Widget _dialogOption(
    BuildContext context, {
    required Object value,
    required String label,
    bool autofocus = false,
  }) {
    return SimpleDialogOption(
      padding: EdgeInsets.zero,
      child: TvFocusable(
        autofocus: autofocus,
        color: Colors.transparent,
        focusedColor: TvColors.panelHigh,
        focusScale: 1,
        radius: BorderRadius.zero,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        onSelect: () => Navigator.pop(context, value),
        child: Text(label, style: const TextStyle(fontSize: 18)),
      ),
    );
  }

  /// Le clavier de la TV, pour un seul champ.
  Future<String?> _type(
    String title,
    String current, {
    String? hint,
    bool obscure = false,
    TextInputType keyboard = TextInputType.text,
  }) {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 480,
              child: TextField(
                controller: controller,
                autofocus: true,
                obscureText: obscure,
                keyboardType: keyboard,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontSize: 20),
                decoration: InputDecoration(hintText: hint),
                onSubmitted: (value) => Navigator.pop(context, value),
              ),
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
                child: const Text('Valider', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
    );
  }

  Future<void> _add() async {
    setState(() {
      _busy = true;
      _message = 'Vérification auprès de la box…';
      _messageIsError = false;
    });
    final outcome = await TvPairingServer.addWithCredentials(
      address: _address,
      login: _login,
      password: _password,
      name: _name,
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
              const TvHeader(trail: ['Ajouter une box', 'Saisie']),
              const SizedBox(height: 24),
              Expanded(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 640,
                    child: ListView(
                      clipBehavior: Clip.none,
                      padding: const EdgeInsets.all(6),
                      children: [
                        _field(
                          'Adresse',
                          _address,
                          placeholder:
                              widget.found.isEmpty
                                  ? 'À saisir'
                                  : 'Choisir parmi ${widget.found.length} box trouvée${widget.found.length > 1 ? 's' : ''}',
                          onSelect: _chooseAddress,
                          autofocus: true,
                        ),
                        _field(
                          'Identifiant',
                          _login,
                          placeholder: 'Aucun',
                          onSelect: () async {
                            final v = await _type('Identifiant', _login);
                            if (v != null) setState(() => _login = v.trim());
                          },
                        ),
                        _field(
                          'Mot de passe',
                          _password.isEmpty ? '' : '•' * _password.length,
                          placeholder: 'Aucun',
                          onSelect: () async {
                            final v = await _type(
                              'Mot de passe',
                              _password,
                              obscure: true,
                            );
                            if (v != null) setState(() => _password = v);
                          },
                        ),
                        _field(
                          'Nom sur la TV',
                          _name,
                          placeholder: 'Facultatif',
                          onSelect: () async {
                            final v = await _type(
                              'Nom sur la TV',
                              _name,
                              hint: 'Maison',
                            );
                            if (v != null) setState(() => _name = v.trim());
                          },
                        ),
                        const SizedBox(height: 10),
                        TvFocusable(
                          onSelect: _busy || _address.isEmpty ? null : _add,
                          color: TvColors.focus.withValues(
                            alpha: _address.isEmpty ? 0.08 : 0.22,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                          child: Row(
                            children: [
                              _busy
                                  ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                    ),
                                  )
                                  : const Icon(Icons.add, size: 26),
                              const SizedBox(width: 14),
                              const Text(
                                'Ajouter la box',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_message != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _message!,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color:
                                  _messageIsError ? TvColors.bad : TvColors.ok,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const TvHints([
                ('↑ ↓', 'Choisir un champ'),
                ('OK', 'Modifier'),
                ('Retour', 'Revenir'),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    String label,
    String value, {
    required String placeholder,
    required VoidCallback onSelect,
    bool autofocus = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TvFocusable(
        autofocus: autofocus,
        focusScale: 1.02,
        onSelect: onSelect,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 170,
              child: Text(
                label,
                style: const TextStyle(fontSize: 17, color: TvColors.muted),
              ),
            ),
            Expanded(
              child: Text(
                value.isEmpty ? placeholder : value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: value.isEmpty ? FontWeight.w400 : FontWeight.w700,
                  color: value.isEmpty ? TvColors.muted : TvColors.text,
                ),
              ),
            ),
            const Icon(Icons.edit, size: 20, color: TvColors.muted),
          ],
        ),
      ),
    );
  }
}

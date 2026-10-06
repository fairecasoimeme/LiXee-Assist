import 'dart:async';

import 'package:flutter/material.dart';

import '../services/widget_data_service.dart';
import 'tv_box_screen.dart';
import 'tv_data.dart';
import 'tv_pairing_screen.dart';
import 'tv_theme.dart';

/// Accueil TV : une tuile par box, et une tuile pour en ajouter une.
///
/// Tout se fait aux flèches et à OK ; la touche Menu ouvre les actions sur
/// la box sélectionnée, à la place de l'appui long du téléphone.
class TvHomeScreen extends StatefulWidget {
  const TvHomeScreen({super.key});

  @override
  State<TvHomeScreen> createState() => _TvHomeScreenState();
}

class _TvHomeScreenState extends State<TvHomeScreen> {
  List<TvBox> _boxes = [];
  bool _loaded = false;
  Timer? _timer;

  /// Tant que l'accueil est affiché, les puissances restent à jour. Au-delà,
  /// c'est le relevé d'arrière-plan qui prend le relais.
  static const _refreshEvery = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _reload();
    _timer = Timer.periodic(_refreshEvery, (_) => _refreshAll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final boxes = await TvData.load();
    if (!mounted) return;
    setState(() {
      _boxes = boxes;
      _loaded = true;
    });
    _refreshAll();
  }

  /// Relève toutes les box en parallèle ; chaque tuile se met à jour dès
  /// que sa box a répondu, sans attendre les box injoignables.
  void _refreshAll() {
    for (final box in List<TvBox>.from(_boxes)) {
      TvData.refresh(box).then((fresh) {
        if (!mounted) return;
        setState(() {
          final i = _boxes.indexWhere((b) => b.entry == box.entry);
          if (i >= 0) _boxes[i] = fresh;
        });
      });
    }
  }

  Future<void> _open(TvBox box) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => TvBoxScreen(box: box)));
    if (mounted) _reload();
  }

  Future<void> _add() async {
    final added = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const TvPairingScreen()));
    if (added == true && mounted) _reload();
  }

  Future<void> _menu(TvBox box) async {
    final choice = await showDialog<String>(
      context: context,
      builder:
          (context) => SimpleDialog(
            title: Text(box.name, style: const TextStyle(fontSize: 22)),
            children: [
              _menuOption(
                context,
                'rename',
                Icons.edit,
                'Renommer',
                autofocus: true,
              ),
              _menuOption(
                context,
                'remove',
                Icons.delete_outline,
                'Retirer cette box',
              ),
              _menuOption(context, null, Icons.close, 'Annuler'),
            ],
          ),
    );
    if (!mounted) return;
    if (choice == 'remove') {
      final sure = await _confirm(
        'Retirer ${box.name} ?',
        'La box restera configurée : vous pourrez la rajouter à tout moment.',
        'Retirer',
      );
      if (sure == true) {
        await TvData.remove(box);
        _reload();
      }
    } else if (choice == 'rename') {
      final name = await _askName(box.name);
      if (name != null && name.trim().isNotEmpty && name.trim() != box.name) {
        await TvData.rename(box, name);
        _reload();
      }
    }
  }

  Widget _menuOption(
    BuildContext context,
    String? value,
    IconData icon,
    String label, {
    bool autofocus = false,
  }) {
    return SimpleDialogOption(
      padding: EdgeInsets.zero,
      child: TvFocusable(
        autofocus: autofocus,
        color: Colors.transparent,
        focusedColor: TvColors.panelHigh,
        focusScale: 1,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        radius: BorderRadius.zero,
        onSelect: () => Navigator.pop(context, value),
        child: Row(
          children: [
            Icon(icon, color: TvColors.muted),
            const SizedBox(width: 16),
            Text(label, style: const TextStyle(fontSize: 18)),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirm(String title, String message, String action) {
    return showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(title),
            content: Text(message, style: const TextStyle(fontSize: 16)),
            actions: [
              TvFocusable(
                autofocus: true,
                color: TvColors.panelHigh,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                onSelect: () => Navigator.pop(context, false),
                child: const Text('Annuler', style: TextStyle(fontSize: 16)),
              ),
              TvFocusable(
                color: TvColors.bad.withValues(alpha: 0.25),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                onSelect: () => Navigator.pop(context, true),
                child: Text(action, style: const TextStyle(fontSize: 16)),
              ),
            ],
          ),
    );
  }

  /// Le seul endroit où le clavier apparaît encore : renommer est rare.
  Future<String?> _askName(String current) {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Renommer la box'),
            content: TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(fontSize: 20),
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
                child: const Text(
                  'Enregistrer',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ],
          ),
    );
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
              TvHeader(
                trailing: Text(
                  '${_boxes.length} box',
                  style: const TextStyle(fontSize: 16, color: TvColors.muted),
                ),
              ),
              const SizedBox(height: 28),
              Expanded(child: _loaded ? _grid() : const SizedBox()),
              const SizedBox(height: 16),
              const TvHints([
                ('OK', 'Ouvrir la box'),
                ('OK maintenu', 'Renommer ou retirer'),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _grid() {
    return GridView.builder(
      clipBehavior: Clip.none,
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 24,
        crossAxisSpacing: 24,
        mainAxisExtent: 196,
      ),
      itemCount: _boxes.length + 1,
      itemBuilder: (context, i) {
        if (i == _boxes.length) {
          return TvFocusable(
            autofocus: _boxes.isEmpty,
            onSelect: _add,
            color: Colors.transparent,
            focusedColor: TvColors.panel,
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, size: 44, color: TvColors.focus),
                SizedBox(height: 6),
                Text(
                  'Ajouter une box',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                Text(
                  'Sans clavier',
                  style: TextStyle(fontSize: 14, color: TvColors.muted),
                ),
              ],
            ),
          );
        }
        final box = _boxes[i];
        return TvFocusable(
          autofocus: i == 0,
          onSelect: () => _open(box),
          onMenu: () => _menu(box),
          child: _BoxTile(box: box),
        );
      },
    );
  }
}

class _BoxTile extends StatelessWidget {
  final TvBox box;

  const _BoxTile({required this.box});

  @override
  Widget build(BuildContext context) {
    final snapshot = box.snapshot;
    final (label, color) = switch (box.reach) {
      TvReach.local => ('Local', TvColors.ok),
      TvReach.remote => ('Tunnel', TvColors.ok),
      TvReach.offline => ('Hors ligne', TvColors.bad),
      TvReach.unknown => ('Connexion…', TvColors.muted),
    };
    final online = box.reach == TvReach.local || box.reach == TvReach.remote;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvPill(label, color),
        const SizedBox(height: 8),
        Text(
          box.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        if (snapshot?.apparentPowerVA != null && online)
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: tvNumber(snapshot!.apparentPowerVA!),
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(
                  text: ' VA',
                  style: TextStyle(fontSize: 15, color: TvColors.muted),
                ),
              ],
            ),
          ),
        Text(
          _subtitle(snapshot, online),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, color: TvColors.muted),
        ),
      ],
    );
  }

  String _subtitle(LinkySnapshot? snapshot, bool online) {
    if (!online) {
      if (box.reach == TvReach.unknown) return '';
      return snapshot == null
          ? 'Aucun relevé'
          : 'Dernier relevé ${tvAge(snapshot.timestamp)}';
    }
    if (snapshot == null) return 'En ligne';
    final production = snapshot.productionPowerVA;
    if (production != null && production > 0) {
      return 'Production +${tvNumber(production)} VA';
    }
    final daily = snapshot.dailyTotalWh;
    if (daily != null) {
      return '${tvNumber(daily / 1000, decimals: 1)} kWh sur 24 h';
    }
    return 'En ligne';
  }
}

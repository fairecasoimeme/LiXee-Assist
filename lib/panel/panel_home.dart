import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/home_screen.dart' show resolveMdnsIP;
import '../services/action_group_service.dart';
import '../services/device_control_service.dart';
import '../services/thermostat_service.dart';
import '../tv/tv_data.dart';
import '../tv/tv_theme.dart';
import 'panel_add.dart';
import 'panel_backlight.dart';
import 'panel_views.dart';
import 'panel_widgets.dart';

enum _Tab { energy, devices, groups, thermostats }

/// Kiosque d'un panneau mural : une box à la fois, quatre vues au pied de
/// l'écran, tout au doigt.
///
/// Une vue n'apparaît que si la box a de quoi la remplir. La box affichée
/// est retenue d'un lancement à l'autre.
class PanelHomeScreen extends StatefulWidget {
  const PanelHomeScreen({super.key});

  @override
  State<PanelHomeScreen> createState() => _PanelHomeScreenState();
}

class _PanelHomeScreenState extends State<PanelHomeScreen> {
  List<TvBox> _boxes = [];
  TvBox? _box;
  bool _loaded = false;
  bool _adding = false;

  List<DeviceSnapshot>? _devices;
  List<ActionGroup>? _groups;
  List<ThermostatZone>? _zones;
  _Tab _current = _Tab.energy;
  Timer? _timer;

  static const _refreshEvery = Duration(seconds: 30);
  static const _boxPref = 'panel_box';

  @override
  void initState() {
    super.initState();
    _reload();
    _timer = Timer.periodic(_refreshEvery, (_) => _refreshCurrent());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final boxes = await TvData.load();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final wanted = prefs.getString(_boxPref);
    final box =
        boxes.where((b) => b.name == wanted).firstOrNull ?? boxes.firstOrNull;
    final changed = box?.entry != _box?.entry;
    setState(() {
      _boxes = boxes;
      _box = box;
      _loaded = true;
      if (changed) {
        _devices = null;
        _groups = null;
        _zones = null;
        _current = _Tab.energy;
      }
    });
    if (box == null) {
      _addFirst();
    } else {
      _loadAll();
    }
  }

  /// Sans box, le kiosque n'a rien à montrer : l'ajout s'ouvre d'office.
  Future<void> _addFirst() async {
    if (_adding) return;
    _adding = true;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const PanelAddScreen(first: true)),
    );
    _adding = false;
    if (mounted) _reload();
  }

  Future<void> _select(TvBox box) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_boxPref, box.name);
    if (mounted) _reload();
  }

  void _loadAll() {
    _refreshEnergy();
    _refreshDevices();
    _refreshGroups();
    _refreshZones();
  }

  /// Seule la vue affichée est relevée périodiquement.
  void _refreshCurrent() {
    if (_box == null) return;
    switch (_current) {
      case _Tab.energy:
        _refreshEnergy();
      case _Tab.devices:
        _refreshDevices();
      case _Tab.groups:
        _refreshGroups();
      case _Tab.thermostats:
        _refreshZones();
    }
  }

  /// Une réponse qui arrive après un changement de box est ignorée.
  bool _still(TvBox box) => mounted && _box?.entry == box.entry;

  Future<void> _refreshEnergy() async {
    final box = _box;
    if (box == null) return;
    final fresh = await TvData.refresh(box);
    if (_still(box)) setState(() => _box = fresh);
  }

  Future<void> _refreshDevices() async {
    final box = _box;
    if (box == null) return;
    final devices = await DeviceControlService.fetchAll(
      box.device,
      mdnsResolver: resolveMdnsIP,
    );
    // Une box muette rend une liste vide : on garde alors l'affichage connu.
    if (_still(box) && (devices.isNotEmpty || _devices == null)) {
      setState(() => _devices = devices);
    }
  }

  Future<void> _refreshGroups() async {
    final box = _box;
    if (box == null) return;
    final groups = await ActionGroupService.fetchAll(
      box.device,
      mdnsResolver: resolveMdnsIP,
    );
    if (_still(box) && (groups.isNotEmpty || _groups == null)) {
      setState(() => _groups = groups);
    }
  }

  Future<void> _refreshZones() async {
    final box = _box;
    if (box == null) return;
    final zones = await ThermostatService.fetchAll(
      box.device,
      mdnsResolver: resolveMdnsIP,
    );
    if (_still(box) && (zones.isNotEmpty || _zones == null)) {
      setState(() => _zones = zones);
    }
  }

  List<_Tab> get _tabs => [
    if (_box?.snapshot?.apparentPowerVA != null) _Tab.energy,
    if (_devices?.any((d) => !_isMeterDevice(d)) ?? false) _Tab.devices,
    if (_groups?.isNotEmpty ?? false) _Tab.groups,
    if (_zones?.isNotEmpty ?? false) _Tab.thermostats,
  ];

  bool _isMeterDevice(DeviceSnapshot d) =>
      d.model.toLowerCase().startsWith('zlinky') ||
      d.label.toLowerCase().startsWith('zlinky');

  (IconData, String) _look(_Tab tab) => switch (tab) {
    _Tab.energy => (Icons.bolt, 'Énergie'),
    _Tab.devices => (Icons.blinds, 'Appareils'),
    _Tab.groups => (Icons.play_circle_outline, 'Groupes'),
    _Tab.thermostats => (Icons.thermostat, 'Thermostats'),
  };

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PanelSettingsScreen(current: _box)),
    );
    if (mounted) _reload();
  }

  Future<void> _chooseBox() async {
    if (_boxes.length < 2) return;
    final chosen = await showModalBottomSheet<TvBox>(
      context: context,
      backgroundColor: TvColors.panel,
      builder:
          (context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(12),
              children: [
                for (final box in _boxes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: PanelTap(
                      color:
                          box.entry == _box?.entry
                              ? TvColors.focus.withValues(alpha: 0.25)
                              : TvColors.panelHigh,
                      onTap: () => Navigator.pop(context, box),
                      child: Text(
                        box.name,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
    );
    if (chosen != null) _select(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final box = _box;
    if (!_loaded || box == null) {
      return const Scaffold(backgroundColor: TvColors.background);
    }
    final tabs = _tabs;
    final current =
        tabs.contains(_current) ? _current : (tabs.firstOrNull ?? _Tab.energy);
    final loading = _devices == null || _groups == null || _zones == null;

    return Scaffold(
      backgroundColor: TvColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _header(box, loading),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
                child: tabs.isEmpty ? _empty(box, loading) : _content(current),
              ),
            ),
            if (tabs.length > 1) _nav(tabs, current),
          ],
        ),
      ),
    );
  }

  Widget _header(TvBox box, bool loading) {
    final dot = switch (box.reach) {
      TvReach.local || TvReach.remote => TvColors.ok,
      TvReach.offline => TvColors.bad,
      TvReach.unknown => TvColors.muted,
    };
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: 14),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _chooseBox,
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        box.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (_boxes.length > 1)
                      const Icon(
                        Icons.arrow_drop_down,
                        color: TvColors.muted,
                        size: 26,
                      ),
                    if (box.reach == TvReach.offline) ...[
                      const SizedBox(width: 8),
                      const Text(
                        'Hors ligne',
                        style: TextStyle(fontSize: 13, color: TvColors.bad),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const PanelClock(),
          PanelIconButton(icon: Icons.settings, onTap: _openSettings),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _empty(TvBox box, bool loading) {
    return Center(
      child:
          loading
              ? const CircularProgressIndicator(color: TvColors.muted)
              : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    box.reach == TvReach.offline
                        ? Icons.cloud_off
                        : Icons.inbox_outlined,
                    size: 44,
                    color: TvColors.muted,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    box.reach == TvReach.offline
                        ? 'La box ne répond pas.'
                        : 'Rien à afficher pour cette box.',
                    style: const TextStyle(fontSize: 16, color: TvColors.muted),
                  ),
                  const SizedBox(height: 14),
                  PanelButton(
                    label: 'Réessayer',
                    icon: Icons.refresh,
                    color: TvColors.panelHigh,
                    textColor: TvColors.text,
                    onTap: _loadAll,
                  ),
                ],
              ),
    );
  }

  Widget _content(_Tab tab) {
    final box = _box!;
    switch (tab) {
      case _Tab.energy:
        return PanelEnergyView(snapshot: box.snapshot!);
      case _Tab.devices:
        return PanelDevicesView(
          box: box.device,
          devices: _devices!,
          onChanged: (devices) => setState(() => _devices = devices),
        );
      case _Tab.groups:
        return PanelGroupsView(box: box.device, groups: _groups!);
      case _Tab.thermostats:
        return PanelThermostatsView(
          box: box.device,
          zones: _zones!,
          onChanged: (zones) => setState(() => _zones = zones),
        );
    }
  }

  Widget _nav(List<_Tab> tabs, _Tab current) {
    return Container(
      height: 60,
      color: TvColors.panel,
      child: Row(
        children: [
          for (final tab in tabs)
            Expanded(
              child: InkWell(
                onTap: () {
                  setState(() => _current = tab);
                  _refreshCurrent();
                },
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _look(tab).$1,
                      size: 26,
                      color: tab == current ? TvColors.focus : TvColors.muted,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _look(tab).$2,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            tab == current ? FontWeight.w700 : FontWeight.w400,
                        color: tab == current ? TvColors.text : TvColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Réglages du kiosque : les box enregistrées, et l'ajout d'une nouvelle.
class PanelSettingsScreen extends StatefulWidget {
  final TvBox? current;

  const PanelSettingsScreen({super.key, this.current});

  @override
  State<PanelSettingsScreen> createState() => _PanelSettingsScreenState();
}

class _PanelSettingsScreenState extends State<PanelSettingsScreen> {
  List<TvBox> _boxes = [];
  String _version = '';
  int _sleepMinutes = PanelBacklight.defaultDelay;
  bool _autostart = true;
  int _returnMinutes = PanelBacklight.defaultReturnDelay;

  @override
  void initState() {
    super.initState();
    _reload();
    PanelBacklight.sleepMinutes().then((minutes) {
      if (mounted) setState(() => _sleepMinutes = minutes);
    });
    PanelBacklight.autostart().then((enabled) {
      if (mounted) setState(() => _autostart = enabled);
    });
    PanelBacklight.returnMinutes().then((minutes) {
      if (mounted) setState(() => _returnMinutes = minutes);
    });
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
  }

  Future<void> _reload() async {
    final boxes = await TvData.load();
    if (mounted) setState(() => _boxes = boxes);
  }

  Future<void> _add() async {
    await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const PanelAddScreen()));
    if (mounted) _reload();
  }

  /// Chaque appui passe au délai de veille suivant.
  Future<void> _nextSleepDelay() async {
    const delays = PanelBacklight.delays;
    final next = delays[(delays.indexOf(_sleepMinutes) + 1) % delays.length];
    await PanelBacklight.setSleepMinutes(next);
    if (mounted) setState(() => _sleepMinutes = next);
  }

  Future<void> _toggleAutostart() async {
    final next = !_autostart;
    await PanelBacklight.setAutostart(next);
    if (mounted) setState(() => _autostart = next);
  }

  Future<void> _nextReturnDelay() async {
    const delays = PanelBacklight.returnDelays;
    final next = delays[(delays.indexOf(_returnMinutes) + 1) % delays.length];
    await PanelBacklight.setReturnMinutes(next);
    if (mounted) setState(() => _returnMinutes = next);
  }

  Widget _setting(
    IconData icon,
    String label,
    String value,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: PanelTap(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(icon, color: TvColors.muted),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
            Text(
              value,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: TvColors.focus,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(TvBox box) async {
    final controller = TextEditingController(text: box.name);
    final name = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Renommer la box'),
            content: TextField(
              controller: controller,
              autofocus: true,
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Annuler'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('Enregistrer'),
              ),
            ],
          ),
    );
    if (name == null || name.trim().isEmpty || name.trim() == box.name) return;
    await TvData.rename(box, name);
    // La box affichée est retenue par son nom.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('panel_box') == box.name) {
      await prefs.setString('panel_box', name.trim());
    }
    _reload();
  }

  Future<void> _remove(TvBox box) async {
    final sure = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('Retirer ${box.name} ?'),
            content: const Text(
              'La box restera configurée : vous pourrez la rajouter à tout '
              'moment.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Annuler'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  'Retirer',
                  style: TextStyle(color: TvColors.bad),
                ),
              ),
            ],
          ),
    );
    if (sure != true) return;
    await TvData.remove(box);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return PanelPage(
      title: 'Réglages',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        children: [
          for (final box in _boxes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.only(left: 14),
                decoration: BoxDecoration(
                  color: TvColors.panel,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        box.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    PanelIconButton(
                      icon: Icons.edit,
                      onTap: () => _rename(box),
                    ),
                    PanelIconButton(
                      icon: Icons.delete_outline,
                      onTap: () => _remove(box),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 6),
          PanelButton(
            label: 'Ajouter une box',
            icon: Icons.add,
            color: TvColors.panelHigh,
            textColor: TvColors.text,
            onTap: _add,
          ),
          if (PanelBacklight.supported) ...[
            _setting(
              Icons.bedtime_outlined,
              "Veille de l'écran",
              _sleepMinutes == 0 ? 'Jamais' : '$_sleepMinutes min',
              _nextSleepDelay,
            ),
            _setting(
              Icons.power_settings_new,
              'Lancer au démarrage',
              _autostart ? 'Oui' : 'Non',
              _toggleAutostart,
            ),
            _setting(
              Icons.keyboard_return,
              'Retour automatique',
              _returnMinutes == 0 ? 'Jamais' : '$_returnMinutes min',
              _nextReturnDelay,
            ),
          ],
          const SizedBox(height: 6),
          // Rend la main à l'écran du panneau. Le kiosque y reviendra de
          // lui-même si le retour automatique est réglé.
          PanelButton(
            label: 'Quitter le kiosque',
            icon: Icons.logout,
            color: TvColors.panelHigh,
            textColor: TvColors.text,
            onTap: PanelBacklight.goHome,
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              _version.isEmpty ? 'LiXee-Assist' : 'LiXee-Assist $_version',
              style: const TextStyle(fontSize: 13, color: TvColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/home_screen.dart' show resolveMdnsIP;
import '../services/action_group_service.dart';
import '../services/device_control_service.dart';
import '../services/thermostat_service.dart';
import 'tv_data.dart';
import 'tv_tabs.dart';
import 'tv_theme.dart';

enum _Tab { energy, devices, groups, thermostats, web }

/// Une box : onglets Énergie, Appareils, Groupes, Thermostats, Interface web.
///
/// Un onglet n'apparaît que si la box a de quoi le remplir. Sélectionner un
/// onglet l'affiche aussitôt : pas besoin de valider pour changer de vue.
class TvBoxScreen extends StatefulWidget {
  final TvBox box;

  const TvBoxScreen({super.key, required this.box});

  @override
  State<TvBoxScreen> createState() => _TvBoxScreenState();
}

class _TvBoxScreenState extends State<TvBoxScreen> {
  late TvBox _box = widget.box;
  List<DeviceSnapshot>? _devices;
  List<ActionGroup>? _groups;
  List<ThermostatZone>? _zones;
  _Tab _current = _Tab.energy;
  Timer? _timer;
  final _firstTab = FocusNode(debugLabel: 'premier onglet');

  static const _refreshEvery = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _loadAll();
    _timer = Timer.periodic(_refreshEvery, (_) => _refreshCurrent());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _firstTab.dispose();
    super.dispose();
  }

  void _loadAll() {
    _refreshEnergy();
    _refreshDevices();
    _refreshGroups();
    _refreshZones();
  }

  /// Seul l'onglet affiché est relevé périodiquement : les autres le seront
  /// quand on y reviendra.
  void _refreshCurrent() {
    switch (_current) {
      case _Tab.energy:
        _refreshEnergy();
      case _Tab.devices:
        _refreshDevices();
      case _Tab.groups:
        _refreshGroups();
      case _Tab.thermostats:
        _refreshZones();
      case _Tab.web:
        break;
    }
  }

  Future<void> _refreshEnergy() async {
    final fresh = await TvData.refresh(_box);
    if (mounted) setState(() => _box = fresh);
  }

  Future<void> _refreshDevices() async {
    final devices = await DeviceControlService.fetchAll(
      _box.device,
      mdnsResolver: resolveMdnsIP,
    );
    // Une box muette rend une liste vide : on garde alors l'affichage connu.
    if (mounted && (devices.isNotEmpty || _devices == null)) {
      setState(() => _devices = devices);
    }
  }

  Future<void> _refreshGroups() async {
    final groups = await ActionGroupService.fetchAll(
      _box.device,
      mdnsResolver: resolveMdnsIP,
    );
    if (mounted && (groups.isNotEmpty || _groups == null)) {
      setState(() => _groups = groups);
    }
  }

  Future<void> _refreshZones() async {
    final zones = await ThermostatService.fetchAll(
      _box.device,
      mdnsResolver: resolveMdnsIP,
    );
    if (mounted && (zones.isNotEmpty || _zones == null)) {
      setState(() => _zones = zones);
    }
  }

  List<_Tab> get _tabs => [
    if (_box.snapshot?.apparentPowerVA != null) _Tab.energy,
    if (_devices?.isNotEmpty ?? false) _Tab.devices,
    if (_groups?.isNotEmpty ?? false) _Tab.groups,
    if (_zones?.isNotEmpty ?? false) _Tab.thermostats,
    _Tab.web,
  ];

  String _label(_Tab tab) => switch (tab) {
    _Tab.energy => 'Énergie',
    _Tab.devices => 'Appareils',
    _Tab.groups => 'Groupes',
    _Tab.thermostats => 'Thermostats',
    _Tab.web => 'Interface web',
  };

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    // Les onglets apparaissent au fil des réponses de la box : celui qui a le
    // focus en première position peut changer sous le curseur. L'onglet
    // affiché suit alors le focus ; il se replie aussi sur le premier si le
    // sien a disparu.
    final current =
        !tabs.contains(_current) || _firstTab.hasFocus ? tabs.first : _current;
    final loading = _devices == null || _groups == null || _zones == null;

    return Scaffold(
      backgroundColor: TvColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(48, 28, 48, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TvHeader(trail: [_box.name], trailing: _reachPill()),
              const SizedBox(height: 20),
              FocusTraversalGroup(
                child: Row(
                  children: [
                    for (final (i, tab) in tabs.indexed) ...[
                      if (i > 0) const SizedBox(width: 10),
                      TvFocusable(
                        focusNode: i == 0 ? _firstTab : null,
                        autofocus: i == 0,
                        focusScale: 1,
                        radius: BorderRadius.circular(99),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        color: tab == current ? TvColors.text : TvColors.panel,
                        onFocusChange: (focused) {
                          if (focused && _current != tab) {
                            setState(() => _current = tab);
                          }
                        },
                        child: Text(
                          _label(tab),
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight:
                                tab == current
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                            color:
                                tab == current
                                    ? TvColors.background
                                    : TvColors.muted,
                          ),
                        ),
                      ),
                    ],
                    if (loading) ...[
                      const SizedBox(width: 16),
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: TvColors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Expanded(child: FocusTraversalGroup(child: _content(current))),
            ],
          ),
        ),
      ),
    );
  }

  Widget? _reachPill() => switch (_box.reach) {
    TvReach.local => const TvPill('Local', TvColors.ok),
    TvReach.remote => const TvPill('Tunnel', TvColors.ok),
    TvReach.offline => const TvPill('Hors ligne', TvColors.bad),
    TvReach.unknown => null,
  };

  Widget _content(_Tab tab) {
    switch (tab) {
      case _Tab.energy:
        return TvEnergyTab(snapshot: _box.snapshot!);
      case _Tab.devices:
        return TvDevicesTab(
          box: _box.device,
          devices: _devices!,
          onChanged: (devices) => setState(() => _devices = devices),
        );
      case _Tab.groups:
        return TvGroupsTab(box: _box.device, groups: _groups!);
      case _Tab.thermostats:
        return TvThermostatsTab(
          box: _box.device,
          zones: _zones!,
          onChanged: (zones) => setState(() => _zones = zones),
        );
      case _Tab.web:
        return TvWebTab(box: _box);
    }
  }
}

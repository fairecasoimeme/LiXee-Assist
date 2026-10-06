import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/home_screen.dart' show resolveMdnsIP;
import '../services/action_group_service.dart';
import '../services/box_client.dart';
import '../services/device_control_service.dart';
import '../services/thermostat_service.dart';
import '../services/widget_data_service.dart';
import '../tv/tv_tabs.dart';
import '../tv/tv_theme.dart';
import 'panel_widgets.dart';

Widget _card({required Widget child, EdgeInsetsGeometry? padding}) => Container(
  padding: padding ?? const EdgeInsets.all(12),
  decoration: BoxDecoration(
    color: TvColors.panel,
    borderRadius: BorderRadius.circular(14),
  ),
  child: child,
);

// ---------------------------------------------------------------------------
// Énergie
// ---------------------------------------------------------------------------

/// La puissance en grand, le bilan sur 24 h, et le graphe heure par heure :
/// ce qu'on lit d'un coup d'œil en passant devant le panneau.
///
/// Sur un écran carré, la jauge et le bilan se partagent le haut. Sur un
/// écran vertical, la jauge prend toute la largeur et le bilan passe en
/// bandeau dessous : côte à côte, ils laisseraient deux colonnes à moitié
/// vides.
class PanelEnergyView extends StatelessWidget {
  final LinkySnapshot snapshot;

  const PanelEnergyView({super.key, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tall = constraints.maxHeight > constraints.maxWidth * 1.25;
        return tall ? _tall() : _square();
      },
    );
  }

  Widget _square() {
    return Column(
      children: [
        Expanded(
          flex: 11,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 10, child: _gauge()),
              const SizedBox(width: 8),
              Expanded(
                flex: 9,
                child: _card(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sur 24 h',
                        style: TextStyle(fontSize: 13, color: TvColors.muted),
                      ),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: _energy(32),
                      ),
                      if (snapshot.dailyCostEur != null) _cost(24),
                      if (_solar() case final solar?) solar,
                      const SizedBox(height: 4),
                      _age(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(flex: 8, child: _chart()),
      ],
    );
  }

  Widget _tall() {
    return Column(
      children: [
        Expanded(flex: 10, child: _gauge()),
        const SizedBox(height: 8),
        _card(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Sur 24 h',
                      style: TextStyle(fontSize: 13, color: TvColors.muted),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          _energy(30),
                          if (snapshot.dailyCostEur != null) ...[
                            const SizedBox(width: 18),
                            _cost(24),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_solar() case final solar?) solar,
                  _age(),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(flex: 8, child: _chart()),
      ],
    );
  }

  Widget _gauge() {
    final s = snapshot;
    return _card(
      padding: const EdgeInsets.all(8),
      child: TvArcGauge(
        ratio:
            s.subscribedPowerVA == null || s.subscribedPowerVA == 0
                ? 0
                : (s.apparentPowerVA ?? 0) / s.subscribedPowerVA!,
        color: TvColors.focus,
        value: tvNumber(s.apparentPowerVA ?? 0),
        caption:
            s.subscribedPowerVA == null
                ? 'VA'
                : 'VA sur ${tvNumber(s.subscribedPowerVA!)}',
        scaleText: true,
      ),
    );
  }

  Widget _energy(double size) => _figure(
    snapshot.dailyTotalWh == null
        ? '—'
        : tvNumber(snapshot.dailyTotalWh! / 1000, decimals: 2),
    'kWh',
    size,
  );

  Widget _cost(double size) =>
      _figure(tvNumber(snapshot.dailyCostEur!, decimals: 2), '€', size);

  /// L'injection en cours si la maison produit, sinon la production du jour.
  Widget? _solar() {
    final production = snapshot.productionPowerVA;
    final String text;
    if (production != null && production > 0) {
      text = 'Injection +${tvNumber(production)} VA';
    } else if (snapshot.dailyProductionWh != null) {
      text =
          'Produit ${tvNumber(snapshot.dailyProductionWh! / 1000, decimals: 2)} kWh';
    } else {
      return null;
    }
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13, color: TvColors.solar),
    );
  }

  Widget _age() => Text(
    'Relevé ${tvAge(snapshot.timestamp)}',
    style: const TextStyle(fontSize: 12, color: TvColors.muted),
  );

  Widget _chart() {
    return _card(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Heure par heure',
            style: TextStyle(fontSize: 13, color: TvColors.muted),
          ),
          const SizedBox(height: 4),
          Expanded(
            child:
                snapshot.hourly.isEmpty
                    ? const Center(
                      child: Text(
                        'Historique indisponible',
                        style: TextStyle(color: TvColors.muted),
                      ),
                    )
                    : TvHourlyChart(samples: snapshot.hourly),
          ),
        ],
      ),
    );
  }

  Widget _figure(String value, String unit, double size) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: value,
          style: TextStyle(fontSize: size, fontWeight: FontWeight.w700),
        ),
        TextSpan(
          text: ' $unit',
          style: TextStyle(fontSize: size * 0.5, color: TvColors.muted),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Appareils
// ---------------------------------------------------------------------------

class PanelDevicesView extends StatefulWidget {
  final BoxDevice box;
  final List<DeviceSnapshot> devices;
  final ValueChanged<List<DeviceSnapshot>> onChanged;

  const PanelDevicesView({
    super.key,
    required this.box,
    required this.devices,
    required this.onChanged,
  });

  @override
  State<PanelDevicesView> createState() => _PanelDevicesViewState();
}

class _PanelDevicesViewState extends State<PanelDevicesView> {
  final Map<String, String> _status = {};

  List<DeviceSnapshot> get _shown =>
      widget.devices.where((d) => !tvIsMeter(d)).toList();

  Future<void> _send(DeviceSnapshot device, DeviceAction action) async {
    setState(() => _status[device.key] = '${tvActionLabel(action.name)}…');
    final ok = await DeviceControlService.send(
      widget.box,
      device,
      action,
      mdnsResolver: resolveMdnsIP,
    );
    if (!mounted) return;
    setState(() => _status[device.key] = ok ? 'Envoyé' : 'Échec de l\'envoi');
    if (!ok) return;

    // Relectures espacées pendant le mouvement : la box ne sert d'elle-même
    // que la dernière valeur rapportée, parfois en retard.
    for (final delay in const [4, 8, 18]) {
      await Future<void>.delayed(Duration(seconds: delay));
      if (!mounted) return;
      final current = widget.devices.firstWhere(
        (d) => d.key == device.key,
        orElse: () => device,
      );
      for (final reading in current.readings) {
        await DeviceControlService.forceRead(
          widget.box,
          current,
          reading,
          mdnsResolver: resolveMdnsIP,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final devices = await DeviceControlService.fetchAll(
        widget.box,
        mdnsResolver: resolveMdnsIP,
      );
      if (!mounted) return;
      if (devices.isNotEmpty) widget.onChanged(devices);
    }
    if (mounted) setState(() => _status.remove(device.key));
  }

  Future<void> _openActions(DeviceSnapshot device) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: TvColors.panel,
      isScrollControlled: true,
      builder:
          (_) => _ActionsSheet(
            deviceKey: device.key,
            devices: () => widget.devices,
            status: () => _status[device.key],
            onAction: (action) => _send(device, action),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = _shown;
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        mainAxisExtent: 112,
      ),
      itemCount: devices.length,
      itemBuilder: (context, i) {
        final device = devices[i];
        return PanelTap(
          onTap: device.actions.isEmpty ? null : () => _openActions(device),
          child: _DeviceTile(device: device, status: _status[device.key]),
        );
      },
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final DeviceSnapshot device;
  final String? status;

  const _DeviceTile({required this.device, this.status});

  @override
  Widget build(BuildContext context) {
    final readings = tvShownReadings(device);
    final primary = readings.isEmpty ? null : readings.first;
    final isPosition = primary?.name == 'current_position';
    // En second, seulement une grandeur qui parle : les gabarits exposent
    // aussi des réglages du module (« Window covering type »).
    final secondary =
        readings.skip(1).where((r) => _plain.contains(r.name)).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          device.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            primary == null
                ? 'Pas de mesure'
                : tvSelfExplanatory.contains(primary.name)
                ? tvReadingValue(primary)
                : '${tvReadingLabel(primary.name)} ${tvReadingValue(primary)}',
            style: TextStyle(
              fontSize: primary == null ? 14 : 21,
              fontWeight: FontWeight.w700,
              color: primary == null ? TvColors.muted : TvColors.text,
            ),
          ),
        ),
        if (isPosition) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: (primary!.value! / 100).clamp(0, 1).toDouble(),
              minHeight: 5,
              backgroundColor: TvColors.panelHigh,
              color: TvColors.focus,
            ),
          ),
        ],
        const Spacer(),
        Text(
          status ??
              (secondary == null
                  ? ''
                  : '${tvReadingLabel(secondary.name)} ${tvReadingValue(secondary)}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: status == null ? TvColors.muted : TvColors.focus,
          ),
        ),
      ],
    );
  }
}

/// Lectures qu'on affiche en petit sous la grandeur principale.
const _plain = {
  'temperature',
  'Temperature',
  'local_temperature',
  'humidity',
  'Humidity',
  'battery',
  'Bat',
};

IconData _actionIcon(String name) => switch (name.toUpperCase()) {
  'UP' || 'OPEN' => Icons.keyboard_arrow_up,
  'DOWN' || 'CLOSE' => Icons.keyboard_arrow_down,
  'STOP' => Icons.stop,
  'ON' => Icons.power_settings_new,
  'OFF' => Icons.power_off_outlined,
  'TOGGLE' => Icons.swap_horiz,
  _ => Icons.play_arrow,
};

/// Commandes d'un appareil, en gros boutons. Le panneau se redessine chaque
/// seconde pour suivre la relecture : un volet qui monte voit sa position
/// bouger.
class _ActionsSheet extends StatefulWidget {
  final String deviceKey;
  final List<DeviceSnapshot> Function() devices;
  final String? Function() status;
  final ValueChanged<DeviceAction> onAction;

  const _ActionsSheet({
    required this.deviceKey,
    required this.devices,
    required this.status,
    required this.onAction,
  });

  @override
  State<_ActionsSheet> createState() => _ActionsSheetState();
}

class _ActionsSheetState extends State<_ActionsSheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = widget.devices();
    final device = devices.firstWhere(
      (d) => d.key == widget.deviceKey,
      orElse: () => devices.first,
    );
    final readings = tvShownReadings(device);
    final primary = readings.isEmpty ? null : readings.first;
    final status = widget.status();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    device.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (primary != null)
                  Text(
                    tvReadingValue(primary),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: TvColors.focus,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final action in device.actions)
                  SizedBox(
                    width: 142,
                    height: 62,
                    child: PanelTap(
                      color: TvColors.panelHigh,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      onTap: () => widget.onAction(action),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(_actionIcon(action.name), size: 26),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              tvActionLabel(action.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              status ?? 'Touchez une commande',
              style: TextStyle(
                fontSize: 14,
                color: status == null ? TvColors.muted : TvColors.focus,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Groupes d'actions
// ---------------------------------------------------------------------------

class PanelGroupsView extends StatefulWidget {
  final BoxDevice box;
  final List<ActionGroup> groups;

  const PanelGroupsView({super.key, required this.box, required this.groups});

  @override
  State<PanelGroupsView> createState() => _PanelGroupsViewState();
}

class _PanelGroupsViewState extends State<PanelGroupsView> {
  final Map<String, String> _status = {};

  Future<void> _run(ActionGroup group) async {
    setState(() => _status[group.key] = 'Lancement…');
    final result = await ActionGroupService.run(
      widget.box,
      group.name,
      mdnsResolver: resolveMdnsIP,
    );
    if (!mounted) return;
    setState(
      () =>
          _status[group.key] =
              result.ok
                  ? 'Lancé · ${result.sent} action${result.sent > 1 ? 's' : ''}'
                  : 'Échec',
    );
    await Future<void>.delayed(const Duration(seconds: 6));
    if (mounted) setState(() => _status.remove(group.key));
  }

  static Color? _parseColor(String hex) {
    final clean = hex.replaceFirst('#', '');
    if (clean.length != 6) return null;
    final value = int.tryParse(clean, radix: 16);
    return value == null ? null : Color(0xFF000000 | value);
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        mainAxisExtent: 118,
      ),
      itemCount: widget.groups.length,
      itemBuilder: (context, i) {
        final group = widget.groups[i];
        final tint = _parseColor(group.color) ?? TvColors.focus;
        final status = _status[group.key];
        return Opacity(
          opacity: group.enabled ? 1 : 0.5,
          child: PanelTap(
            padding: const EdgeInsets.all(8),
            onTap: group.enabled ? () => _run(group) : null,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox.square(
                  dimension: 38,
                  child:
                      group.iconPath != null
                          ? CustomPaint(
                            painter: TvIconPainter(group.iconPath!, tint),
                          )
                          : Center(
                            child: Text(
                              group.icon.isEmpty ? '▶' : group.icon,
                              style: TextStyle(fontSize: 26, color: tint),
                            ),
                          ),
                ),
                const SizedBox(height: 6),
                Text(
                  group.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (status != null || !group.enabled)
                  Text(
                    status ?? 'Désactivé',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: status == null ? TvColors.muted : TvColors.focus,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Thermostats
// ---------------------------------------------------------------------------

/// Une zone par page, qu'on fait glisser du doigt : la consigne se règle
/// avec deux gros boutons.
class PanelThermostatsView extends StatefulWidget {
  final BoxDevice box;
  final List<ThermostatZone> zones;
  final ValueChanged<List<ThermostatZone>> onChanged;

  const PanelThermostatsView({
    super.key,
    required this.box,
    required this.zones,
    required this.onChanged,
  });

  @override
  State<PanelThermostatsView> createState() => _PanelThermostatsViewState();
}

class _PanelThermostatsViewState extends State<PanelThermostatsView> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zones = widget.zones;
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _controller,
            itemCount: zones.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder:
                (context, i) => _ZonePage(
                  // La clé garde l'écart de consigne en attente sur sa zone.
                  key: ValueKey(zones[i].key),
                  box: widget.box,
                  zone: zones[i],
                  onChanged: widget.onChanged,
                ),
          ),
        ),
        if (zones.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < zones.length; i++)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page ? TvColors.text : TvColors.panelHigh,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ZonePage extends StatefulWidget {
  final BoxDevice box;
  final ThermostatZone zone;
  final ValueChanged<List<ThermostatZone>> onChanged;

  const _ZonePage({
    super.key,
    required this.box,
    required this.zone,
    required this.onChanged,
  });

  @override
  State<_ZonePage> createState() => _ZonePageState();
}

class _ZonePageState extends State<_ZonePage> {
  /// Écart de consigne pas encore envoyé : les appuis s'additionnent, et la
  /// valeur part une seconde après le dernier.
  double _pending = 0;
  Timer? _debounce;
  bool _busy = false;

  static const _gaugeMin = 5.0;
  static const _gaugeMax = 35.0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  double get _shownSetpoint =>
      ThermostatService.nextSetpoint(widget.zone.setpoint, _pending);

  void _step(double step) {
    setState(() => _pending += step);
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), _sendSetpoint);
  }

  Future<void> _sendSetpoint() async {
    final delta = _shownSetpoint - widget.zone.setpoint;
    if (delta == 0) {
      setState(() => _pending = 0);
      return;
    }
    await _command(
      () => ThermostatService.command(
        widget.box,
        widget.zone.name,
        delta: delta,
        mdnsResolver: resolveMdnsIP,
      ),
    );
  }

  Future<void> _command(Future<bool> Function() send) async {
    setState(() => _busy = true);
    final ok = await send();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _pending = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('La box n\'a pas pris la commande')),
      );
      return;
    }
    // La box régule en continu : relire tout de suite donnerait l'état
    // d'avant.
    await Future<void>.delayed(const Duration(seconds: 2));
    final zones = await ThermostatService.fetchAll(
      widget.box,
      mdnsResolver: resolveMdnsIP,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pending = 0;
    });
    if (zones.isNotEmpty) widget.onChanged(zones);
  }

  @override
  Widget build(BuildContext context) {
    final z = widget.zone;
    final heatColor = z.heating ? TvColors.heat : TvColors.cool;
    final color = z.active ? heatColor : heatColor.withValues(alpha: 0.45);
    double position(double t) => (t - _gaugeMin) / (_gaugeMax - _gaugeMin);

    final (stateLabel, stateColor) =
        z.forceMode == 2
            ? ('Arrêt', TvColors.muted)
            : z.active
            ? (z.heating ? 'Chauffe' : 'Refroidit', heatColor)
            : ('En attente', TvColors.muted);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  z.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: TvColors.muted,
                    ),
                  ),
                ),
              TvPill(stateLabel, stateColor),
            ],
          ),
          Expanded(
            child: Row(
              children: [
                _stepButton(Icons.remove, () => _step(-0.5)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: TvArcGauge(
                      ratio: position(_shownSetpoint),
                      color: color,
                      value: '${tvNumber(_shownSetpoint, decimals: 1)}°',
                      caption:
                          z.hasReading
                              ? 'mesuré ${tvNumber(z.temperature!, decimals: 1)} °C'
                              : 'pas de mesure',
                      marker: z.hasReading ? position(z.temperature!) : null,
                    ),
                  ),
                ),
                _stepButton(Icons.add, () => _step(0.5)),
              ],
            ),
          ),
          Row(
            children: [
              for (final (mode, label) in const [
                (0, 'Auto'),
                (1, 'Marche'),
                (2, 'Arrêt'),
              ]) ...[
                Expanded(
                  child: _modeChip(
                    label,
                    selected: z.forceMode == mode,
                    onTap:
                        () => _command(
                          () => ThermostatService.command(
                            widget.box,
                            z.name,
                            forceMode: mode,
                            mdnsResolver: resolveMdnsIP,
                          ),
                        ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: _modeChip(
                  'Hors-gel',
                  selected: z.frost,
                  onTap:
                      () => _command(
                        () => ThermostatService.command(
                          widget.box,
                          z.name,
                          toggleFrost: true,
                          mdnsResolver: resolveMdnsIP,
                        ),
                      ),
                ),
              ),
              if (z.reversible) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: _modeChip(
                    z.heating ? 'Froid' : 'Chaud',
                    selected: false,
                    onTap:
                        () => _command(
                          () => ThermostatService.command(
                            widget.box,
                            z.name,
                            heat: !z.heating,
                            mdnsResolver: resolveMdnsIP,
                          ),
                        ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _stepButton(IconData icon, VoidCallback onTap) => SizedBox.square(
    dimension: 68,
    child: PanelTap(
      color: TvColors.panelHigh,
      radius: 34,
      padding: EdgeInsets.zero,
      onTap: _busy ? null : onTap,
      child: Icon(icon, size: 34),
    ),
  );

  Widget _modeChip(
    String label, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 44,
      child: PanelTap(
        color: selected ? TvColors.text : TvColors.panelHigh,
        radius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        onTap: _busy ? null : onTap,
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: selected ? TvColors.background : TvColors.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

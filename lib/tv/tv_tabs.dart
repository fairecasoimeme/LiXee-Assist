import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_drawing/path_drawing.dart';

import '../screens/home_screen.dart' show resolveMdnsIP;
import '../screens/webview_device_screen.dart';
import '../services/action_group_service.dart';
import '../services/box_client.dart';
import '../services/device_control_service.dart';
import '../services/thermostat_service.dart';
import '../services/widget_data_service.dart';
import 'tv_data.dart';
import 'tv_theme.dart';

// ---------------------------------------------------------------------------
// Énergie
// ---------------------------------------------------------------------------

class TvEnergyTab extends StatelessWidget {
  final LinkySnapshot snapshot;

  const TvEnergyTab({super.key, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final production = s.productionPowerVA;
    final trend = s.hourlyTrendPct;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 4,
          child: _Panel(
            title: 'Puissance',
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
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
                  ),
                ),
                if (production != null && production > 0)
                  Text(
                    'Injection +${tvNumber(production)} VA',
                    style: const TextStyle(fontSize: 18, color: TvColors.solar),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          flex: 4,
          child: _Panel(
            title: 'Sur 24 h',
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _figure(
                  s.dailyTotalWh == null
                      ? '—'
                      : tvNumber(s.dailyTotalWh! / 1000, decimals: 2),
                  'kWh',
                  40,
                ),
                if (s.dailyCostEur != null)
                  _figure(tvNumber(s.dailyCostEur!, decimals: 2), '€', 30),
                if (s.dailyProductionWh != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Produit ${tvNumber(s.dailyProductionWh! / 1000, decimals: 2)} kWh',
                    style: const TextStyle(fontSize: 18, color: TvColors.solar),
                  ),
                ],
                if (trend != null) ...[
                  const SizedBox(height: 10),
                  _trend(trend),
                ],
                const SizedBox(height: 10),
                Text(
                  'Relevé ${tvAge(s.timestamp)}',
                  style: const TextStyle(fontSize: 14, color: TvColors.muted),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          flex: 9,
          child: _Panel(
            title: 'Heure par heure',
            child:
                s.hourly.isEmpty
                    ? const Center(
                      child: Text(
                        'Historique indisponible',
                        style: TextStyle(color: TvColors.muted),
                      ),
                    )
                    : TvHourlyChart(samples: s.hourly),
          ),
        ),
      ],
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
          style: TextStyle(fontSize: size * 0.45, color: TvColors.muted),
        ),
      ],
    ),
  );

  /// Sous 2 %, l'écart est du bruit de mesure : on dit « stable ».
  Widget _trend(double pct) {
    final String text;
    final Color color;
    if (pct > 2) {
      text = '↑ ${pct.round()} % vs heure précédente';
      color = TvColors.bad;
    } else if (pct < -2) {
      text = '↓ ${(-pct).round()} % vs heure précédente';
      color = TvColors.ok;
    } else {
      text = '→ stable';
      color = TvColors.muted;
    }
    return Text(text, style: TextStyle(fontSize: 17, color: color));
  }
}

class _Panel extends StatelessWidget {
  final String title;
  final Widget child;

  const _Panel({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: TvColors.panel,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, color: TvColors.muted),
          ),
          const SizedBox(height: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Jauge en arc de 270°, ouverte en bas, comme sur les widgets.
class TvArcGauge extends StatelessWidget {
  final double ratio;
  final Color color;
  final String value;
  final String caption;

  /// Position d'un repère sur l'arc (0 à 1), par exemple la température
  /// mesurée face à la consigne.
  final double? marker;

  const TvArcGauge({
    super.key,
    required this.ratio,
    required this.color,
    required this.value,
    required this.caption,
    this.marker,
  });

  @override
  Widget build(BuildContext context) {
    // Carré centré dans la place disponible : un AspectRatio sous des
    // contraintes serrées (dans un Expanded) cède, et l'arc devient ovale.
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 260.0,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 260.0,
        );
        return Center(child: SizedBox.square(dimension: side, child: _gauge()));
      },
    );
  }

  Widget _gauge() {
    return CustomPaint(
      painter: _ArcPainter(ratio.clamp(0, 1).toDouble(), color, marker),
      // Marge intérieure : le texte ne doit pas chevaucher l'arc.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                child: Text(
                  value,
                  style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                caption,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: TvColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  final double ratio;
  final Color color;
  final double? marker;

  _ArcPainter(this.ratio, this.color, this.marker);

  static const _start = math.pi * 0.75;
  static const _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.08;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final track =
        Paint()
          ..color = TvColors.panelHigh
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _start, _sweep, false, track);
    if (ratio > 0) {
      canvas.drawArc(rect, _start, _sweep * ratio, false, track..color = color);
    }
    if (marker != null) {
      final angle = _start + _sweep * marker!.clamp(0, 1);
      final center = rect.center;
      final radius = rect.width / 2;
      canvas.drawCircle(
        Offset(
          center.dx + radius * math.cos(angle),
          center.dy + radius * math.sin(angle),
        ),
        stroke * 0.42,
        Paint()..color = TvColors.text,
      );
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.ratio != ratio || old.color != color || old.marker != marker;
}

/// Graphe des 24 dernières heures. L'heure en cours, partielle, est la
/// dernière barre, plus appuyée ; l'injection est en vert.
class TvHourlyChart extends StatelessWidget {
  final List<HourlySample> samples;

  const TvHourlyChart({super.key, required this.samples});

  @override
  Widget build(BuildContext context) {
    final marks = [
      0,
      samples.length ~/ 3,
      2 * samples.length ~/ 3,
      samples.length - 1,
    ];
    return Column(
      children: [
        Expanded(
          child: CustomPaint(
            size: Size.infinite,
            painter: _BarsPainter(samples),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final (i, index) in marks.indexed)
              Text(
                '${samples[index].hour}h',
                style: TextStyle(
                  fontSize: 14,
                  color:
                      i == marks.length - 1 ? TvColors.focus : TvColors.muted,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<HourlySample> samples;

  _BarsPainter(this.samples);

  @override
  void paint(Canvas canvas, Size size) {
    final peak = samples.fold<int>(
      1,
      (m, s) => math.max(m, math.max(s.wh, s.productionWh)),
    );
    final slot = size.width / samples.length;
    final width = slot * 0.62;
    final hasProduction = samples.any((s) => s.productionWh > 0);
    for (final (i, s) in samples.indexed) {
      final current = i == samples.length - 1;
      final x = i * slot + (slot - width) / 2;
      final drawnWidth = hasProduction ? width / 2 : width;
      final h = size.height * s.wh / peak;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, size.height - h, drawnWidth, h),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        Paint()..color = TvColors.focus.withValues(alpha: current ? 1 : 0.55),
      );
      if (hasProduction && s.productionWh > 0) {
        final p = size.height * s.productionWh / peak;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x + drawnWidth, size.height - p, drawnWidth, p),
            topLeft: const Radius.circular(3),
            topRight: const Radius.circular(3),
          ),
          Paint()..color = TvColors.solar.withValues(alpha: current ? 1 : 0.7),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.samples != samples;
}

// ---------------------------------------------------------------------------
// Appareils
// ---------------------------------------------------------------------------

/// Noms d'action des gabarits, traduits pour l'écran.
String tvActionLabel(String name) => switch (name.toUpperCase()) {
  'UP' || 'OPEN' => 'Monter',
  'DOWN' || 'CLOSE' => 'Descendre',
  'STOP' => 'Stop',
  'ON' => 'Allumer',
  'OFF' => 'Éteindre',
  'TOGGLE' => 'Basculer',
  _ => name,
};

String tvReadingLabel(String name) => switch (name) {
  'current_position' => 'Position',
  'temperature' || 'Temperature' || 'local_temperature' => 'Température',
  'humidity' || 'Humidity' => 'Humidité',
  'battery' || 'Bat' => 'Batterie',
  _ => name
      .replaceAll('_', ' ')
      .replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase()),
};

/// Valeur mise en forme, avec « ouvert » et « fermé » aux deux bouts d'un
/// volet, à un point près : les modules s'arrêtent souvent à 99 ou 1 %.
String tvReadingValue(DeviceReading r) {
  final v = r.value;
  if (v == null) return '—';
  final text = v == v.roundToDouble() ? tvNumber(v) : tvNumber(v, decimals: 1);
  final unit = r.unit ?? (r.name == 'current_position' ? '%' : '');
  final spaced = unit.isEmpty ? text : '$text $unit';
  if (r.name == 'current_position') {
    if (v >= 99) return '$spaced · ouvert';
    if (v <= 1) return '$spaced · fermé';
  }
  return spaced;
}

/// Lectures qui valent la peine d'être montrées : une valeur, et pas un
/// réglage du module (« Window covering type », « Config status »).
List<DeviceReading> tvShownReadings(DeviceSnapshot d) =>
    d.readings.where((r) => r.value != null).toList();

/// Grandeurs qu'on comprend sans leur nom, à leur unité.
const tvSelfExplanatory = {
  'current_position',
  'temperature',
  'Temperature',
  'local_temperature',
};

/// Le compteur Linky a son propre onglet : le répéter ici n'apporte que des
/// libellés bruts.
bool tvIsMeter(DeviceSnapshot d) =>
    d.model.toLowerCase().startsWith('zlinky') ||
    d.label.toLowerCase().startsWith('zlinky');

class TvDevicesTab extends StatefulWidget {
  final BoxDevice box;
  final List<DeviceSnapshot> devices;
  final ValueChanged<List<DeviceSnapshot>> onChanged;

  const TvDevicesTab({
    super.key,
    required this.box,
    required this.devices,
    required this.onChanged,
  });

  @override
  State<TvDevicesTab> createState() => _TvDevicesTabState();
}

class _TvDevicesTabState extends State<TvDevicesTab> {
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

  /// Les commandes s'ouvrent dans un panneau : dans la tuile, elles la
  /// faisaient déborder, et Retour y quittait l'écran au lieu de les fermer.
  Future<void> _openActions(DeviceSnapshot device) {
    return showDialog<void>(
      context: context,
      builder:
          (dialogContext) => _ActionsDialog(
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
      clipBehavior: Clip.none,
      padding: const EdgeInsets.all(6),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 18,
        crossAxisSpacing: 18,
        mainAxisExtent: 172,
      ),
      itemCount: devices.length,
      itemBuilder: (context, i) {
        final device = devices[i];
        return TvFocusable(
          onSelect: device.actions.isEmpty ? null : () => _openActions(device),
          child: _DeviceSummary(device: device, status: _status[device.key]),
        );
      },
    );
  }
}

/// Nom, grandeur principale, une lecture secondaire : ce qui tient dans une
/// tuile lue de loin.
class _DeviceSummary extends StatelessWidget {
  final DeviceSnapshot device;
  final String? status;
  final bool large;

  const _DeviceSummary({required this.device, this.status, this.large = false});

  @override
  Widget build(BuildContext context) {
    final readings = tvShownReadings(device);
    final primary = readings.isEmpty ? null : readings.first;
    final secondary = readings.skip(1).take(large ? 3 : 1);
    final isPosition = primary?.name == 'current_position';
    final count = device.actions.length;

    return Column(
      mainAxisSize: large ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          device.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: large ? 24 : 19,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            primary == null
                ? 'Pas de mesure'
                // Position et température se lisent d'elles-mêmes ; une
                // batterie seule à « 100 % » ne dirait pas de quoi il s'agit.
                : tvSelfExplanatory.contains(primary.name)
                ? tvReadingValue(primary)
                : '${tvReadingLabel(primary.name)} ${tvReadingValue(primary)}',
            style: TextStyle(
              fontSize: primary == null ? 18 : (large ? 34 : 27),
              fontWeight: FontWeight.w700,
              color: primary == null ? TvColors.muted : TvColors.text,
            ),
          ),
        ),
        if (isPosition) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: (primary!.value! / 100).clamp(0, 1).toDouble(),
              minHeight: 6,
              backgroundColor: TvColors.panelHigh,
              color: TvColors.focus,
            ),
          ),
        ],
        for (final r in secondary)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${tvReadingLabel(r.name)} ${tvReadingValue(r)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: TvColors.muted),
            ),
          ),
        if (!large) ...[
          const Spacer(),
          Text(
            status ??
                (count == 0 ? '' : '$count commande${count > 1 ? 's' : ''}'),
            maxLines: 1,
            style: TextStyle(
              fontSize: 14,
              color: status == null ? TvColors.muted : TvColors.focus,
            ),
          ),
        ],
      ],
    );
  }
}

/// Panneau des commandes d'un appareil. Il se redessine chaque seconde pour
/// suivre la relecture en cours : un volet qui monte voit sa position bouger.
class _ActionsDialog extends StatefulWidget {
  final String deviceKey;
  final List<DeviceSnapshot> Function() devices;
  final String? Function() status;
  final ValueChanged<DeviceAction> onAction;

  const _ActionsDialog({
    required this.deviceKey,
    required this.devices,
    required this.status,
    required this.onAction,
  });

  @override
  State<_ActionsDialog> createState() => _ActionsDialogState();
}

class _ActionsDialogState extends State<_ActionsDialog> {
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
    final status = widget.status();
    return Dialog(
      backgroundColor: TvColors.panel,
      insetPadding: const EdgeInsets.symmetric(horizontal: 160, vertical: 60),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DeviceSummary(device: device, large: true),
            const SizedBox(height: 22),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final (i, action) in device.actions.indexed)
                  TvFocusable(
                    autofocus: i == 0,
                    focusScale: 1.06,
                    color: TvColors.panelHigh,
                    focusedColor: TvColors.focus.withValues(alpha: 0.35),
                    radius: BorderRadius.circular(12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 12,
                    ),
                    onSelect: () => widget.onAction(action),
                    child: Text(
                      tvActionLabel(action.name),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              status ?? 'OK envoie la commande · Retour ferme',
              style: TextStyle(
                fontSize: 15,
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

class TvGroupsTab extends StatefulWidget {
  final BoxDevice box;
  final List<ActionGroup> groups;

  const TvGroupsTab({super.key, required this.box, required this.groups});

  @override
  State<TvGroupsTab> createState() => _TvGroupsTabState();
}

class _TvGroupsTabState extends State<TvGroupsTab> {
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

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      clipBehavior: Clip.none,
      padding: const EdgeInsets.all(6),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 20,
        crossAxisSpacing: 20,
        mainAxisExtent: 210,
      ),
      itemCount: widget.groups.length,
      itemBuilder: (context, i) {
        final group = widget.groups[i];
        final tint = _parseColor(group.color) ?? TvColors.focus;
        final status = _status[group.key];
        return TvFocusable(
          onSelect: group.enabled ? () => _run(group) : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child:
                    group.iconPath != null
                        ? CustomPaint(
                          painter: TvIconPainter(group.iconPath!, tint),
                        )
                        : Center(
                          child: Text(
                            group.icon.isEmpty ? '▶' : group.icon,
                            style: TextStyle(fontSize: 40, color: tint),
                          ),
                        ),
              ),
              const SizedBox(height: 12),
              Text(
                group.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                status ??
                    (group.enabled
                        ? '${group.actionCount} action${group.actionCount > 1 ? 's' : ''}'
                        : 'Désactivé'),
                style: TextStyle(
                  fontSize: 14,
                  color: status == null ? TvColors.muted : TvColors.focus,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Color? _parseColor(String hex) {
    final clean = hex.replaceFirst('#', '');
    if (clean.length != 6) return null;
    final value = int.tryParse(clean, radix: 16);
    return value == null ? null : Color(0xFF000000 | value);
  }
}

/// Icône Material Design Icons, tracée depuis son chemin SVG (grille 24×24).
class TvIconPainter extends CustomPainter {
  final String data;
  final Color color;

  TvIconPainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    try {
      final path = parseSvgPathData(data);
      canvas.scale(size.width / 24, size.height / 24);
      canvas.drawPath(path, Paint()..color = color);
    } catch (_) {
      // Tracé illisible : la tuile garde son nom, sans icône.
    }
  }

  @override
  bool shouldRepaint(TvIconPainter old) =>
      old.data != data || old.color != color;
}

// ---------------------------------------------------------------------------
// Thermostats
// ---------------------------------------------------------------------------

class TvThermostatsTab extends StatelessWidget {
  final BoxDevice box;
  final List<ThermostatZone> zones;
  final ValueChanged<List<ThermostatZone>> onChanged;

  const TvThermostatsTab({
    super.key,
    required this.box,
    required this.zones,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      clipBehavior: Clip.none,
      padding: const EdgeInsets.all(6),
      itemCount: zones.length,
      separatorBuilder: (_, __) => const SizedBox(height: 24),
      itemBuilder:
          (context, i) =>
              _ZoneCard(box: box, zone: zones[i], onChanged: onChanged),
    );
  }
}

class _ZoneCard extends StatefulWidget {
  final BoxDevice box;
  final ThermostatZone zone;
  final ValueChanged<List<ThermostatZone>> onChanged;

  const _ZoneCard({
    required this.box,
    required this.zone,
    required this.onChanged,
  });

  @override
  State<_ZoneCard> createState() => _ZoneCardState();
}

class _ZoneCardState extends State<_ZoneCard> {
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

  KeyEventResult _onSetpointKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final step =
        event.logicalKey == LogicalKeyboardKey.arrowRight
            ? 0.5
            : event.logicalKey == LogicalKeyboardKey.arrowLeft
            ? -0.5
            : 0.0;
    if (step == 0) return KeyEventResult.ignored;
    setState(() => _pending += step);
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), _sendSetpoint);
    return KeyEventResult.handled;
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

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: TvColors.panel,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 230,
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
          const SizedBox(width: 40),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      z.name,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 16),
                    TvPill(stateLabel, stateColor),
                    if (z.frost) ...[
                      const SizedBox(width: 8),
                      const TvPill('Hors-gel', TvColors.cool),
                    ],
                    if (_busy) ...[
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
                const SizedBox(height: 18),
                TvFocusable(
                  autofocus: false,
                  focusScale: 1,
                  color: TvColors.panelHigh,
                  onKey: _onSetpointKey,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      const Text('Consigne', style: TextStyle(fontSize: 18)),
                      const Spacer(),
                      const Icon(
                        Icons.chevron_left,
                        color: TvColors.muted,
                        size: 32,
                      ),
                      Text(
                        '${tvNumber(_shownSetpoint, decimals: 1)} °C',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        color: TvColors.muted,
                        size: 32,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final (mode, label) in const [
                      (0, 'Auto'),
                      (1, 'Marche'),
                      (2, 'Arrêt'),
                    ])
                      _modeChip(
                        label,
                        selected: z.forceMode == mode,
                        onSelect:
                            () => _command(
                              () => ThermostatService.command(
                                widget.box,
                                z.name,
                                forceMode: mode,
                                mdnsResolver: resolveMdnsIP,
                              ),
                            ),
                      ),
                    if (z.reversible)
                      _modeChip(
                        z.heating ? 'Passer en froid' : 'Passer en chaud',
                        selected: false,
                        onSelect:
                            () => _command(
                              () => ThermostatService.command(
                                widget.box,
                                z.name,
                                heat: !z.heating,
                                mdnsResolver: resolveMdnsIP,
                              ),
                            ),
                      ),
                    _modeChip(
                      'Hors-gel',
                      selected: z.frost,
                      onSelect:
                          () => _command(
                            () => ThermostatService.command(
                              widget.box,
                              z.name,
                              toggleFrost: true,
                              mdnsResolver: resolveMdnsIP,
                            ),
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const TvHints([
                  (
                    '← →',
                    'Consigne ±0,5 °C, envoyée 1 s après le dernier appui',
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeChip(
    String label, {
    required bool selected,
    required VoidCallback onSelect,
  }) {
    return TvFocusable(
      focusScale: 1.06,
      color: selected ? TvColors.text : TvColors.panelHigh,
      radius: BorderRadius.circular(10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      onSelect: _busy ? null : onSelect,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: selected ? TvColors.background : TvColors.text,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Interface web
// ---------------------------------------------------------------------------

class TvWebTab extends StatefulWidget {
  final TvBox box;

  const TvWebTab({super.key, required this.box});

  @override
  State<TvWebTab> createState() => _TvWebTabState();
}

class _TvWebTabState extends State<TvWebTab> {
  bool _opening = false;
  String? _error;

  Future<void> _open() async {
    setState(() {
      _opening = true;
      _error = null;
    });
    final found = await TvData.reachableRoute(widget.box.device);
    if (!mounted) return;
    setState(() => _opening = false);
    if (found == null) {
      setState(() => _error = 'La box ne répond pas.');
      return;
    }
    final (candidate, route) = found;
    final device = widget.box.device;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => WebViewDeviceScreen(
              deviceEntry: widget.box.entry,
              url: route.baseUrl,
              isFallback: candidate != device.primaryUrl,
              hasFallback: device.fallbackUrl?.isNotEmpty ?? false,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Pour la configuration avancée de la box. Les flèches passent '
              'd\'un bouton ou d\'un champ au suivant ; OK maintenu bascule '
              'sur un pointeur libre.',
              style: TextStyle(fontSize: 18, color: TvColors.muted),
            ),
            const SizedBox(height: 24),
            TvFocusable(
              onSelect: _opening ? null : _open,
              color: TvColors.focus.withValues(alpha: 0.2),
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _opening
                      ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                      : const Icon(Icons.open_in_browser, size: 26),
                  const SizedBox(width: 14),
                  const Text(
                    'Ouvrir l\'interface web',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: const TextStyle(fontSize: 16, color: TvColors.bad),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

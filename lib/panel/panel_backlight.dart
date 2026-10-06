import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Rétroéclairage du panneau, piloté par le service de son fabricant.
///
/// Sur un NSPanel Pro, la veille de l'écran n'est pas celle d'Android :
/// c'est l'application du constructeur qui éteint et rallume l'écran, et elle
/// ne le rallume plus au toucher quand le kiosque est au premier plan.
class PanelBacklight {
  PanelBacklight._();

  static const _channel = MethodChannel('com.lixee.assist/panel');
  static const _delayPref = 'panel_sleep_minutes';

  // Lues aussi par le code natif (PanelKiosk), qui lance le kiosque au
  // démarrage du panneau et le ramène au premier plan.
  static const _autostartPref = 'panel_autostart';
  static const _returnPref = 'panel_return_minutes';

  /// Délais de retour au kiosque proposés, en minutes ; 0 = jamais.
  static const returnDelays = [1, 2, 5, 10, 0];
  static const defaultReturnDelay = 2;

  /// Délais de veille proposés, en minutes ; 0 = jamais.
  static const delays = [1, 2, 5, 10, 30, 0];
  static const defaultDelay = 2;

  static bool _supported = false;

  /// Le panneau a-t-il un rétroéclairage que le kiosque sait piloter ?
  static bool get supported => _supported;

  static Future<void> init() async {
    try {
      _supported =
          await _channel.invokeMethod<bool>('backlightSupported') ?? false;
    } catch (_) {
      _supported = false;
    }
  }

  static Future<void> set(bool on) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('setBacklight', on);
    } catch (_) {
      // L'écran reste dans son état : rien d'autre à tenter.
    }
  }

  /// Niveau réel (0 = éteint), `null` s'il est illisible.
  static Future<int?> level() async {
    if (!_supported) return null;
    try {
      return await _channel.invokeMethod<int>('backlightLevel');
    } catch (_) {
      return null;
    }
  }

  static Future<int> sleepMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_delayPref) ?? defaultDelay;
  }

  static Future<void> setSleepMinutes(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_delayPref, minutes);
    changes.value++;
  }

  static Future<bool> autostart() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autostartPref) ?? true;
  }

  static Future<void> setAutostart(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autostartPref, enabled);
  }

  static Future<int> returnMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_returnPref) ?? defaultReturnDelay;
  }

  static Future<void> setReturnMinutes(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_returnPref, minutes);
  }

  /// Le kiosque vient-il d'être ramené devant, écran éteint ? Dans ce cas il
  /// ne doit pas le rallumer : personne n'est devant le panneau.
  static Future<bool> takeQuietLaunch() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('takeQuietLaunch') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Incrémenté quand le délai de veille change, pour relancer la minuterie.
  static final changes = ValueNotifier<int>(0);
}

/// Veille de l'écran du kiosque : il s'éteint après un délai sans appui, et
/// le premier toucher le rallume sans rien déclencher dessous.
class PanelWake extends StatefulWidget {
  final Widget child;

  const PanelWake({super.key, required this.child});

  @override
  State<PanelWake> createState() => _PanelWakeState();
}

class _PanelWakeState extends State<PanelWake> with WidgetsBindingObserver {
  bool _dark = false;
  bool _foreground = true;
  int _minutes = PanelBacklight.defaultDelay;
  Timer? _idle;
  Timer? _watch;

  @override
  void initState() {
    super.initState();
    if (!PanelBacklight.supported) return;
    WidgetsBinding.instance.addObserver(this);
    PanelBacklight.changes.addListener(_loadDelay);
    _loadDelay();
    _arrive();
    // L'écran peut aussi être éteint par l'application du constructeur :
    // on suit son état réel, pour que le toucher suivant ne fasse que
    // rallumer.
    _watch = Timer.periodic(const Duration(seconds: 2), (_) => _sync());
  }

  @override
  void dispose() {
    if (PanelBacklight.supported) {
      WidgetsBinding.instance.removeObserver(this);
      PanelBacklight.changes.removeListener(_loadDelay);
    }
    _idle?.cancel();
    _watch?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _arrive();
    } else {
      // En arrière-plan, l'écran revient à l'application qui est devant.
      _idle?.cancel();
    }
  }

  Future<void> _loadDelay() async {
    final minutes = await PanelBacklight.sleepMinutes();
    if (!mounted) return;
    _minutes = minutes;
    _restart();
  }

  Future<void> _sync() async {
    if (!_foreground) return;
    final level = await PanelBacklight.level();
    if (!mounted || level == null) return;
    final dark = level == 0;
    if (dark != _dark) {
      setState(() => _dark = dark);
      if (!dark) _restart();
    }
  }

  void _restart() {
    _idle?.cancel();
    if (_minutes <= 0 || !_foreground) return;
    _idle = Timer(Duration(minutes: _minutes), _sleep);
  }

  void _sleep() {
    if (!mounted || !_foreground) return;
    setState(() => _dark = true);
    PanelBacklight.set(false);
  }

  /// Le kiosque passe au premier plan : il allume l'écran, sauf s'il y
  /// revient de lui-même pendant que l'écran dort.
  Future<void> _arrive() async {
    if (await PanelBacklight.takeQuietLaunch()) {
      if (mounted) setState(() => _dark = true);
      _idle?.cancel();
      return;
    }
    _wake();
  }

  void _wake() {
    PanelBacklight.set(true);
    if (_dark && mounted) setState(() => _dark = false);
    _restart();
  }

  @override
  Widget build(BuildContext context) {
    if (!PanelBacklight.supported) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      // Écran éteint : l'appui est absorbé ci-dessous, il ne fait que
      // rallumer. Écran allumé : il repousse la veille.
      onPointerDown: (_) => _dark ? null : _restart(),
      onPointerUp: (_) => _dark ? _wake() : null,
      child: AbsorbPointer(absorbing: _dark, child: widget.child),
    );
  }
}

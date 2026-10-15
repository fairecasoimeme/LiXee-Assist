import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Vue sur laquelle le kiosque s'ouvre.
enum KioskTab { energy, savings, devices, groups, thermostats }

extension KioskTabLabel on KioskTab {
  String get label => switch (this) {
    KioskTab.energy => 'Énergie',
    KioskTab.savings => 'Économies',
    KioskTab.devices => 'Appareils',
    KioskTab.groups => 'Groupes',
    KioskTab.thermostats => 'Thermostats',
  };
}

/// Le mode d'affichage de l'application : l'interface normale du téléphone,
/// ou le kiosque — le tableau de bord tactile des panneaux muraux.
///
/// Un panneau mural est toujours en kiosque, une TV a son interface à elle.
/// Sur un téléphone ou une tablette, l'utilisateur choisit : passer au
/// kiosque le temps d'un coup d'œil, ou y démarrer d'office pour un appareil
/// laissé au mur.
class AppMode {
  AppMode._();

  static const _startPref = 'app_start_kiosk';
  static const _kioskAwakePref = 'kiosk_keep_awake';
  static const _kioskFullscreenPref = 'kiosk_fullscreen';
  static const _kioskTabPref = 'kiosk_start_tab';
  static const _kioskRefreshPref = 'kiosk_refresh_seconds';
  static const _normalAwakePref = 'normal_keep_awake';

  /// Intervalles d'actualisation proposés, en secondes.
  static const refreshChoices = [15, 30, 60, 300];
  static const defaultRefresh = 30;

  /// Le kiosque est-il affiché ? L'application se reconstruit à chaque
  /// changement.
  static final kiosk = ValueNotifier<bool>(false);

  static bool _panel = false;
  static bool _tv = false;
  static late SharedPreferences _prefs;

  /// L'appareil est-il un panneau mural, où le kiosque est le seul mode ?
  static bool get dedicated => _panel;

  /// Peut-on passer d'un mode à l'autre ? Ni sur un panneau, ni sur une TV.
  static bool get canSwitch => !_panel && !_tv;

  static Future<void> init({required bool panel, required bool tv}) async {
    _panel = panel;
    _tv = tv;
    _prefs = await SharedPreferences.getInstance();
    kiosk.value = panel || (canSwitch && startInKiosk);
    await applyDisplay();
  }

  // --- Réglages ------------------------------------------------------------

  /// L'application s'ouvre-t-elle en kiosque ?
  static bool get startInKiosk => _prefs.getBool(_startPref) ?? false;
  static Future<void> setStartInKiosk(bool value) =>
      _prefs.setBool(_startPref, value);

  /// En kiosque, l'écran reste-t-il allumé ? Oui par défaut : un tableau de
  /// bord qui s'éteint au bout de trente secondes ne sert à rien.
  static bool get kioskKeepAwake => _prefs.getBool(_kioskAwakePref) ?? true;
  static Future<void> setKioskKeepAwake(bool value) async {
    await _prefs.setBool(_kioskAwakePref, value);
    await applyDisplay();
  }

  /// En kiosque, les barres du système sont-elles masquées ?
  static bool get kioskFullscreen =>
      _prefs.getBool(_kioskFullscreenPref) ?? false;
  static Future<void> setKioskFullscreen(bool value) async {
    await _prefs.setBool(_kioskFullscreenPref, value);
    await applyDisplay();
  }

  static KioskTab get kioskStartTab {
    final name = _prefs.getString(_kioskTabPref);
    return KioskTab.values.where((t) => t.name == name).firstOrNull ??
        KioskTab.energy;
  }

  static Future<void> setKioskStartTab(KioskTab tab) =>
      _prefs.setString(_kioskTabPref, tab.name);

  /// Intervalle entre deux relevés de la vue affichée, en secondes.
  static int get kioskRefreshSeconds {
    final seconds = _prefs.getInt(_kioskRefreshPref);
    return refreshChoices.contains(seconds) ? seconds! : defaultRefresh;
  }

  static Future<void> setKioskRefreshSeconds(int seconds) async {
    await _prefs.setInt(_kioskRefreshPref, seconds);
    refreshChanges.value++;
  }

  /// Incrémenté quand l'intervalle d'actualisation change, pour que le
  /// kiosque affiché relance sa minuterie.
  static final refreshChanges = ValueNotifier<int>(0);

  /// En mode normal, l'écran reste-t-il allumé tant que l'application est
  /// affichée ? Non par défaut, comme toute application.
  static bool get normalKeepAwake => _prefs.getBool(_normalAwakePref) ?? false;
  static Future<void> setNormalKeepAwake(bool value) async {
    await _prefs.setBool(_normalAwakePref, value);
    await applyDisplay();
  }

  // --- Bascule -------------------------------------------------------------

  static Future<void> enterKiosk() async {
    if (!canSwitch) return;
    kiosk.value = true;
    await applyDisplay();
  }

  static Future<void> leaveKiosk() async {
    if (!canSwitch) return;
    kiosk.value = false;
    await applyDisplay();
  }

  /// Met l'écran dans l'état que demande le mode affiché.
  ///
  /// Un panneau mural gère sa propre veille (voir `PanelWake`) et une TV ne
  /// s'éteint pas : rien à faire sur ces appareils.
  static Future<void> applyDisplay() async {
    if (!canSwitch) return;
    final awake = kiosk.value ? kioskKeepAwake : normalKeepAwake;
    try {
      await WakelockPlus.toggle(enable: awake);
    } catch (e) {
      debugPrint('[MODE] Écran allumé non appliqué: $e');
    }
    // Les barres du système ne sont touchées que pour le plein écran, et
    // rendues telles quelles en le quittant : l'interface normale garde la
    // présentation qu'elle a toujours eue.
    final immersive = kiosk.value && kioskFullscreen;
    if (immersive == _immersive) return;
    _immersive = immersive;
    if (immersive) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  static bool _immersive = false;
}

/// « 30 s », « 1 min » : un intervalle d'actualisation, en clair.
String refreshLabel(int seconds) =>
    seconds < 60 ? '$seconds s' : '${seconds ~/ 60} min';

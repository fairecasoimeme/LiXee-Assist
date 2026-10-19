import 'dart:io';
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';

/// Largeur de travail du kiosque, en pixels logiques. Le NSPanel Pro a un
/// écran carré de 480 × 480, le NSPanel Pro 120 un écran vertical de
/// 750 × 1334 : les vues s'étirent en hauteur.
const double panelDesignSide = 480;

/// Détecte un panneau mural (Sonoff NSPanel Pro et écrans du même genre),
/// qui reçoit le kiosque tactile à la place de l'interface du téléphone.
class PanelDetector {
  PanelDetector._();

  static bool _isPanel = false;
  static bool get isPanel => _isPanel;

  static Future<void> init() async {
    // --dart-define=FORCE_PANEL=true : essayer le kiosque sur un téléphone.
    if (const bool.fromEnvironment('FORCE_PANEL')) {
      _isPanel = true;
      return;
    }
    if (!Platform.isAndroid) return;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final names =
          '${info.manufacturer} ${info.brand} ${info.model} ${info.product} '
                  '${info.device}'
              .toLowerCase();
      debugPrint('[PANEL] Appareil : $names');
      // Les NSPanel Pro ne portent pas leur nom : ils se déclarent comme la
      // carte de référence Rockchip dont ils dérivent, « px30_evb ».
      if (names.contains('nspanel') || names.contains('px30_evb')) {
        _isPanel = true;
        return;
      }
    } catch (_) {
      // Sans informations sur l'appareil, il reste la forme de l'écran.
    }
    // Un petit écran carré n'est pas un téléphone.
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isEmpty) return;
    final size = views.first.physicalSize;
    if (size.isEmpty) return;
    final ratio = size.longestSide / size.shortestSide;
    _isPanel = ratio < 1.15 && size.shortestSide <= 800;
  }
}

/// Met l'interface à l'échelle : son petit côté vaut toujours
/// [panelDesignSide], quelle que soit la densité que le panneau déclare.
///
/// Placé dans le `builder` de l'application, il couvre aussi les dialogues,
/// et le clavier garde sa vraie hauteur une fois ramenée à cette échelle.
class PanelScale extends StatelessWidget {
  final Widget child;

  const PanelScale({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final scale = mq.size.shortestSide / panelDesignSide;
    if (scale <= 0 || (scale - 1).abs() < 0.01) return child;
    final size = mq.size / scale;
    return FittedBox(
      fit: BoxFit.fill,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: MediaQuery(
          data: mq.copyWith(
            size: size,
            padding: mq.padding / scale,
            viewPadding: mq.viewPadding / scale,
            viewInsets: mq.viewInsets / scale,
          ),
          child: child,
        ),
      ),
    );
  }
}

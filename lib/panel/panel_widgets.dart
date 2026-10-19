import 'dart:async';

import 'package:flutter/material.dart';

import '../tv/tv_theme.dart';

/// Une surface qu'on touche : assez grande pour le doigt, avec un retour
/// visuel à l'appui.
class PanelTap extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color color;
  final EdgeInsetsGeometry padding;
  final double radius;

  const PanelTap({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.color = TvColors.panel,
    this.padding = const EdgeInsets.all(12),
    this.radius = 14,
  });

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return Material(
      color: color,
      borderRadius: shape,
      child: InkWell(
        borderRadius: shape,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Bouton rond à icône, de 44 pixels : la taille minimale d'une cible au
/// doigt.
class PanelIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color color;

  const PanelIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.color = TvColors.muted,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 44,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Icon(icon, color: color, size: 24),
        ),
      ),
    );
  }
}

/// Heure courante, pour un panneau qui reste allumé au mur.
class PanelClock extends StatefulWidget {
  const PanelClock({super.key});

  @override
  State<PanelClock> createState() => _PanelClockState();
}

class _PanelClockState extends State<PanelClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 10),
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
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return Text(
      '${two(now.hour)}:${two(now.minute)}',
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: TvColors.text,
      ),
    );
  }
}

/// Page secondaire du kiosque : un bandeau avec retour et titre, puis le
/// contenu.
class PanelPage extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const PanelPage({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TvColors.background,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  PanelIconButton(
                    icon: Icons.arrow_back,
                    color: TvColors.text,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (trailing != null) trailing!,
                  const SizedBox(width: 8),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// Bouton plein, pour l'action principale d'une page.
class PanelButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color color;
  final Color textColor;

  const PanelButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.color = TvColors.focus,
    this.textColor = TvColors.background,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: PanelTap(
        onTap: onTap,
        color: color,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: textColor),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

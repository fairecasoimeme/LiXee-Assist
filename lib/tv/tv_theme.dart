import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Palette et gabarits de la version TV.
///
/// Fond sombre : une TV s'allume souvent dans une pièce peu éclairée, et un
/// écran blanc y éblouit. Les tailles visent un écran lu à trois mètres.
class TvColors {
  TvColors._();

  static const background = Color(0xFF0E141B);
  static const panel = Color(0xFF18222D);
  static const panelHigh = Color(0xFF22303E);
  static const text = Color(0xFFEEF3F8);
  static const muted = Color(0xFF93A3B5);
  static const focus = Color(0xFF4FA8FF);
  static const ok = Color(0xFF3CC47C);
  static const warn = Color(0xFFF0A33A);
  static const bad = Color(0xFFE5534B);
  static const solar = Color(0xFF2EB872);
  static const heat = Color(0xFFE74C3C);
  static const cool = Color(0xFF2980B9);
}

/// Thème Material de la version TV, pour les dialogues et les champs.
ThemeData tvTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: TvColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: TvColors.focus,
      surface: TvColors.panel,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: TvColors.panel),
    textTheme: base.textTheme.apply(
      bodyColor: TvColors.text,
      displayColor: TvColors.text,
    ),
  );
}

/// Touches qui valident, selon la télécommande ou le clavier branché.
bool isSelectKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.select ||
    key == LogicalKeyboardKey.enter ||
    key == LogicalKeyboardKey.numpadEnter ||
    key == LogicalKeyboardKey.gameButtonA;

/// Touche Menu de la télécommande (☰).
bool isMenuKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.contextMenu ||
    key == LogicalKeyboardKey.gameButtonY;

/// Touche Retour, quand un écran veut l'intercepter avant la navigation.
bool isBackKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.goBack ||
    key == LogicalKeyboardKey.escape ||
    key == LogicalKeyboardKey.browserBack;

/// Un élément qu'on sélectionne aux flèches et qu'on active avec OK.
///
/// Sélectionné, il grossit un peu et prend un cadre bleu : c'est le seul
/// repère de l'utilisateur, il doit se voir de loin. Il se fait aussi
/// défiler à l'écran quand il en sort.
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSelect;
  final VoidCallback? onMenu;

  /// Reçoit les touches avant le parcours aux flèches. Rendre
  /// [KeyEventResult.handled] garde la touche, par exemple gauche et droite
  /// sur un réglage de consigne.
  final KeyEventResult Function(KeyEvent event)? onKey;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final FocusNode? focusNode;
  final BorderRadius radius;
  final Color color;
  final Color? focusedColor;
  final EdgeInsetsGeometry padding;
  final double focusScale;

  const TvFocusable({
    super.key,
    required this.child,
    this.onSelect,
    this.onMenu,
    this.onKey,
    this.onFocusChange,
    this.autofocus = false,
    this.focusNode,
    this.radius = const BorderRadius.all(Radius.circular(14)),
    this.color = TvColors.panel,
    this.focusedColor,
    this.padding = const EdgeInsets.all(16),
    this.focusScale = 1.04,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final custom = widget.onKey?.call(event);
    if (custom == KeyEventResult.handled) return custom!;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (isSelectKey(event.logicalKey) && widget.onSelect != null) {
      widget.onSelect!();
      return KeyEventResult.handled;
    }
    if (isMenuKey(event.logicalKey) && widget.onMenu != null) {
      widget.onMenu!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleFocus(bool focused) {
    setState(() => _focused = focused);
    widget.onFocusChange?.call(focused);
    if (focused) {
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 180),
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _handleKey,
      onFocusChange: _handleFocus,
      child: GestureDetector(
        // Au doigt aussi : pratique pour essayer l'interface sur un téléphone.
        onTap: widget.onSelect,
        onLongPress: widget.onMenu,
        child: AnimatedScale(
          scale: _focused && !reduceMotion ? widget.focusScale : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: widget.padding,
            decoration: BoxDecoration(
              color:
                  _focused
                      ? (widget.focusedColor ?? widget.color)
                      : widget.color,
              borderRadius: widget.radius,
              border: Border.all(
                color: _focused ? TvColors.focus : Colors.transparent,
                width: 3,
              ),
              boxShadow:
                  _focused
                      ? [
                        BoxShadow(
                          color: TvColors.focus.withValues(alpha: 0.35),
                          blurRadius: 24,
                        ),
                      ]
                      : const [],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Pastille d'état : un point et un mot, lisibles de loin.
class TvPill extends StatelessWidget {
  final String label;
  final Color color;

  const TvPill(this.label, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bandeau du haut : logo et fil d'Ariane.
class TvHeader extends StatelessWidget {
  final List<String> trail;
  final Widget? trailing;

  const TvHeader({super.key, this.trail = const [], this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              const Text.rich(
                TextSpan(
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: TvColors.text,
                  ),
                  children: [
                    TextSpan(text: 'li'),
                    TextSpan(
                      text: 'X',
                      style: TextStyle(color: TvColors.focus),
                    ),
                    TextSpan(text: 'ee Assist'),
                  ],
                ),
              ),
              for (final (i, step) in trail.indexed) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    '›',
                    style: TextStyle(fontSize: 20, color: TvColors.muted),
                  ),
                ),
                Flexible(
                  child: Text(
                    step,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight:
                          i == trail.length - 1
                              ? FontWeight.w700
                              : FontWeight.w400,
                      color:
                          i == trail.length - 1
                              ? TvColors.text
                              : TvColors.muted,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        // Hors de la rangée extensible : sinon le fil d'Ariane et l'espace
        // se partagent la largeur, et la pastille échoue au milieu.
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// Rappel des touches, en bas d'écran.
class TvHints extends StatelessWidget {
  final List<(String key, String label)> hints;

  const TvHints(this.hints, {super.key});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 24,
      runSpacing: 6,
      children: [
        for (final (key, label) in hints)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Sans touche, l'indication est une simple précision.
              if (key.isNotEmpty) ...[
                Container(
                  constraints: const BoxConstraints(minWidth: 26),
                  height: 26,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: TvColors.panelHigh,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    key,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: TvColors.text,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: const TextStyle(fontSize: 14, color: TvColors.muted),
              ),
            ],
          ),
      ],
    );
  }
}

/// Mise en forme française des nombres : virgule décimale, espace fine
/// entre milliers.
String tvNumber(num value, {int decimals = 0}) {
  final fixed = value.toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final negative = parts[0].startsWith('-');
  final digits = negative ? parts[0].substring(1) : parts[0];
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(' ');
    grouped.write(digits[i]);
  }
  final whole = '${negative ? '−' : ''}$grouped';
  return parts.length > 1 ? '$whole,${parts[1]}' : whole;
}

/// « il y a 3 min », « il y a 2 h », « hier ».
String tvAge(DateTime when) {
  final age = DateTime.now().difference(when);
  if (age.inMinutes < 1) return "à l'instant";
  if (age.inMinutes < 60) return 'il y a ${age.inMinutes} min';
  if (age.inHours < 24) return 'il y a ${age.inHours} h';
  if (age.inDays == 1) return 'hier';
  return 'il y a ${age.inDays} jours';
}

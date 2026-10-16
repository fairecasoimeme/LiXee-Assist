import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tv/tv_theme.dart';

/// Petites barres pour illustrer un conseil avec les mesures de la maison :
/// les jours du mois, les heures d'une journée, les pics de puissance.
///
/// Une barre peut être mise en avant ([highlight]) et une ligne de repère
/// tracée en pointillés ([line], avec son libellé [lineLabel]).
class PanelMiniBars extends StatelessWidget {
  final List<double> values;
  final Color color;
  final int? highlight;
  final Color? highlightColor;
  final double? line;
  final String? lineLabel;
  final Color lineColor;

  /// Libellés sous l'axe, répartis de gauche à droite.
  final List<String> labels;
  final double height;

  const PanelMiniBars({
    super.key,
    required this.values,
    this.color = TvColors.focus,
    this.highlight,
    this.highlightColor,
    this.line,
    this.lineLabel,
    this.lineColor = TvColors.warn,
    this.labels = const [],
    this.height = 64,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: height,
          child: CustomPaint(
            painter: _MiniBarsPainter(
              values,
              color,
              highlight,
              highlightColor ?? color,
              line,
              lineLabel,
              lineColor,
            ),
          ),
        ),
        if (labels.isNotEmpty) ...[
          const SizedBox(height: 3),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final label in labels)
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: TvColors.muted),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _MiniBarsPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final int? highlight;
  final Color highlightColor;
  final double? line;
  final String? lineLabel;
  final Color lineColor;

  _MiniBarsPainter(
    this.values,
    this.color,
    this.highlight,
    this.highlightColor,
    this.line,
    this.lineLabel,
    this.lineColor,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final top = math.max(values.fold<double>(0, math.max), (line ?? 0) * 1.12);
    if (top <= 0) return;
    final slot = size.width / values.length;
    final width = math.max(1.0, slot * 0.64);
    for (final (i, v) in values.indexed) {
      if (v <= 0) continue;
      final h = math.max(2.0, size.height * v / top);
      final chosen = i == highlight;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(
            i * slot + (slot - width) / 2,
            size.height - h,
            width,
            h,
          ),
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(2),
        ),
        Paint()
          ..color =
              chosen
                  ? highlightColor
                  : color.withValues(alpha: highlight == null ? 0.75 : 0.45),
      );
    }

    final mark = line;
    if (mark != null && mark > 0) {
      final y = size.height - size.height * mark / top;
      final paint =
          Paint()
            ..color = lineColor
            ..strokeWidth = 1.4;
      for (var x = 0.0; x < size.width; x += 8) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 5, size.width), y),
          paint,
        );
      }
      if (lineLabel case final text?) {
        final label = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontSize: 10.5,
              color: lineColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(
          canvas,
          Offset(size.width - label.width, math.max(0, y - label.height - 1)),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_MiniBarsPainter old) =>
      old.values != values || old.highlight != highlight || old.line != line;
}

/// Une jauge horizontale : où se situe une puissance par rapport au
/// maximum de l'abonnement, avec le seuil de 80 % marqué.
class PanelPeakMeter extends StatelessWidget {
  /// Part du maximum, de 0 à 1 (et au-delà en dépassement).
  final double ratio;
  final String leftLabel;
  final String rightLabel;

  const PanelPeakMeter({
    super.key,
    required this.ratio,
    required this.leftLabel,
    required this.rightLabel,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        ratio >= 0.9
            ? TvColors.bad
            : (ratio >= 0.7 ? TvColors.warn : TvColors.ok);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 14,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              return Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: TvColors.panelHigh,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  Container(
                    width: w * ratio.clamp(0.02, 1.0),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  // 80 % : au-delà, le disjoncteur n'est plus très loin.
                  Positioned(
                    left: w * 0.8 - 1,
                    top: 0,
                    bottom: 0,
                    child: Container(width: 2, color: TvColors.text),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                leftLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              rightLabel,
              style: const TextStyle(fontSize: 12, color: TvColors.muted),
            ),
          ],
        ),
      ],
    );
  }
}

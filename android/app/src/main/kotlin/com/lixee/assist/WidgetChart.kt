package com.lixee.assist

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.core.content.ContextCompat

/**
 * Histogramme de la consommation heure par heure sur les 24 dernières heures.
 *
 * Comme la jauge, il est dessiné au Canvas puis passé en bitmap : RemoteViews
 * n'accepte aucune vue personnalisée. Les barres expliquent d'où vient le
 * total journalier affiché à côté.
 */
object WidgetChart {

    private const val WIDTH_PX = 660
    private const val HEIGHT_PX = 150

    /** Une barre sur trois porte son heure, sinon l'axe devient illisible. */
    private const val LABEL_EVERY = 6

    data class Point(val hour: Int, val wh: Int)

    /**
     * Décode la série compacte publiée par HomeWidgetBridge : `18:1741,19:4052,…`.
     */
    fun parse(raw: String?): List<Point> {
        if (raw.isNullOrBlank()) return emptyList()
        return raw.split(',').mapNotNull { entry ->
            val parts = entry.split(':')
            if (parts.size < 2) return@mapNotNull null
            val hour = parts[0].trim().toIntOrNull() ?: return@mapNotNull null
            val wh = parts[1].trim().toIntOrNull() ?: return@mapNotNull null
            Point(hour, wh)
        }
    }

    private fun paint(context: Context, colorRes: Int) =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, colorRes)
        }

    fun render(context: Context, points: List<Point>): Bitmap {
        val bitmap = Bitmap.createBitmap(WIDTH_PX, HEIGHT_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        if (points.isEmpty()) return bitmap

        val labelHeight = HEIGHT_PX * 0.22f
        val plotHeight = HEIGHT_PX - labelHeight

        // La dernière heure est en cours, donc partielle : elle serait presque
        // toujours le minimum. On la dessine, mais on l'écarte du calcul du
        // pic et du creux, sinon le vert désignerait l'heure incomplète.
        val lastIndex = points.lastIndex
        val complete = if (points.size > 1) points.dropLast(1) else points

        // Une consommation nulle sur toute la plage ne doit pas diviser par zéro.
        val peak = (complete.maxOfOrNull { it.wh } ?: 0).coerceAtLeast(1)
        val trough = complete.minOfOrNull { it.wh } ?: 0
        // Série plate : mettre en avant un « pic » et un « creux » identiques
        // n'aurait aucun sens, on laisse toutes les barres neutres.
        val hasSpread = trough < peak

        val slot = WIDTH_PX.toFloat() / points.size
        val barWidth = slot * 0.62f
        val radius = barWidth / 2f

        val bar = paint(context, R.color.widget_accent)
        val peakBar = paint(context, R.color.widget_gauge_warn)
        val troughBar = paint(context, R.color.widget_positive)
        val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, R.color.widget_text_secondary)
            textSize = HEIGHT_PX * 0.19f
            textAlign = Paint.Align.CENTER
        }

        points.forEachIndexed { index, point ->
            val centerX = slot * index + slot / 2f
            // Plancher visible : une heure creuse doit rester repérable.
            // Plafond : le pic ignore l'heure en cours, qui pourrait donc le
            // dépasser et déborder du cadre.
            val height = (point.wh.toFloat() / peak * plotHeight).coerceIn(3f, plotHeight)
            canvas.drawRoundRect(
                centerX - barWidth / 2f,
                plotHeight - height,
                centerX + barWidth / 2f,
                plotHeight,
                radius,
                radius,
                when {
                    !hasSpread || index == lastIndex -> bar
                    point.wh == peak -> peakBar
                    point.wh == trough -> troughBar
                    else -> bar
                }
            )

            if (index % LABEL_EVERY == 0) {
                val text = "%02dh".format(point.hour)
                // Le libellé de la première barre déborderait à gauche : on le
                // ramène dans le cadre plutôt que de le laisser rogner.
                val half = label.measureText(text) / 2f
                canvas.drawText(
                    text,
                    centerX.coerceIn(half, WIDTH_PX - half),
                    HEIGHT_PX - labelHeight * 0.15f,
                    label
                )
            }
        }

        return bitmap
    }
}

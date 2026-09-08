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

    /** Une barre sur six porte son heure, sinon l'axe devient illisible. */
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

    /** Opacités des barres : pleine pour le pic, moyenne au fil de l'eau,
     *  faible pour le creux. Un dégradé d'intensité, pas de teinte. */
    private const val ALPHA_PEAK = 255
    private const val ALPHA_NORMAL = 115
    private const val ALPHA_TROUGH = 55

    private fun paint(context: Context, colorRes: Int, alpha: Int = 255) =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, colorRes)
            this.alpha = alpha
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

        // Les extrêmes sont marqués par l'intensité, pas par la teinte : une
        // heure de pointe n'est pas une alerte et une heure creuse n'est pas
        // une bonne nouvelle, ce sont des maxima. L'orange et le vert restent
        // réservés à la limite d'abonnement et à la tendance, où ils portent
        // un jugement.
        val bar = paint(context, R.color.widget_accent, ALPHA_NORMAL)
        val peakBar = paint(context, R.color.widget_accent, ALPHA_PEAK)
        val troughBar = paint(context, R.color.widget_accent, ALPHA_TROUGH)
        val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, R.color.widget_text_secondary)
            textSize = HEIGHT_PX * 0.19f
            textAlign = Paint.Align.CENTER
        }
        // L'heure en cours est le repère le plus utile d'une fenêtre glissante :
        // sans elle on lit « 10h · 16h · 22h » sans savoir où l'on se situe.
        val nowLabel = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, R.color.widget_accent)
            textSize = HEIGHT_PX * 0.19f
            textAlign = Paint.Align.CENTER
            isFakeBoldText = true
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

            // Compté depuis la fin : l'heure en cours est ainsi toujours
            // étiquetée, et les repères restent régulièrement espacés.
            if ((lastIndex - index) % LABEL_EVERY == 0) {
                val isNow = index == lastIndex
                val paint = if (isNow) nowLabel else label
                val text = "%02dh".format(point.hour)
                // Le libellé des barres extrêmes déborderait du cadre : on le
                // ramène dedans plutôt que de le laisser rogner.
                val half = paint.measureText(text) / 2f
                canvas.drawText(
                    text,
                    centerX.coerceIn(half, WIDTH_PX - half),
                    HEIGHT_PX - labelHeight * 0.15f,
                    paint
                )
            }
        }

        return bitmap
    }
}

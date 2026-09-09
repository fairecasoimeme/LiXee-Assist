package com.lixee.assist

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.core.content.ContextCompat
import kotlin.math.abs
import kotlin.math.max

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

    /** Opacités des barres : pleine pour le pic, moyenne au fil de l'eau,
     *  faible pour le creux. Un dégradé d'intensité, pas de teinte. */
    private const val ALPHA_PEAK = 255
    private const val ALPHA_NORMAL = 115
    private const val ALPHA_TROUGH = 55

    data class Point(val hour: Int, val wh: Int, val productionWh: Int = 0) {
        /** Positif si l'on a tiré du réseau, négatif si l'on y a injecté. */
        val netWh: Int get() = wh - productionWh
    }

    /** Grandeur portée par les barres. */
    enum class Series {
        DRAWN,
        INJECTED,

        /** Solde, tracé de part et d'autre d'une ligne zéro. */
        NET;

        fun valueOf(point: Point): Int = when (this) {
            DRAWN -> point.wh
            INJECTED -> point.productionWh
            NET -> point.netWh
        }
    }

    /**
     * Décode la série compacte publiée par HomeWidgetBridge :
     * `18:1741:0,19:4052:1433,…`. La production est facultative.
     */
    fun parse(raw: String?): List<Point> {
        if (raw.isNullOrBlank()) return emptyList()
        return raw.split(',').mapNotNull { entry ->
            val parts = entry.split(':')
            if (parts.size < 2) return@mapNotNull null
            val hour = parts[0].trim().toIntOrNull() ?: return@mapNotNull null
            val wh = parts[1].trim().toIntOrNull() ?: return@mapNotNull null
            Point(hour, wh, parts.getOrNull(2)?.trim()?.toIntOrNull() ?: 0)
        }
    }

    private fun paint(context: Context, colorRes: Int, alpha: Int = 255) =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, colorRes)
            this.alpha = alpha
        }

    /**
     * @param series grandeur portée par les barres. [Series.NET] les trace de
     *   part et d'autre d'une ligne zéro, consommation au-dessus et production
     *   en-dessous ; les autres partent du bas du cadre.
     */
    fun render(
        context: Context,
        points: List<Point>,
        series: Series = Series.DRAWN,
        accentColorRes: Int = R.color.widget_accent
    ): Bitmap {
        val bitmap = Bitmap.createBitmap(WIDTH_PX, HEIGHT_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        if (points.isEmpty()) return bitmap

        val labelHeight = HEIGHT_PX * 0.22f
        val plotHeight = HEIGHT_PX - labelHeight
        val slot = WIDTH_PX.toFloat() / points.size
        val barWidth = slot * 0.62f
        val radius = barWidth / 2f

        if (series == Series.NET) {
            drawSigned(context, canvas, points, plotHeight, slot, barWidth, radius, accentColorRes)
        } else {
            drawStacked(context, canvas, points, series, plotHeight, slot, barWidth, radius, accentColorRes)
        }
        drawHourLabels(context, canvas, points, slot, labelHeight, accentColorRes)
        return bitmap
    }

    /** Une seule grandeur, mesurée depuis le bas du cadre. */
    private fun drawStacked(
        context: Context,
        canvas: Canvas,
        points: List<Point>,
        series: Series,
        plotHeight: Float,
        slot: Float,
        barWidth: Float,
        radius: Float,
        accentColorRes: Int
    ) {
        // La dernière heure est en cours, donc partielle : elle serait presque
        // toujours le minimum. On la dessine, mais on l'écarte du calcul du
        // pic et du creux, sinon l'intensité désignerait l'heure incomplète.
        val lastIndex = points.lastIndex
        val complete = if (points.size > 1) points.dropLast(1) else points

        // Une consommation nulle sur toute la plage ne doit pas diviser par zéro.
        val peak = (complete.maxOfOrNull { series.valueOf(it) } ?: 0).coerceAtLeast(1)
        val trough = complete.minOfOrNull { series.valueOf(it) } ?: 0
        // Série plate : mettre en avant un « pic » et un « creux » identiques
        // n'aurait aucun sens, on laisse toutes les barres neutres.
        val hasSpread = trough < peak

        // Les extrêmes sont marqués par l'intensité, pas par la teinte : une
        // heure de pointe n'est pas une alerte et une heure creuse n'est pas
        // une bonne nouvelle, ce sont des maxima.
        val bar = paint(context, accentColorRes, ALPHA_NORMAL)
        val peakBar = paint(context, accentColorRes, ALPHA_PEAK)
        val troughBar = paint(context, accentColorRes, ALPHA_TROUGH)

        points.forEachIndexed { index, point ->
            val centerX = slot * index + slot / 2f
            // Plancher visible : une heure creuse doit rester repérable.
            // Plafond : le pic ignore l'heure en cours, qui pourrait donc le
            // dépasser et déborder du cadre.
            val value = series.valueOf(point)
            val height = (value.toFloat() / peak * plotHeight).coerceIn(3f, plotHeight)
            canvas.drawRoundRect(
                centerX - barWidth / 2f,
                plotHeight - height,
                centerX + barWidth / 2f,
                plotHeight,
                radius,
                radius,
                when {
                    !hasSpread || index == lastIndex -> bar
                    value == peak -> peakBar
                    value == trough -> troughBar
                    else -> bar
                }
            )
        }
    }

    /**
     * Solde de part et d'autre d'une ligne zéro.
     *
     * Passer sous zéro, c'est avoir injecté plus qu'on n'a tiré : le vert y
     * porte donc le même sens que pour la tendance — une bonne nouvelle — et
     * non une catégorie. Au-dessus, la teinte du thème reste neutre.
     *
     * La ligne zéro est placée au prorata des extrêmes plutôt qu'au milieu :
     * une journée presque toujours consommatrice ne doit pas gaspiller la
     * moitié du cadre pour une injection marginale.
     */
    private fun drawSigned(
        context: Context,
        canvas: Canvas,
        points: List<Point>,
        plotHeight: Float,
        slot: Float,
        barWidth: Float,
        radius: Float,
        accentColorRes: Int
    ) {
        val maxDrawn = max(0, points.maxOfOrNull { it.netWh } ?: 0)
        val maxInjected = max(0, -(points.minOfOrNull { it.netWh } ?: 0))
        val span = (maxDrawn + maxInjected).coerceAtLeast(1)
        val zeroY = plotHeight * maxDrawn / span

        val drawnBar = paint(context, accentColorRes, ALPHA_NORMAL)
        val injectedBar = paint(context, R.color.widget_accent_production, ALPHA_PEAK)
        val zeroLine = paint(context, R.color.widget_text_secondary, 90).apply {
            strokeWidth = 2f
        }

        points.forEachIndexed { index, point ->
            val centerX = slot * index + slot / 2f
            val height =
                (abs(point.netWh).toFloat() / span * plotHeight).coerceAtLeast(2f)
            val injecting = point.netWh < 0
            val top = if (injecting) zeroY else zeroY - height
            canvas.drawRoundRect(
                centerX - barWidth / 2f,
                top,
                centerX + barWidth / 2f,
                top + height,
                radius,
                radius,
                if (injecting) injectedBar else drawnBar
            )
        }

        // Tracée après les barres : la référence doit rester lisible par-dessus.
        canvas.drawLine(0f, zeroY, WIDTH_PX.toFloat(), zeroY, zeroLine)
    }

    private fun drawHourLabels(
        context: Context,
        canvas: Canvas,
        points: List<Point>,
        slot: Float,
        labelHeight: Float,
        accentColorRes: Int
    ) {
        val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, R.color.widget_text_secondary)
            textSize = HEIGHT_PX * 0.19f
            textAlign = Paint.Align.CENTER
        }
        // L'heure en cours est le repère le plus utile d'une fenêtre glissante :
        // sans elle on lit « 10h · 16h · 22h » sans savoir où l'on se situe.
        val nowLabel = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, accentColorRes)
            textSize = HEIGHT_PX * 0.19f
            textAlign = Paint.Align.CENTER
            isFakeBoldText = true
        }

        val lastIndex = points.lastIndex
        points.forEachIndexed { index, point ->
            // Compté depuis la fin : l'heure en cours est ainsi toujours
            // étiquetée, et les repères restent régulièrement espacés.
            if ((lastIndex - index) % LABEL_EVERY != 0) return@forEachIndexed

            val isNow = index == lastIndex
            val paint = if (isNow) nowLabel else label
            val text = "%02dh".format(point.hour)
            // Le libellé des barres extrêmes déborderait du cadre : on le
            // ramène dedans plutôt que de le laisser rogner.
            val half = paint.measureText(text) / 2f
            canvas.drawText(
                text,
                (slot * index + slot / 2f).coerceIn(half, WIDTH_PX - half),
                HEIGHT_PX - labelHeight * 0.15f,
                paint
            )
        }
    }
}

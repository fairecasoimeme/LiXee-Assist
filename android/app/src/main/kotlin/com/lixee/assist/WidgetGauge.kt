package com.lixee.assist

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import androidx.core.content.ContextCompat
import kotlin.math.min

/**
 * Jauge en arc, dessinée au Canvas puis passée au widget en bitmap.
 *
 * RemoteViews n'accepte pas de vue personnalisée : un arc ne peut donc pas
 * être dessiné par le layout. Le rendu se fait ici, dans le processus du
 * lanceur, sans que Flutter ait besoin de tourner.
 */
object WidgetGauge {

    private const val SIZE_PX = 260
    private const val START_ANGLE = 135f
    private const val SWEEP_ANGLE = 270f

    /**
     * @param ratio position de l'aiguille entre 0 et 1, ou `null` si la
     *   puissance souscrite est inconnue — l'arc n'est alors pas rempli.
     * @param maxLabel borne haute affichée sous l'arc ; `null` la masque.
     * @param centerValue valeur inscrite au cœur de l'arc, avec [centerUnit].
     */
    fun render(
        context: Context,
        ratio: Float?,
        minLabel: String? = null,
        maxLabel: String? = null,
        centerValue: String? = null,
        centerUnit: String? = null
    ): Bitmap {
        val bitmap = Bitmap.createBitmap(SIZE_PX, SIZE_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        val stroke = SIZE_PX * 0.12f
        val inset = stroke / 2f + 2f
        // L'ouverture de l'arc est en bas : on y loge les bornes.
        val bottomGap = SIZE_PX * 0.14f
        val bounds = RectF(
            inset, inset, SIZE_PX - inset, SIZE_PX - inset - bottomGap
        )

        val track = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            strokeCap = Paint.Cap.ROUND
            color = ContextCompat.getColor(context, R.color.widget_gauge_track)
        }
        canvas.drawArc(bounds, START_ANGLE, SWEEP_ANGLE, false, track)

        if (ratio != null) {
            val clamped = min(1f, maxOf(0f, ratio))
            val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = stroke
                strokeCap = Paint.Cap.ROUND
                color = ContextCompat.getColor(context, colorFor(clamped))
            }
            // Un ratio nul ne doit pas dessiner un point isolé dû au cap rond.
            if (clamped > 0.002f) {
                canvas.drawArc(bounds, START_ANGLE, SWEEP_ANGLE * clamped, false, fill)
            }
        }

        drawCenter(context, canvas, bounds, centerValue, centerUnit)
        drawBounds(context, canvas, bounds, minLabel, maxLabel)
        return bitmap
    }

    /** Valeur au cœur de l'arc : c'est elle que l'œil cherche en premier. */
    private fun drawCenter(
        context: Context,
        canvas: Canvas,
        bounds: RectF,
        value: String?,
        unit: String?
    ) {
        if (value == null) return

        val valuePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, R.color.widget_accent)
            textSize = SIZE_PX * 0.235f
            textAlign = Paint.Align.CENTER
            isFakeBoldText = true
        }
        val unitPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, R.color.widget_text_secondary)
            textSize = SIZE_PX * 0.105f
            textAlign = Paint.Align.CENTER
        }

        // Centre optique : la valeur légèrement au-dessus, l'unité dessous.
        val cx = bounds.centerX()
        val cy = bounds.centerY()
        canvas.drawText(value, cx, cy + valuePaint.textSize * 0.22f, valuePaint)
        unit?.let {
            canvas.drawText(it, cx, cy + valuePaint.textSize * 0.95f, unitPaint)
        }
    }

    /**
     * Bornes de l'échelle, alignées sur les extrémités de l'arc — sans elles
     * la position de l'aiguille ne veut rien dire.
     */
    private fun drawBounds(
        context: Context,
        canvas: Canvas,
        bounds: RectF,
        minLabel: String?,
        maxLabel: String?
    ) {
        if (minLabel == null && maxLabel == null) return

        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, R.color.widget_text_secondary)
            textSize = SIZE_PX * 0.115f
        }
        val baseline = bounds.bottom + SIZE_PX * 0.13f

        minLabel?.let {
            paint.textAlign = Paint.Align.LEFT
            canvas.drawText(it, bounds.left, baseline, paint)
        }
        maxLabel?.let {
            paint.textAlign = Paint.Align.RIGHT
            canvas.drawText(it, bounds.right, baseline, paint)
        }
    }

    /** Vert tant qu'on est loin du contrat, orange puis rouge en approchant. */
    private fun colorFor(ratio: Float) = when {
        ratio < 0.6f -> R.color.widget_gauge_ok
        ratio < 0.85f -> R.color.widget_gauge_warn
        else -> R.color.widget_gauge_alert
    }
}

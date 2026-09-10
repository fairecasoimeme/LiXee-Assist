package com.lixee.assist

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import androidx.core.content.ContextCompat
import java.util.Locale
import kotlin.math.cos
import kotlin.math.sin

/**
 * Jauge de thermostat, calquée sur celle de la page de la box.
 *
 * L'arc court de 5 à 35 °C sur 270°, et se remplit **jusqu'à la consigne** —
 * pas jusqu'à la mesure. La mesure, elle, est marquée par un curseur : c'est
 * l'écart entre les deux qui dit ce que la régulation a encore à faire.
 *
 * Quatre teintes, comme la box : vive quand l'actionneur marche, pâle quand il
 * est au repos ; rouge en chauffage, bleu en refroidissement.
 */
object ThermostatGauge {

    private const val SIZE_PX = 260
    private const val START_ANGLE = 135f
    private const val SWEEP_ANGLE = 270f

    /** Bornes de l'échelle, celles de la box. */
    private const val MIN_C = 5f
    private const val MAX_C = 35f

    fun render(
        context: Context,
        setpoint: Float,
        temperature: Float?,
        heating: Boolean,
        active: Boolean
    ): Bitmap {
        val bitmap = Bitmap.createBitmap(SIZE_PX, SIZE_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        val stroke = SIZE_PX * 0.11f
        val inset = stroke / 2f + 3f
        val bounds = RectF(inset, inset, SIZE_PX - inset, SIZE_PX - inset)

        val track = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            strokeCap = Paint.Cap.ROUND
            color = ContextCompat.getColor(context, R.color.widget_gauge_track)
        }
        canvas.drawArc(bounds, START_ANGLE, SWEEP_ANGLE, false, track)

        val fill = Paint(track).apply {
            color = ContextCompat.getColor(context, colourFor(heating, active))
        }
        canvas.drawArc(
            bounds, START_ANGLE, SWEEP_ANGLE * ratio(setpoint), false, fill
        )

        if (temperature != null) {
            drawCursor(context, canvas, bounds, temperature, stroke)
        }
        drawCenter(context, canvas, temperature, heating, active)
        return bitmap
    }

    /**
     * Teintes de la box : vif quand ça régule, pâle sinon.
     *
     * C'est la seule information que la couleur porte à elle seule ici — le
     * widget la répète en toutes lettres à côté, pour qui ne distingue pas
     * un rouge d'un rose sur un fond d'écran chargé.
     */
    private fun colourFor(heating: Boolean, active: Boolean) = when {
        heating && active -> R.color.widget_thermo_heat_on
        heating -> R.color.widget_thermo_heat_off
        active -> R.color.widget_thermo_cool_on
        else -> R.color.widget_thermo_cool_off
    }

    private fun ratio(value: Float) =
        ((value.coerceIn(MIN_C, MAX_C) - MIN_C) / (MAX_C - MIN_C))

    /** Repère de la température mesurée, posé sur l'arc. */
    private fun drawCursor(
        context: Context,
        canvas: Canvas,
        bounds: RectF,
        temperature: Float,
        stroke: Float
    ) {
        val angle = Math.toRadians(
            (START_ANGLE + SWEEP_ANGLE * ratio(temperature)).toDouble()
        )
        val radius = bounds.width() / 2f
        val cx = bounds.centerX() + radius * cos(angle).toFloat()
        val cy = bounds.centerY() + radius * sin(angle).toFloat()

        // Un liseré du fond détache le repère de l'arc qu'il chevauche.
        canvas.drawCircle(cx, cy, stroke * 0.46f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, R.color.widget_background)
        })
        canvas.drawCircle(cx, cy, stroke * 0.30f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ContextCompat.getColor(context, R.color.widget_text_primary)
        })
    }

    private fun drawCenter(
        context: Context,
        canvas: Canvas,
        temperature: Float?,
        heating: Boolean,
        active: Boolean
    ) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textAlign = Paint.Align.CENTER
            isFakeBoldText = true
            textSize = SIZE_PX * 0.24f
            color = ContextCompat.getColor(
                context,
                if (temperature == null) R.color.widget_text_secondary
                else R.color.widget_text_primary
            )
        }
        val cx = SIZE_PX / 2f
        val text = temperature?.let { String.format(Locale.getDefault(), "%.1f", it) }
            ?: context.getString(R.string.widget_placeholder)
        canvas.drawText(text, cx, SIZE_PX / 2f + paint.textSize * 0.2f, paint)

        canvas.drawText(
            "°C",
            cx,
            SIZE_PX / 2f + paint.textSize * 0.95f,
            Paint(paint).apply {
                isFakeBoldText = false
                textSize = SIZE_PX * 0.11f
                color = ContextCompat.getColor(
                    context,
                    if (active) colourFor(heating, true)
                    else R.color.widget_text_secondary
                )
            }
        )
    }
}

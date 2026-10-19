package com.lixee.assist

import android.content.Context
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.service.dreams.DreamService
import android.text.format.DateFormat
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextClock
import android.widget.TextView
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONObject
import java.text.NumberFormat
import java.util.Locale
import kotlin.random.Random

/**
 * Écran de veille LiXee pour Android TV : l'heure, l'énergie d'une box et
 * ses thermostats, en grand, lisibles depuis le canapé.
 *
 * Il ne relève rien lui-même : il lit ce que l'app publie pour les widgets,
 * et demande un relevé à intervalles réguliers par le même chemin qu'eux
 * ([WidgetRefreshWorker]). Plusieurs box : elles défilent chacune à leur tour.
 *
 * Tout le contenu glisse de quelques pixels chaque minute, pour ne pas
 * marquer les dalles OLED à force d'afficher les mêmes chiffres au même
 * endroit.
 */
class LixeeDreamService : DreamService() {

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var content: LinearLayout
    private lateinit var energy: LinearLayout
    private lateinit var thermostats: LinearLayout

    /** Contexte en thème sombre : les rendus des widgets y prennent leurs teintes claires. */
    private lateinit var night: Context
    private var boxIndex = 0
    private var ticks = 0

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        isInteractive = false
        isFullscreen = true
        isScreenBright = false

        night = createConfigurationContext(
            Configuration(resources.configuration).apply {
                uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                    Configuration.UI_MODE_NIGHT_YES
            }
        )

        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(56), dp(40), dp(56), dp(40))
        }
        root.addView(content, FrameLayout.LayoutParams(MATCH, MATCH))

        content.addView(clock())
        energy = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        content.addView(energy, LinearLayout.LayoutParams(MATCH, 0, 1f).apply {
            topMargin = dp(24)
        })
        thermostats = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        content.addView(thermostats, LinearLayout.LayoutParams(MATCH, WRAP).apply {
            topMargin = dp(16)
        })
        setContentView(root)
    }

    override fun onDreamingStarted() {
        super.onDreamingStarted()
        requestRefresh()
        render()
        handler.postDelayed(tick, TICK_MS)
    }

    override fun onDreamingStopped() {
        handler.removeCallbacks(tick)
        super.onDreamingStopped()
    }

    /** Toutes les 10 s : relit les données ; toutes les minutes : relève et décale. */
    private val tick = object : Runnable {
        override fun run() {
            ticks++
            if (ticks % BOX_TICKS == 0) boxIndex++
            if (ticks % REFRESH_TICKS == 0) {
                requestRefresh()
                shiftContent()
            }
            render()
            handler.postDelayed(this, TICK_MS)
        }
    }

    private fun data(): SharedPreferences = HomeWidgetPlugin.getData(this)

    /** Box qui ont un relevé Linky, dans l'ordre de l'app. */
    private fun energyBoxes(): List<String> {
        val raw = data().getString(KEY_DEVICE_LIST, null) ?: return emptyList()
        return try {
            val names = JSONArray(raw)
            (0 until names.length()).map { names.getString(it) }
                .filter { data().getString("$it.power", null)?.isNotEmpty() == true }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun zones(): List<Pair<String, JSONObject>> {
        val raw = data().getString(KEY_THERMO_CATALOG, null) ?: return emptyList()
        return try {
            val list = JSONArray(raw)
            (0 until list.length()).mapNotNull { i ->
                val key = list.getJSONObject(i).optString("key")
                val payload = data().getString("$key.thermo", null) ?: return@mapNotNull null
                key to JSONObject(payload)
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun requestRefresh() {
        energyBoxes().getOrNull(boxIndex.mod(maxOf(1, energyBoxes().size)))?.let {
            WidgetRefreshWorker.enqueueQuiet(this, "lixee://refresh/${android.net.Uri.encode(it)}")
        }
        zones().map { it.first }.forEach {
            WidgetRefreshWorker.enqueueQuiet(this, "lixee://thermorefresh/${android.net.Uri.encode(it)}")
        }
    }

    private fun shiftContent() {
        content.translationX = Random.nextInt(-dp(18), dp(18)).toFloat()
        content.translationY = Random.nextInt(-dp(12), dp(12)).toFloat()
    }

    private fun render() {
        renderEnergy()
        renderThermostats()
    }

    private fun renderEnergy() {
        energy.removeAllViews()
        val boxes = energyBoxes()
        if (boxes.isEmpty()) {
            energy.addView(text(getString(R.string.dream_empty), 22f, MUTED))
            return
        }
        val box = boxes[boxIndex.mod(boxes.size)]
        val d = data()
        val power = d.getString("$box.power", null)?.toIntOrNull()
        val max = d.getString("$box.maxpower", null)?.toIntOrNull()
        val ts = d.getString("$box.ts", null)?.toLongOrNull()
        val stale = ts == null || System.currentTimeMillis() - ts > STALE_MS

        val gauge = WidgetGauge.render(
            night,
            ratio = if (power != null && max != null && max > 0) power.toFloat() / max else null,
            maxLabel = max?.let { number(it) },
            centerValue = power?.let { number(it) },
            centerUnit = "VA",
            stale = stale,
        )
        energy.addView(ImageView(this).apply { setImageBitmap(gauge) },
            LinearLayout.LayoutParams(dp(230), dp(230)))

        val figures = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(36), 0, dp(36), 0)
        }
        figures.addView(text(box, 26f, TEXT, bold = true))
        d.getString("$box.daily", null)?.toIntOrNull()?.let {
            figures.addView(text("${decimal(it / 1000.0, 2)} kWh", 46f, TEXT, bold = true))
        }
        d.getString("$box.cost", null)?.toDoubleOrNull()?.let {
            figures.addView(text("${decimal(it, 2)} € sur 24 h", 24f, MUTED))
        }
        d.getString("$box.prodpower", null)?.toIntOrNull()?.takeIf { it > 0 }?.let {
            figures.addView(text(getString(R.string.dream_injection, number(it)), 24f, SOLAR))
        }
        if (ts != null) {
            val time = DateFormat.getTimeFormat(this).format(java.util.Date(ts))
            figures.addView(text(getString(R.string.dream_reading_at, time), 18f, MUTED))
        }
        energy.addView(figures, LinearLayout.LayoutParams(WRAP, WRAP))

        val points = WidgetChart.parse(d.getString("$box.hourly", null))
        if (points.isNotEmpty()) {
            energy.addView(ImageView(this).apply {
                setImageBitmap(WidgetChart.render(night, points))
                scaleType = ImageView.ScaleType.FIT_CENTER
            }, LinearLayout.LayoutParams(0, dp(200), 1f))
        }
    }

    private fun renderThermostats() {
        thermostats.removeAllViews()
        for ((_, zone) in zones().take(3)) {
            val setpoint = zone.optDouble("setpoint").toFloat()
            val temp = if (zone.has("temp")) zone.optDouble("temp").toFloat() else null
            val heating = zone.optBoolean("heating", true)
            val active = zone.optBoolean("active")
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, 0, dp(40), 0)
            }
            card.addView(ImageView(this).apply {
                setImageBitmap(ThermostatGauge.render(night, setpoint, temp, heating, active))
            }, LinearLayout.LayoutParams(dp(110), dp(110)))
            val lines = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(14), 0, 0, 0)
            }
            lines.addView(text(zone.optString("name"), 22f, TEXT, bold = true))
            lines.addView(text(getString(R.string.dream_setpoint, decimal(setpoint.toDouble(), 1)), 18f, TEXT))
            val state = when {
                zone.optInt("force") == 2 -> getString(R.string.dream_thermo_off)
                active && heating -> getString(R.string.dream_thermo_heating)
                active -> getString(R.string.dream_thermo_cooling)
                else -> getString(R.string.dream_thermo_idle)
            }
            val measured = temp?.let { getString(R.string.dream_measured, decimal(it.toDouble(), 1)) }
            lines.addView(text(listOfNotNull(measured, state).joinToString(" · "), 16f, MUTED))
            card.addView(lines)
            thermostats.addView(card)
        }
    }

    private fun clock(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.BOTTOM
        }
        row.addView(TextClock(this).apply {
            format24Hour = "HH:mm"
            format12Hour = "h:mm"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 72f)
            setTextColor(TEXT)
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
        })
        row.addView(TextClock(this).apply {
            format24Hour = "EEEE d MMMM"
            format12Hour = "EEEE d MMMM"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            setTextColor(MUTED)
            setPadding(dp(20), 0, 0, dp(14))
        })
        return row
    }

    private fun text(value: String, sp: Float, color: Int, bold: Boolean = false) =
        TextView(this).apply {
            text = value
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
            setTextColor(color)
            if (bold) typeface = Typeface.DEFAULT_BOLD
            layoutParams = ViewGroup.LayoutParams(WRAP, WRAP)
        }

    private fun number(value: Int) = NumberFormat.getIntegerInstance(Locale.getDefault()).format(value)

    private fun decimal(value: Double, digits: Int) =
        NumberFormat.getNumberInstance(Locale.getDefault()).apply {
            minimumFractionDigits = digits
            maximumFractionDigits = digits
        }.format(value)

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val KEY_DEVICE_LIST = "widget_device_list"
        private const val KEY_THERMO_CATALOG = "widget_thermostat_catalog"

        private const val TICK_MS = 10_000L
        /** Relevé et décalage anti-marquage toutes les 6 × 10 s. */
        private const val REFRESH_TICKS = 6
        /** Box suivante toutes les 3 × 10 s. */
        private const val BOX_TICKS = 3
        private const val STALE_MS = 30 * 60_000L

        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        private val TEXT = Color.parseColor("#EEF3F8")
        private val MUTED = Color.parseColor("#93A3B5")
        private val SOLAR = Color.parseColor("#2EB872")
    }
}

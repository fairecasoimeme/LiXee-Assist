package com.lixee.assist

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import androidx.core.os.ConfigurationCompat
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONObject
import java.util.Locale

/**
 * Widget d'une zone du thermostat virtuel de la box.
 *
 * Le réglage de la consigne se fait **sans confirmation** : un demi-degré est
 * petit, visible et immédiatement réversible, et passer de 19 à 21 imposerait
 * sinon quatre dialogues. Les boutons qui changent le comportement de la
 * régulation — forçage, chaud/froid, hors-gel — en demandent une, eux.
 */
class ThermostatWidgetProvider : HomeWidgetProvider() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_THERMOSTAT) {
            acknowledge(context, intent)
            WidgetRefreshWorker.enqueue(context, intent.data?.toString())
            return
        }
        super.onReceive(context, intent)
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { id ->
            appWidgetManager.updateAppWidget(id, build(context, widgetData, id))
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        val editor = HomeWidgetPlugin.getData(context).edit()
        appWidgetIds.forEach { editor.remove(bindingKeyFor(it)) }
        editor.apply()
    }

    companion object {
        const val ACTION_THERMOSTAT = "com.lixee.assist.action.THERMOSTAT"

        fun bindingKeyFor(appWidgetId: Int) = "thermo_binding_$appWidgetId"

        private fun acknowledge(context: Context, intent: Intent) {
            val widgetId = intent.getIntExtra(
                AppWidgetManager.EXTRA_APPWIDGET_ID,
                AppWidgetManager.INVALID_APPWIDGET_ID
            )
            if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return

            val views = RemoteViews(context.packageName, R.layout.widget_thermostat)
            views.setTextViewText(
                R.id.thermo_footer, context.getString(R.string.widget_refreshing)
            )
            views.setTextColor(
                R.id.thermo_footer,
                ContextCompat.getColor(context, R.color.widget_accent)
            )
            AppWidgetManager.getInstance(context)
                .partiallyUpdateAppWidget(widgetId, views)
        }

        fun build(
            context: Context,
            widgetData: SharedPreferences,
            widgetId: Int
        ): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_thermostat)
            val key = widgetData.getString(bindingKeyFor(widgetId), null)

            if (key == null) {
                views.setTextViewText(
                    R.id.thermo_name, context.getString(R.string.widget_no_device)
                )
                views.setTextViewText(R.id.thermo_temp, "")
                views.setTextViewText(R.id.thermo_state, "")
                views.setTextViewText(R.id.thermo_setpoint, "")
                views.setTextViewText(
                    R.id.thermo_footer,
                    context.getString(R.string.widget_tap_to_configure)
                )
                views.setViewVisibility(R.id.thermo_row_modes, View.GONE)
                return views
            }

            val fallbackName = key.substringAfter('~')
            val payload = widgetData.getString("$key$SUFFIX", null)
            val timestamp = widgetData.getString("$key.ts", null)?.toLongOrNull()
            val failedAt = widgetData.getString("$key.failedat", null)?.toLongOrNull()
            val unreachable =
                failedAt != null && (timestamp == null || failedAt > timestamp)

            if (payload.isNullOrEmpty()) {
                views.setTextViewText(R.id.thermo_name, fallbackName)
                views.setTextViewText(R.id.thermo_temp, "")
                views.setTextViewText(R.id.thermo_state, "")
                views.setTextViewText(R.id.thermo_setpoint, "")
                views.setTextViewText(
                    R.id.thermo_footer, footer(context, null, unreachable)
                )
                views.setViewVisibility(R.id.thermo_row_modes, View.GONE)
                return views
            }

            val zone = JSONObject(payload)
            val locale = ConfigurationCompat
                .getLocales(context.resources.configuration).get(0)
                ?: Locale.getDefault()

            views.setTextViewText(
                R.id.thermo_name, zone.optString("name").ifEmpty { fallbackName }
            )

            // Sans sonde valide, la consigne ne régule rien : le dire vaut
            // mieux que de laisser croire à une mesure. La jauge affiche alors
            // un tiret en son centre, et cette ligne l'explique.
            views.setTextViewText(
                R.id.thermo_temp,
                if (zone.has("temp")) ""
                else context.getString(R.string.widget_thermo_no_sensor)
            )
            views.setImageViewBitmap(
                R.id.thermo_gauge,
                ThermostatGauge.render(
                    context,
                    setpoint = zone.optDouble("setpoint").toFloat(),
                    temperature =
                        if (zone.has("temp")) zone.optDouble("temp").toFloat() else null,
                    heating = zone.optBoolean("heating"),
                    active = zone.optBoolean("active")
                )
            )

            views.setTextViewText(
                R.id.thermo_setpoint,
                context.getString(
                    R.string.widget_thermo_setpoint,
                    String.format(locale, "%.1f", zone.optDouble("setpoint"))
                )
            )
            // La teinte de la consigne dit si l'actionneur marche en ce moment.
            views.setTextColor(
                R.id.thermo_setpoint,
                ContextCompat.getColor(
                    context,
                    if (zone.optBoolean("active")) R.color.widget_gauge_warn
                    else R.color.widget_accent
                )
            )

            views.setTextViewText(R.id.thermo_state, state(context, zone))
            views.setTextColor(
                R.id.thermo_state,
                ContextCompat.getColor(context, stateColour(zone))
            )

            attachClicks(context, views, key, zone, widgetId)
            markSelection(context, views, zone)

            views.setTextViewText(
                R.id.thermo_footer, footer(context, timestamp, unreachable)
            )
            views.setTextColor(
                R.id.thermo_footer,
                ContextCompat.getColor(
                    context,
                    if (unreachable) R.color.widget_gauge_warn
                    else R.color.widget_text_secondary
                )
            )
            return views
        }

        /**
         * Décrit l'état en toutes lettres : mode, forçage, hors-gel, et si
         * l'actionneur marche à cet instant.
         *
         * La page de la box porte la même information par la teinte de sa
         * carte. Sur un écran d'accueil, à côté d'autres widgets et sous un
         * fond d'écran quelconque, une couleur seule se lit mal.
         */
        private fun state(context: Context, zone: JSONObject): String {
            val parts = mutableListOf<String>()
            parts.add(
                context.getString(
                    if (zone.optBoolean("heating")) R.string.widget_thermo_heat
                    else R.string.widget_thermo_cool
                )
            )
            when (zone.optInt("force")) {
                1 -> parts.add(context.getString(R.string.widget_thermo_forced_on))
                2 -> parts.add(context.getString(R.string.widget_thermo_forced_off))
                else -> parts.add(context.getString(R.string.widget_thermo_auto))
            }
            if (zone.optBoolean("frost")) {
                parts.add(context.getString(R.string.widget_thermo_frost))
            }
            parts.add(
                context.getString(
                    if (zone.optBoolean("active")) R.string.widget_thermo_regulating
                    else R.string.widget_thermo_idle
                )
            )
            return parts.joinToString(context.getString(R.string.widget_thermo_separator))
        }

        /** Actif : la teinte du mode. Au repos : gris, comme la box. */
        private fun stateColour(zone: JSONObject): Int = when {
            !zone.optBoolean("active") -> R.color.widget_text_secondary
            zone.optBoolean("heating") -> R.color.widget_gauge_warn
            else -> R.color.widget_accent
        }

        /**
         * Colore le bouton correspondant à l'état courant.
         *
         * RemoteViews n'a pas de notion de sélection : on échange le fond par
         * `setBackgroundResource`, seule voie télécommandable pour cela.
         */
        private fun markSelection(
            context: Context,
            views: RemoteViews,
            zone: JSONObject
        ) {
            val force = zone.optInt("force")
            select(context, views, R.id.thermo_auto, force == 0,
                R.drawable.widget_action_button_on)
            select(context, views, R.id.thermo_on, force == 1,
                R.drawable.widget_action_button_on)
            select(context, views, R.id.thermo_off, force == 2,
                R.drawable.widget_action_button_on)

            val heating = zone.optBoolean("heating")
            select(context, views, R.id.thermo_heat, heating,
                R.drawable.widget_action_button_heat)
            select(context, views, R.id.thermo_cool, !heating,
                R.drawable.widget_action_button_cool)
            select(context, views, R.id.thermo_frost, zone.optBoolean("frost"),
                R.drawable.widget_action_button_frost)
        }

        private fun select(
            context: Context,
            views: RemoteViews,
            viewId: Int,
            selected: Boolean,
            selectedBackground: Int
        ) {
            views.setInt(
                viewId,
                "setBackgroundResource",
                if (selected) selectedBackground else R.drawable.widget_action_button
            )
            views.setTextColor(
                viewId,
                ContextCompat.getColor(
                    context,
                    if (selected) R.color.widget_on_accent
                    else R.color.widget_text_primary
                )
            )
        }

        private fun attachClicks(
            context: Context,
            views: RemoteViews,
            key: String,
            zone: JSONObject,
            widgetId: Int
        ) {
            // Le pas ne demande pas confirmation : voir la note de classe.
            views.setOnClickPendingIntent(
                R.id.thermo_minus, direct(context, key, "d=-0.5", widgetId, 1)
            )
            views.setOnClickPendingIntent(
                R.id.thermo_plus, direct(context, key, "d=0.5", widgetId, 2)
            )

            val name = zone.optString("name")
            views.setOnClickPendingIntent(
                R.id.thermo_auto,
                confirmed(context, key, "f=0", name,
                    context.getString(R.string.widget_thermo_auto), widgetId, 3)
            )
            views.setOnClickPendingIntent(
                R.id.thermo_on,
                confirmed(context, key, "f=1", name,
                    context.getString(R.string.widget_thermo_on), widgetId, 4)
            )
            views.setOnClickPendingIntent(
                R.id.thermo_off,
                confirmed(context, key, "f=2", name,
                    context.getString(R.string.widget_thermo_off), widgetId, 5)
            )

            // Chaud/froid n'a de sens que sur une zone réversible ; le hors-gel
            // que sur une zone qui chauffe. La box masque les mêmes.
            val reversible = zone.optBoolean("reversible")
            val heating = zone.optBoolean("heating")
            views.setViewVisibility(
                R.id.thermo_heat, if (reversible) View.VISIBLE else View.GONE
            )
            views.setViewVisibility(
                R.id.thermo_cool, if (reversible) View.VISIBLE else View.GONE
            )
            views.setViewVisibility(
                R.id.thermo_frost, if (heating) View.VISIBLE else View.INVISIBLE
            )
            views.setViewVisibility(
                R.id.thermo_row_modes,
                if (reversible || heating) View.VISIBLE else View.GONE
            )

            if (reversible) {
                views.setOnClickPendingIntent(
                    R.id.thermo_heat,
                    confirmed(context, key, "h=1", name,
                        context.getString(R.string.widget_thermo_heat), widgetId, 6)
                )
                views.setOnClickPendingIntent(
                    R.id.thermo_cool,
                    confirmed(context, key, "h=0", name,
                        context.getString(R.string.widget_thermo_cool), widgetId, 7)
                )
            }
            if (heating) {
                views.setOnClickPendingIntent(
                    R.id.thermo_frost,
                    confirmed(context, key, "g=1", name,
                        context.getString(R.string.widget_thermo_frost), widgetId, 8)
                )
            }
        }

        private fun target(key: String, query: String) =
            Uri.parse("lixee://thermo/${Uri.encode(key)}?$query")

        /** Appui qui agit tout de suite, sans dialogue. */
        private fun direct(
            context: Context,
            key: String,
            query: String,
            widgetId: Int,
            slot: Int
        ): PendingIntent {
            val intent = Intent(ACTION_THERMOSTAT)
                .setClassName(context.packageName, ThermostatWidgetProvider::class.java.name)
                .setData(target(key, query))
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            return PendingIntent.getBroadcast(
                context, widgetId * 16 + slot, intent, flags()
            )
        }

        /** Appui qui passe par une confirmation. */
        private fun confirmed(
            context: Context,
            key: String,
            query: String,
            zoneName: String,
            label: String,
            widgetId: Int,
            slot: Int
        ): PendingIntent {
            val intent = Intent(context, WidgetActionConfirmActivity::class.java)
                .setData(target(key, query))
                .putExtra(WidgetActionConfirmActivity.EXTRA_LABEL, zoneName)
                .putExtra(WidgetActionConfirmActivity.EXTRA_ACTION, label)
                .putExtra(
                    WidgetActionConfirmActivity.EXTRA_RECEIVER,
                    ThermostatWidgetProvider::class.java.name
                )
                .putExtra(
                    WidgetActionConfirmActivity.EXTRA_BROADCAST_ACTION,
                    ACTION_THERMOSTAT
                )
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            return PendingIntent.getActivity(
                context, widgetId * 16 + slot, intent, flags()
            )
        }

        private fun flags(): Int {
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= 23) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            return flags
        }

        private fun footer(
            context: Context,
            timestamp: Long?,
            unreachable: Boolean
        ): String {
            if (timestamp == null) {
                return context.getString(
                    if (unreachable) R.string.widget_unreachable_never
                    else R.string.widget_never_updated
                )
            }
            val minutes = (System.currentTimeMillis() - timestamp) / 60_000L
            val age = when {
                minutes < 1L -> context.getString(R.string.widget_age_now)
                minutes < 60L -> context.resources.getQuantityString(
                    R.plurals.widget_age_minutes, minutes.toInt(), minutes.toInt()
                )
                else -> {
                    val hours = (minutes / 60L).toInt()
                    context.resources.getQuantityString(
                        R.plurals.widget_age_hours, hours, hours
                    )
                }
            }
            return if (unreachable) {
                context.getString(R.string.widget_unreachable, age)
            } else {
                age
            }
        }

        private const val SUFFIX = ".thermo"
    }
}

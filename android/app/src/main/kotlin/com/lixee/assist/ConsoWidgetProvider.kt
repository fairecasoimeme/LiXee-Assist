package com.lixee.assist

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import androidx.core.os.ConfigurationCompat
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import java.util.Locale

/**
 * Widget d'écran d'accueil affichant le dernier relevé d'une box.
 *
 * Il ne fait aucun accès réseau : WidgetDataService (côté Dart) écrit un
 * instantané horodaté par box, ce provider se contente de l'afficher. Il
 * s'exécute dans le processus du lanceur, où le moteur Flutter ne tourne pas.
 *
 * Chaque instance est liée à une box par [WidgetConfigActivity] : plusieurs
 * widgets peuvent coexister, un par box.
 */
class ConsoWidgetProvider : HomeWidgetProvider() {

    companion object {
        /**
         * Au-delà, le relevé est signalé comme vieillissant : le worker tourne
         * toutes les 15 minutes, une heure sans nouvelle donnée veut dire que
         * quatre cycles ont échoué.
         */
        private const val AGING_MS = 60 * 60 * 1000L

        /**
         * Au-delà, la valeur cesse d'être présentée comme une mesure en cours.
         * Un chiffre faux qui a l'air frais est pire qu'un chiffre absent.
         */
        private const val STALE_MS = 6 * 60 * 60 * 1000L

        /**
         * Exposé pour que l'écran de configuration dessine immédiatement le
         * widget qu'il vient de lier, sans attendre le prochain relevé.
         */
        fun render(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetIds: IntArray,
            widgetData: SharedPreferences
        ) {
            appWidgetIds.forEach { widgetId ->
                val device = widgetData.getString(
                    WidgetConfigActivity.deviceKeyFor(widgetId), null
                )
                appWidgetManager.updateAppWidget(
                    widgetId,
                    buildViews(context, widgetData, device)
                )
            }
        }

        private fun buildViews(
            context: Context,
            widgetData: SharedPreferences,
            device: String?
        ): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_conso)
            attachClicks(context, views, device)

            if (device == null) {
                // Instance jamais configurée : ne rien inventer.
                views.setTextViewText(
                    R.id.widget_device, context.getString(R.string.widget_no_device)
                )
                views.setTextViewText(
                    R.id.widget_footer, context.getString(R.string.widget_tap_to_configure)
                )
                views.setTextViewText(R.id.widget_daily, "")
                views.setTextViewText(R.id.widget_cost, "")
                views.setTextViewText(R.id.widget_trend, "")
                views.setImageViewBitmap(R.id.widget_gauge, WidgetGauge.render(context, null))
                views.setImageViewBitmap(
                    R.id.widget_chart, WidgetChart.render(context, emptyList())
                )
                return views
            }

            val power = widgetData.getString("$device.power", null)?.toIntOrNull()
            val maxPower = widgetData.getString("$device.maxpower", null)?.toIntOrNull()
            val source = widgetData.getString("$device.source", null)
            val timestamp = widgetData.getString("$device.ts", null)?.toLongOrNull()

            views.setTextViewText(R.id.widget_device, device)
            views.setTextViewText(R.id.widget_footer, footer(context, timestamp, source))
            // Un relevé qui vieillit doit se signaler : sans ça, une box
            // injoignable laisse des chiffres périmés d'apparence normale.
            views.setTextColor(
                R.id.widget_footer,
                ContextCompat.getColor(
                    context,
                    if (age(timestamp) > AGING_MS) R.color.widget_gauge_warn
                    else R.color.widget_text_secondary
                )
            )

            // Sans puissance souscrite, l'arc reste vide plutôt que d'inventer
            // une échelle : mieux vaut ne rien montrer qu'induire en erreur.
            val scaled = maxPower != null && maxPower > 0
            val ratio = if (power != null && scaled) {
                power.toFloat() / maxPower!!.toFloat()
            } else {
                null
            }
            views.setImageViewBitmap(
                R.id.widget_gauge,
                WidgetGauge.render(
                    context,
                    ratio,
                    minLabel = if (scaled) "0" else null,
                    // En kVA : « 10,4 kVA » tient là où « 10 350 » déborderait.
                    maxLabel = if (scaled) {
                        context.getString(
                            R.string.widget_unit_max,
                            format(context, maxPower!! / 1000.0, 1)
                        )
                    } else {
                        null
                    },
                    centerValue = power?.let { format(context, it.toDouble(), 0) }
                        ?: context.getString(R.string.widget_placeholder),
                    centerUnit = context.getString(R.string.widget_unit_power),
                    stale = age(timestamp) > STALE_MS
                )
            )

            val daily = widgetData.getString("$device.daily", null)?.toIntOrNull()
            val cost = widgetData.getString("$device.cost", null)?.toDoubleOrNull()
            views.setTextViewText(
                R.id.widget_daily,
                daily?.let {
                    context.getString(
                        R.string.widget_unit_energy, format(context, it / 1000.0, 2)
                    )
                } ?: context.getString(R.string.widget_placeholder)
            )
            // Le coût n'est publié que si un tarif est paramétré sur la box.
            views.setTextViewText(
                R.id.widget_cost,
                cost?.let {
                    context.getString(R.string.widget_unit_cost, format(context, it, 2))
                }.orEmpty()
            )
            renderTrend(context, views, widgetData.getString("$device.trend", null))
            views.setImageViewBitmap(
                R.id.widget_chart,
                WidgetChart.render(
                    context, WidgetChart.parse(widgetData.getString("$device.hourly", null))
                )
            )
            return views
        }

        /**
         * Appui sur la jauge : relevé immédiat, sans ouvrir l'app. Ailleurs :
         * ouverture de l'app. C'est le seul rafraîchissement qui échappe aux
         * limites de fréquence d'Android, puisque l'utilisateur le demande.
         *
         * Le plugin fixe le code de requête à 0 pour tous les PendingIntent.
         * Ce n'est pas une collision : deux PendingIntent ne sont confondus que
         * si leurs intents sont `filterEquals`, ce qui compare l'URI — d'où une
         * URI distincte par box.
         */
        private fun attachClicks(context: Context, views: RemoteViews, device: String?) {
            val suffix = device ?: "unconfigured"
            views.setOnClickPendingIntent(
                R.id.widget_gauge,
                HomeWidgetBackgroundIntent.getBroadcast(
                    context, Uri.parse("lixee://refresh/$suffix")
                )
            )
            views.setOnClickPendingIntent(
                R.id.widget_root,
                HomeWidgetLaunchIntent.getActivity(
                    context, MainActivity::class.java, Uri.parse("lixee://open/$suffix")
                )
            )
        }

        /**
         * Évolution entre les deux dernières heures complètes.
         *
         * Le vert marque une baisse : sur une facture d'électricité, consommer
         * moins est la bonne nouvelle — l'inverse des conventions boursières.
         */
        private fun renderTrend(context: Context, views: RemoteViews, raw: String?) {
            val pct = raw?.toIntOrNull()
            if (pct == null) {
                views.setTextViewText(R.id.widget_trend, "")
                return
            }

            val (text, color) = when {
                pct > 2 -> context.getString(R.string.widget_trend_up, pct) to
                    R.color.widget_negative
                pct < -2 -> context.getString(R.string.widget_trend_down, -pct) to
                    R.color.widget_positive
                // Sous 2 %, l'écart relève du bruit de mesure.
                else -> context.getString(R.string.widget_trend_flat) to
                    R.color.widget_text_secondary
            }
            views.setTextViewText(R.id.widget_trend, text)
            views.setTextColor(R.id.widget_trend, ContextCompat.getColor(context, color))
        }

        /**
         * Formate selon la locale de l'appareil : les valeurs arrivent de Dart
         * avec un séparateur décimal invariant, qu'il ne faut pas afficher tel
         * quel à un utilisateur francophone.
         */
        private fun format(context: Context, value: Double, decimals: Int): String {
            val locale = ConfigurationCompat.getLocales(context.resources.configuration)[0]
                ?: Locale.getDefault()
            return String.format(locale, "%,.${decimals}f", value)
        }

        /** Âge du relevé. `Long.MAX_VALUE` quand il n'y en a jamais eu. */
        private fun age(timestamp: Long?): Long =
            if (timestamp == null) Long.MAX_VALUE
            else System.currentTimeMillis() - timestamp

        /**
         * Le lanceur redessine le widget sans que Dart tourne : l'âge doit être
         * recalculé ici, sinon il resterait figé à sa valeur d'écriture.
         */
        private fun footer(context: Context, timestamp: Long?, source: String?): String {
            if (timestamp == null) return context.getString(R.string.widget_never_updated)

            val elapsed = age(timestamp)
            val minutes = elapsed / 60_000L
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

            val via = when (source) {
                "local" -> context.getString(R.string.widget_source_local)
                "remote" -> context.getString(R.string.widget_source_remote)
                else -> null
            }
            return if (via == null) age else "$age · $via"
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        render(context, appWidgetManager, appWidgetIds, widgetData)
    }

    /** Le widget retiré, son choix de box n'a plus lieu d'être conservé. */
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        val editor = HomeWidgetPluginData.edit(context)
        appWidgetIds.forEach { editor.remove(WidgetConfigActivity.deviceKeyFor(it)) }
        editor.apply()
    }
}

/** Petit accès nommé aux préférences du plugin, pour la lisibilité. */
private object HomeWidgetPluginData {
    fun edit(context: Context): SharedPreferences.Editor =
        es.antonborri.home_widget.HomeWidgetPlugin.getData(context).edit()
}

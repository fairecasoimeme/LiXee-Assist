package com.lixee.assist

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import androidx.core.os.ConfigurationCompat
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import java.util.Locale

/**
 * Widget d'écran d'accueil affichant le dernier relevé d'une box.
 *
 * Il ne fait aucun accès réseau : WidgetDataService (côté Dart) écrit un
 * instantané horodaté par box, ce provider se contente de l'afficher. Il
 * s'exécute dans le processus du lanceur, où le moteur Flutter ne tourne pas.
 *
 * Chaque instance est liée à une box par [WidgetConfigActivity], et à un thème
 * par la sous-classe qui la déclare — d'où plusieurs entrées dans le sélecteur
 * de widgets pour un seul rendu.
 */
abstract class LixeeWidgetProvider(private val theme: WidgetTheme) :
    HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        render(context, appWidgetManager, appWidgetIds, widgetData, theme)
    }

    /** Le widget retiré, son choix de box n'a plus lieu d'être conservé. */
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        val editor = HomeWidgetPlugin.getData(context).edit()
        appWidgetIds.forEach { editor.remove(WidgetConfigActivity.deviceKeyFor(it)) }
        editor.apply()
    }

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
            widgetData: SharedPreferences,
            theme: WidgetTheme
        ) {
            appWidgetIds.forEach { widgetId ->
                val device = widgetData.getString(
                    WidgetConfigActivity.deviceKeyFor(widgetId), null
                )
                appWidgetManager.updateAppWidget(
                    widgetId,
                    buildViews(context, widgetData, device, theme)
                )
            }
        }

        private fun buildViews(
            context: Context,
            widgetData: SharedPreferences,
            device: String?,
            theme: WidgetTheme
        ): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_conso)
            attachClicks(context, views, device)
            views.setTextViewText(R.id.widget_gauge_label,
                context.getString(theme.gaugeLabelRes))
            views.setTextViewText(R.id.widget_column_label,
                context.getString(theme.columnLabelRes))
            // Un solde n'a pas d'échelle de zéro à la puissance souscrite :
            // masquer la jauge vaut mieux qu'en dessiner une qui ment.
            val gaugeVisibility = if (theme.hasGauge) View.VISIBLE else View.GONE
            views.setViewVisibility(R.id.widget_gauge_column, gaugeVisibility)

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

            val timestamp = widgetData.getString("$device.ts", null)?.toLongOrNull()
            views.setTextViewText(R.id.widget_device, device)
            views.setTextViewText(R.id.widget_footer, footer(context, timestamp))
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

            if (theme.hasGauge) {
                renderGauge(context, views, widgetData, device, theme, timestamp)
            }
            renderFigures(context, views, widgetData, device, theme)
            renderTrend(context, views, widgetData.getString("$device.trend", null))
            views.setImageViewBitmap(
                R.id.widget_chart,
                WidgetChart.render(
                    context,
                    WidgetChart.parse(widgetData.getString("$device.hourly", null)),
                    theme.chartSeries
                )
            )
            return views
        }

        private fun renderGauge(
            context: Context,
            views: RemoteViews,
            widgetData: SharedPreferences,
            device: String,
            theme: WidgetTheme,
            timestamp: Long?
        ) {
            val power = widgetData.getString("$device${theme.powerKey}", null)?.toIntOrNull()
            val maxPower = widgetData.getString("$device.maxpower", null)?.toIntOrNull()

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
                    // En kVA : « 9,0 kVA » tient là où « 9 000 » déborderait.
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
        }

        private fun renderFigures(
            context: Context,
            views: RemoteViews,
            widgetData: SharedPreferences,
            device: String,
            theme: WidgetTheme
        ) {
            val daily = widgetData.getString("$device${theme.dailyKey}", null)?.toIntOrNull()
            val amount = widgetData.getString("$device${theme.amountKey}", null)?.toDoubleOrNull()

            views.setTextViewText(
                R.id.widget_daily,
                daily?.let {
                    context.getString(
                        R.string.widget_unit_energy, format(context, it / 1000.0, 2)
                    )
                } ?: context.getString(R.string.widget_placeholder)
            )
            // Le montant n'est publié que si un tarif est paramétré sur la box.
            views.setTextViewText(
                R.id.widget_cost,
                amount?.let {
                    context.getString(R.string.widget_unit_cost, format(context, it, 2))
                }.orEmpty()
            )
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
        private fun footer(context: Context, timestamp: Long?): String {
            if (timestamp == null) return context.getString(R.string.widget_never_updated)

            // La voie employée — tunnel ou LAN — n'est plus affichée : c'est
            // une information de diagnostic, sans intérêt pour qui regarde son
            // écran d'accueil, et elle pesait autant que la fraîcheur.
            val minutes = age(timestamp) / 60_000L
            return when {
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
        }
    }
}

/** Consommation soutirée : le thème d'origine. */
class ConsoWidgetProvider : LixeeWidgetProvider(WidgetTheme.CONSUMPTION)

/** Injection sur le réseau. Ne montre rien sans compteur de production. */
class ProductionWidgetProvider : LixeeWidgetProvider(WidgetTheme.PRODUCTION)

/** Solde entre soutirage et injection, et facture nette. */
class BalanceWidgetProvider : LixeeWidgetProvider(WidgetTheme.BALANCE)

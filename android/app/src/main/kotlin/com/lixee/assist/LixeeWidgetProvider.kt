package com.lixee.assist

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import androidx.core.os.ConfigurationCompat
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

    /**
     * Le rafraîchissement d'arrière-plan met plusieurs secondes et ne change
     * parfois rien de visible : sans accusé de réception, l'appui semble
     * n'avoir aucun effet. On passe donc d'abord ici pour marquer le pied de
     * page, avant de relayer vers le travail qui fera le relevé.
     */
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_REFRESH) {
            acknowledgeTap(context, intent, theme)
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

        /** Appui sur la jauge, reçu par nos propres providers. */
        const val ACTION_REFRESH = "com.lixee.assist.action.REFRESH_WIDGET"

        /**
         * Marque le pied de page comme « mise à jour… », sans toucher au reste.
         *
         * `partiallyUpdateAppWidget` applique les seules opérations demandées
         * par-dessus l'affichage existant : la jauge et le graphe ne sont pas
         * redessinés, et rien n'a besoin d'être relu.
         *
         * L'état se résorbe seul : le relevé se termine par une mise à jour
         * complète, qu'il ait abouti ou échoué.
         */
        private fun acknowledgeTap(context: Context, intent: Intent, theme: WidgetTheme) {
            val widgetId = intent.getIntExtra(
                AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID
            )
            if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return

            val views = RemoteViews(context.packageName, R.layout.widget_conso)
            views.setTextViewText(
                R.id.widget_footer, context.getString(R.string.widget_refreshing)
            )
            views.setTextColor(
                R.id.widget_footer,
                ContextCompat.getColor(context, theme.accentColorRes)
            )
            AppWidgetManager.getInstance(context)
                .partiallyUpdateAppWidget(widgetId, views)
        }

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
                    buildViews(context, widgetData, device, theme, widgetId)
                )
            }
        }

        private fun buildViews(
            context: Context,
            widgetData: SharedPreferences,
            device: String?,
            theme: WidgetTheme,
            widgetId: Int
        ): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_conso)
            attachClicks(context, views, device, theme, widgetId)
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
            val failedAt = widgetData.getString("$device.failedat", null)?.toLongOrNull()
            // La box a cesse de repondre depuis le dernier relevé abouti.
            val unreachable = failedAt != null && (timestamp == null || failedAt > timestamp)

            views.setTextViewText(R.id.widget_device, device)
            views.setTextViewText(
                R.id.widget_footer, footer(context, timestamp, unreachable)
            )
            // Un relevé qui vieillit doit se signaler : sans ça, une box
            // injoignable laisse des chiffres périmés d'apparence normale.
            views.setTextColor(
                R.id.widget_footer,
                ContextCompat.getColor(
                    context,
                    if (unreachable || age(timestamp) > AGING_MS) R.color.widget_gauge_warn
                    else R.color.widget_text_secondary
                )
            )

            if (theme.hasGauge) {
                renderGauge(context, views, widgetData, device, theme, timestamp)
            }
            renderFigures(context, views, widgetData, device, theme)
            renderTrend(context, views, widgetData.getString("$device.trend", null), theme)
            views.setImageViewBitmap(
                R.id.widget_chart,
                WidgetChart.render(
                    context,
                    WidgetChart.parse(widgetData.getString("$device.hourly", null)),
                    theme.chartSeries,
                    theme.accentColorRes
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
                    stale = age(timestamp) > STALE_MS,
                    accentColorRes = theme.accentColorRes
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
        private fun attachClicks(
            context: Context,
            views: RemoteViews,
            device: String?,
            theme: WidgetTheme,
            widgetId: Int
        ) {
            // Encodé : un nom de box est libre et peut contenir espaces ou
            // accents, qui casseraient l'URI — et donc la distinction entre
            // les PendingIntent de deux widgets.
            val suffix = Uri.encode(device ?: "unconfigured")
            // Vers notre propre receveur, pas directement vers celui du
            // plugin : il faut accuser réception avant de relayer.
            views.setOnClickPendingIntent(
                R.id.widget_gauge,
                refreshIntent(context, Uri.parse("lixee://refresh/$suffix"), theme, widgetId)
            )
            // Vers l'écran de confirmation, pas vers l'app : refuser doit
            // laisser l'utilisateur sur son bureau, sans rien avoir lancé.
            views.setOnClickPendingIntent(
                R.id.widget_root,
                confirmIntent(context, Uri.parse("lixee://open/$suffix"))
            )
        }

        /**
         * L'URI distingue les widgets entre eux : deux PendingIntent ne sont
         * confondus que si leurs intents sont `filterEquals`, ce qui la compare.
         */
        /**
         * Vise le provider du theme par son nom : un Intent explicite evite de
         * dependre d'un filtre, et l'URI distincte par box garde les
         * PendingIntent separes.
         */
        private fun refreshIntent(
            context: Context,
            target: Uri,
            theme: WidgetTheme,
            widgetId: Int
        ): PendingIntent {
            val intent = Intent(ACTION_REFRESH)
                .setClassName(context.packageName, theme.providerClassName)
                .setData(target)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= 23) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            return PendingIntent.getBroadcast(context, widgetId, intent, flags)
        }

        private fun confirmIntent(context: Context, target: Uri): PendingIntent {
            val intent = Intent(context, WidgetLaunchConfirmActivity::class.java)
                .setData(target)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= 23) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            return PendingIntent.getActivity(context, 0, intent, flags)
        }

        /**
         * Évolution entre les deux dernières heures complètes.
         *
         * Le vert marque une baisse : sur une facture d'électricité, consommer
         * moins est la bonne nouvelle — l'inverse des conventions boursières.
         */
        private fun renderTrend(
            context: Context,
            views: RemoteViews,
            raw: String?,
            theme: WidgetTheme
        ) {
            val pct = raw?.toIntOrNull()
            if (pct == null) {
                views.setTextViewText(R.id.widget_trend, "")
                return
            }

            // Consommer plus coute, produire plus rapporte : la meme hausse
            // est une mauvaise nouvelle dans un cas et une bonne dans l'autre.
            val goodNews = R.color.widget_positive
            val badNews = R.color.widget_negative
            val rising = if (theme.risingIsGood) goodNews else badNews
            val falling = if (theme.risingIsGood) badNews else goodNews

            val (text, color) = when {
                pct > 2 -> context.getString(R.string.widget_trend_up, pct) to rising
                pct < -2 -> context.getString(R.string.widget_trend_down, -pct) to falling
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

            // La voie employée — tunnel ou LAN — n'est plus affichée : c'est
            // une information de diagnostic, sans intérêt pour qui regarde son
            // écran d'accueil, et elle pesait autant que la fraîcheur.
            val minutes = age(timestamp) / 60_000L
            val ageText = when {
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
            // Dire les deux : l'utilisateur veut savoir que sa demande a bien
            // ete prise en compte, et de quand datent les chiffres affiches.
            return if (unreachable) {
                context.getString(R.string.widget_unreachable, ageText)
            } else {
                ageText
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

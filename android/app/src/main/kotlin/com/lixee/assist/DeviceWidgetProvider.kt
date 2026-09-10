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
 * Widget d'un appareil Zigbee appairé : ses valeurs et ses boutons.
 *
 * Ne connaît aucun type de matériel. Le côté Dart publie un objet décrivant ce
 * qu'il faut montrer — libellés, unités, boutons — d'après le gabarit que la
 * box tient pour cet appareil. Un modèle inconnu de l'app s'affiche donc
 * correctement dès que la box le connaît, sans mise à jour de l'app.
 *
 * RemoteViews ne sait pas créer de vues à la volée : la mise en page prévoit
 * trois boutons et masque ceux qui ne servent pas.
 */
class DeviceWidgetProvider : HomeWidgetProvider() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_DEVICE_REFRESH, ACTION_DEVICE_COMMAND -> {
                acknowledge(context, intent)
                WidgetRefreshWorker.enqueue(context, intent.data?.toString())
                return
            }
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
        /** Appui sur le corps du widget : relève, sans rien commander. */
        const val ACTION_DEVICE_REFRESH = "com.lixee.assist.action.DEVICE_REFRESH"

        /** Appui confirmé sur un bouton d'action. */
        const val ACTION_DEVICE_COMMAND = "com.lixee.assist.action.DEVICE_COMMAND"

        private const val AGING_MS = 60 * 60 * 1000L
        /** Quatre rangées de trois : le gabarit le plus fourni propose onze
         *  actions, et RemoteViews impose de toutes les prévoir d'avance. */
        private const val BUTTON_COLUMNS = 3
        private const val MAX_BUTTONS = 12

        /** Clé du choix d'appareil, propre à une instance de widget. */
        fun bindingKeyFor(appWidgetId: Int) = "device_binding_$appWidgetId"

        /**
         * Marque le pied de page pendant que le relevé court.
         *
         * La box répond avant que l'appareil ait bougé, et un volet met une
         * vingtaine de secondes à arriver : sans ce retour, l'appui semble
         * n'avoir aucun effet et l'utilisateur appuie une seconde fois.
         */
        private fun acknowledge(context: Context, intent: Intent) {
            val widgetId = intent.getIntExtra(
                AppWidgetManager.EXTRA_APPWIDGET_ID,
                AppWidgetManager.INVALID_APPWIDGET_ID
            )
            if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return

            val views = RemoteViews(context.packageName, R.layout.widget_device)
            views.setTextViewText(
                R.id.device_footer, context.getString(R.string.widget_refreshing)
            )
            views.setTextColor(
                R.id.device_footer,
                ContextCompat.getColor(context, R.color.widget_accent)
            )
            AppWidgetManager.getInstance(context)
                .partiallyUpdateAppWidget(widgetId, views)
        }

        /**
         * Exposé pour que l'écran de configuration dessine immédiatement le
         * widget qu'il vient de lier, sans attendre le prochain relevé.
         */
        fun build(
            context: Context,
            widgetData: SharedPreferences,
            widgetId: Int
        ): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_device)
            val key = widgetData.getString(bindingKeyFor(widgetId), null)

            if (key == null) {
                views.setTextViewText(
                    R.id.device_label, context.getString(R.string.widget_no_device)
                )
                views.setTextViewText(R.id.device_primary_label, "")
                views.setTextViewText(R.id.device_primary, "")
                views.setTextViewText(R.id.device_secondary, "")
                views.setTextViewText(
                    R.id.device_footer,
                    context.getString(R.string.widget_tap_to_configure)
                )
                hideButtonsFrom(views, 0)
                return views
            }

            views.setOnClickPendingIntent(
                R.id.device_root,
                refreshIntent(context, key, widgetId)
            )

            val timestamp = widgetData.getString("$key.ts", null)?.toLongOrNull()
            val failedAt =
                widgetData.getString("$key.failedat", null)?.toLongOrNull()
            val unreachable =
                failedAt != null && (timestamp == null || failedAt > timestamp)

            val payload = widgetData.getString("$key.device", null)
            if (payload.isNullOrEmpty()) {
                // Lié mais jamais relevé : ne rien inventer, et surtout ne pas
                // proposer de boutons dont on ignore encore les intitulés.
                views.setTextViewText(R.id.device_label, key.substringAfter('/'))
                views.setTextViewText(R.id.device_primary_label, "")
                views.setTextViewText(R.id.device_primary, "")
                views.setTextViewText(R.id.device_secondary, "")
                views.setTextViewText(R.id.device_footer, footer(context, null, unreachable))
                hideButtonsFrom(views, 0)
                return views
            }

            val device = JSONObject(payload)
            views.setTextViewText(
                R.id.device_label,
                device.optString("label").ifEmpty { key.substringAfter('/') }
            )

            val readings = device.optJSONArray("readings")
            val locale = ConfigurationCompat.getLocales(context.resources.configuration)
                .get(0) ?: Locale.getDefault()

            // La première grandeur porte le widget, avec son intitulé : « 100 »
            // seul ne dit pas ce qu'il mesure.
            val primary =
                if (readings == null || readings.length() == 0) null
                else readings.getJSONObject(0)
            views.setTextViewText(
                R.id.device_primary_label,
                if (primary == null) "" else label(context, primary.optString("name"))
            )
            views.setTextViewText(
                R.id.device_primary,
                if (primary == null) context.getString(R.string.widget_placeholder)
                else format(primary, locale, context)
            )

            // Les suivantes se serrent sur une ligne, et seulement si elles
            // portent une unité : le gabarit décrit aussi des états de service
            // — mouvement en cours, statut de calibration — qui encombrent un
            // écran d'accueil sans rien apprendre à personne.
            val extras = buildString {
                for (i in 1 until (readings?.length() ?: 0)) {
                    val reading = readings!!.getJSONObject(i)
                    if (reading.optString("unit").isEmpty()) continue
                    if (isNotEmpty()) append("   ")
                    append(label(context, reading.optString("name")))
                    append(' ')
                    append(format(reading, locale, context))
                }
            }
            views.setTextViewText(R.id.device_secondary, extras)

            val actions = device.optJSONArray("actions")
            val count = minOf(actions?.length() ?: 0, MAX_BUTTONS)
            for (i in 0 until count) {
                val action = actions!!.getJSONObject(i)
                views.setViewVisibility(buttonId(i), View.VISIBLE)
                views.setTextViewText(buttonId(i), action.optString("name"))
                views.setOnClickPendingIntent(
                    buttonId(i),
                    confirmIntent(
                        context,
                        key,
                        action,
                        device.optString("label"),
                        device.optInt("short"),
                        widgetId
                    )
                )
            }
            hideButtonsFrom(views, count)

            views.setTextViewText(
                R.id.device_footer, footer(context, timestamp, unreachable)
            )
            views.setTextColor(
                R.id.device_footer,
                ContextCompat.getColor(
                    context,
                    if (unreachable || age(timestamp) > AGING_MS) R.color.widget_gauge_warn
                    else R.color.widget_text_secondary
                )
            )
            return views
        }

        /**
         * Rend lisible le nom d'attribut du gabarit.
         *
         * Purement cosmétique : les noms non traduits retombent sur leur forme
         * d'origine, dépouillée de ses tirets bas. Rien ici ne conditionne le
         * comportement — reconnaître un nom ne donne aucun privilège à
         * l'attribut, il s'affiche comme les autres.
         */
        private fun label(context: Context, name: String): String = when (name) {
            "current_position" -> context.getString(R.string.widget_reading_position)
            "temperature", "Temperature", "local_temperature" ->
                context.getString(R.string.widget_reading_temperature)
            "humidity", "Humidity" ->
                context.getString(R.string.widget_reading_humidity)
            "battery", "Bat" -> context.getString(R.string.widget_reading_battery)
            else -> name.replace('_', ' ').replaceFirstChar { it.uppercase() }
        }

        private fun buttonId(index: Int) = when (index) {
            0 -> R.id.device_action_0
            1 -> R.id.device_action_1
            2 -> R.id.device_action_2
            3 -> R.id.device_action_3
            4 -> R.id.device_action_4
            5 -> R.id.device_action_5
            6 -> R.id.device_action_6
            7 -> R.id.device_action_7
            8 -> R.id.device_action_8
            9 -> R.id.device_action_9
            10 -> R.id.device_action_10
            else -> R.id.device_action_11
        }

        private fun rowId(index: Int) = when (index) {
            0 -> R.id.device_actions_0
            1 -> R.id.device_actions_1
            2 -> R.id.device_actions_2
            else -> R.id.device_actions_3
        }

        /**
         * Masque les emplacements au-delà de [first].
         *
         * Deux façons de masquer, et la nuance compte : dans la rangée
         * entamée, les emplacements restants gardent leur place (INVISIBLE),
         * sinon un bouton seul s'étirerait sur toute la largeur. Les rangées
         * entièrement vides disparaissent (GONE) pour ne pas laisser de trou.
         */
        private fun hideButtonsFrom(views: RemoteViews, first: Int) {
            for (i in first until MAX_BUTTONS) {
                val sameRowAsLast = i / BUTTON_COLUMNS == (first - 1) / BUTTON_COLUMNS
                views.setViewVisibility(
                    buttonId(i),
                    if (first > 0 && sameRowAsLast) View.INVISIBLE else View.GONE
                )
            }
            val usedRows =
                (first + BUTTON_COLUMNS - 1) / BUTTON_COLUMNS
            for (row in 0 until MAX_BUTTONS / BUTTON_COLUMNS) {
                views.setViewVisibility(
                    rowId(row),
                    if (row < usedRows) View.VISIBLE else View.GONE
                )
            }
        }

        /**
         * Met en forme une grandeur selon la locale de l'appareil.
         *
         * Le côté Dart envoie un nombre brut à séparateur invariant : lui faire
         * porter la virgule décimale aurait figé le format français dans le
         * stockage.
         */
        private fun format(
            reading: JSONObject,
            locale: Locale,
            context: Context
        ): String {
            if (!reading.has("value")) {
                return context.getString(R.string.widget_placeholder)
            }
            val value = reading.optDouble("value")
            val unit = reading.optString("unit")
            // Les valeurs entières se lisent mieux sans décimale inutile :
            // « 100 % » plutôt que « 100,0 % ».
            val text = if (value == Math.floor(value) && !value.isInfinite()) {
                String.format(locale, "%.0f", value)
            } else {
                String.format(locale, "%.1f", value)
            }
            val withUnit = if (unit.isEmpty()) text else "$text $unit"
            return coveringState(context, reading, value, withUnit)
        }

        /**
         * Aux extrémités, la position d'un volet se dit aussi en mots.
         *
         * « 100 % » laisse deviner, « 100 % ouvert » ne laisse aucun doute —
         * d'autant que le sens n'a rien d'évident : la norme ZCL fait de 100 %
         * un volet fermé, alors que les SONOFF MINI-ZBRBS, pilotés par la box,
         * rapportent 100 volet ouvert (vérifié de visu). Entre les deux, le
         * pourcentage se suffit à lui-même.
         */
        private fun coveringState(
            context: Context,
            reading: JSONObject,
            value: Double,
            formatted: String
        ): String {
            if (reading.optString("name") != "current_position") return formatted
            return when (value) {
                100.0 -> context.getString(R.string.widget_position_open, formatted)
                0.0 -> context.getString(R.string.widget_position_closed, formatted)
                else -> formatted
            }
        }

        /**
         * L'URI distingue les widgets entre eux : deux PendingIntent ne sont
         * confondus que si leurs intents sont `filterEquals`, ce qui la compare.
         */
        private fun refreshIntent(
            context: Context,
            key: String,
            widgetId: Int
        ): PendingIntent {
            val intent = Intent(ACTION_DEVICE_REFRESH)
                .setClassName(context.packageName, DeviceWidgetProvider::class.java.name)
                .setData(Uri.parse("lixee://devrefresh/${Uri.encode(key)}"))
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            return PendingIntent.getBroadcast(context, widgetId, intent, flags())
        }

        /**
         * Un bouton d'action passe par une confirmation, jamais directement.
         *
         * Un volet qui descend parce que le téléphone était en poche ne se
         * rattrape pas d'un appui sur « annuler » : le coût d'une fausse
         * manœuvre n'est pas le même que pour un simple rafraîchissement.
         */
        private fun confirmIntent(
            context: Context,
            key: String,
            action: JSONObject,
            label: String,
            shortAddr: Int,
            widgetId: Int
        ): PendingIntent {
            val name = action.optString("name")
            // L'URI porte les paramètres de la commande, pas seulement son nom :
            // sans eux, l'app devait relire tout l'inventaire de la box avant
            // de pouvoir l'émettre — plusieurs secondes de plus par appui.
            val target = Uri.parse("lixee://devaction/${Uri.encode(key)}/${Uri.encode(name)}")
                .buildUpon()
                .appendQueryParameter("sa", shortAddr.toString())
                .appendQueryParameter("c", action.optInt("command").toString())
                .appendQueryParameter("e", action.optInt("endpoint", 1).toString())
                .appendQueryParameter("v", action.optInt("value").toString())
                .apply {
                    if (action.has("cluster")) {
                        appendQueryParameter("cl", action.optInt("cluster").toString())
                    }
                    if (action.has("mfr")) {
                        appendQueryParameter("m", action.optInt("mfr").toString())
                    }
                }
                .build()

            val intent = Intent(context, WidgetActionConfirmActivity::class.java)
                .setData(target)
                .putExtra(WidgetActionConfirmActivity.EXTRA_LABEL, label)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            // Le code de requête distingue les boutons d'un même widget : leurs
            // URI diffèrent déjà, mais s'en remettre à cela seul rendrait tout
            // renommage d'action silencieusement ambigu.
            return PendingIntent.getActivity(
                context, widgetId * 16 + name.hashCode().and(0xF), intent, flags()
            )
        }

        private fun flags(): Int {
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= 23) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            return flags
        }

        private fun age(timestamp: Long?) =
            if (timestamp == null) Long.MAX_VALUE
            else System.currentTimeMillis() - timestamp

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
            return if (unreachable) {
                context.getString(R.string.widget_unreachable, ageText)
            } else {
                ageText
            }
        }
    }
}

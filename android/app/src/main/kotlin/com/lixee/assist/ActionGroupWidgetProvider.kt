package com.lixee.assist

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONObject

/**
 * Widget d'un groupe d'actions : le widget entier est le bouton.
 *
 * Les groupes se configurent sur la box (`config → Groupes d'actions`) et
 * rassemblent plusieurs commandes sous un nom, une icône et une couleur. Il
 * n'y a donc rien à afficher d'autre, et rien à décider ici : appuyer déclenche
 * ce que la box a enregistré.
 */
class ActionGroupWidgetProvider : HomeWidgetProvider() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_RUN_GROUP) {
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
        const val ACTION_RUN_GROUP = "com.lixee.assist.action.RUN_GROUP"

        fun bindingKeyFor(appWidgetId: Int) = "group_binding_$appWidgetId"

        private fun acknowledge(context: Context, intent: Intent) {
            val widgetId = intent.getIntExtra(
                AppWidgetManager.EXTRA_APPWIDGET_ID,
                AppWidgetManager.INVALID_APPWIDGET_ID
            )
            if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return

            val views = RemoteViews(context.packageName, R.layout.widget_group)
            views.setTextViewText(
                R.id.group_footer, context.getString(R.string.widget_group_running)
            )
            views.setTextColor(
                R.id.group_footer,
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
            val views = RemoteViews(context.packageName, R.layout.widget_group)
            val key = widgetData.getString(bindingKeyFor(widgetId), null)

            if (key == null) {
                views.setTextViewText(R.id.group_icon, "")
                views.setTextViewText(
                    R.id.group_name, context.getString(R.string.widget_no_device)
                )
                views.setTextViewText(
                    R.id.group_footer,
                    context.getString(R.string.widget_tap_to_configure)
                )
                return views
            }

            views.setOnClickPendingIntent(
                R.id.group_root, confirmIntent(context, key, widgetId)
            )

            val payload = widgetData.getString("$key$SUFFIX_GROUP", null)
            // La clé vaut « box#nom » : le nom seul suffit à l'affichage.
            val fallbackName = key.substringAfter('#')
            if (payload.isNullOrEmpty()) {
                views.setTextViewText(R.id.group_icon, "")
                views.setTextViewText(R.id.group_name, fallbackName)
                views.setTextViewText(
                    R.id.group_footer, context.getString(R.string.widget_never_updated)
                )
                return views
            }

            val group = JSONObject(payload)
            views.setTextViewText(
                R.id.group_name, group.optString("name").ifEmpty { fallbackName }
            )

            // La couleur choisie sur la box teinte le nom et l'icône : c'est
            // elle qui distingue « ouverture » de « fermeture » avant de lire.
            val colour = tint(group.optString("color"))
            colour?.let { views.setTextColor(R.id.group_name, it) }
            showIcon(context, views, group, colour)

            val timestamp = widgetData.getString("$key.ts", null)?.toLongOrNull()
            val failedAt = widgetData.getString("$key.failedat", null)?.toLongOrNull()
            val unreachable =
                failedAt != null && (timestamp == null || failedAt > timestamp)
            val sent = widgetData.getString("$key$SUFFIX_SENT", null)?.toIntOrNull()

            views.setTextViewText(
                R.id.group_footer,
                footer(context, group, timestamp, sent, unreachable)
            )
            views.setTextColor(
                R.id.group_footer,
                ContextCompat.getColor(
                    context,
                    if (unreachable) R.color.widget_gauge_warn
                    else R.color.widget_text_secondary
                )
            )
            return views
        }

        /**
         * Trois cas, selon ce que la box a enregistré.
         *
         * Un nom d'icône avec son tracé se dessine ; un émoji d'avant la 2.23
         * s'écrit ; un nom d'icône *sans* tracé — jeu d'icônes injoignable — ne
         * s'affiche pas du tout, plutôt que d'écrire « window-shutter » en
         * toutes lettres là où l'on attend un dessin.
         */
        private fun showIcon(
            context: Context,
            views: RemoteViews,
            group: JSONObject,
            colour: Int?
        ) {
            val icon = group.optString("icon")
            val bitmap = group.optString("iconPath").takeIf { it.isNotEmpty() }?.let {
                GroupIcon.render(
                    it,
                    colour ?: ContextCompat.getColor(context, R.color.widget_text_primary)
                )
            }
            val showEmoji = bitmap == null && icon.isNotEmpty() && !GroupIcon.isIconName(icon)

            views.setViewVisibility(
                R.id.group_icon_image, if (bitmap != null) View.VISIBLE else View.GONE
            )
            bitmap?.let { views.setImageViewBitmap(R.id.group_icon_image, it) }

            views.setViewVisibility(
                R.id.group_icon, if (showEmoji) View.VISIBLE else View.GONE
            )
            views.setTextViewText(R.id.group_icon, if (showEmoji) icon else "")
        }

        /**
         * Le pied de page dit ce qu'a donné le dernier appui.
         *
         * Avant tout déclenchement, il annonce plutôt ce que le groupe fera :
         * savoir qu'un bouton commande six volets change la façon de l'appuyer.
         */
        private fun footer(
            context: Context,
            group: JSONObject,
            timestamp: Long?,
            sent: Int?,
            unreachable: Boolean
        ): String {
            if (unreachable) return context.getString(R.string.widget_group_failed)
            if (sent == null || timestamp == null) {
                val count = group.optInt("count")
                return context.resources.getQuantityString(
                    R.plurals.widget_group_actions, count, count
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
            return context.getString(R.string.widget_group_sent, sent, age)
        }

        /** `#rrggbb` tel que la box l'écrit. `null` si elle n'en donne pas. */
        private fun tint(color: String): Int? = try {
            if (color.startsWith("#")) Color.parseColor(color) else null
        } catch (e: IllegalArgumentException) {
            null
        }

        private fun confirmIntent(
            context: Context,
            key: String,
            widgetId: Int
        ): PendingIntent {
            // Toujours la confirmation : un groupe touche plusieurs appareils
            // d'un coup, et rien ne le défait d'un second appui.
            val intent = Intent(context, WidgetGroupConfirmActivity::class.java)
                .setData(Uri.parse("lixee://groupaction/${Uri.encode(key)}"))
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= 23) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            return PendingIntent.getActivity(context, widgetId, intent, flags)
        }

        private const val SUFFIX_GROUP = ".group"
        private const val SUFFIX_SENT = ".sent"
    }
}

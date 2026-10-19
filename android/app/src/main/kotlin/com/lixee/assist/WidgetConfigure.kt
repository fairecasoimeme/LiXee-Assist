package com.lixee.assist

import android.app.Activity
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build

/**
 * Ouverture de l'écran de configuration depuis le widget lui-même.
 *
 * Android lance cet écran au dépôt du widget, mais tous les lanceurs ne le
 * font pas : celui de Xiaomi (HyperOS) pose un widget déclaré `miuiWidget`
 * sans jamais le proposer. Le widget resterait alors sur « touchez pour
 * configurer » sans que l'appui fasse quoi que ce soit. Tant qu'une instance
 * n'est liée à rien, son appui ouvre donc lui-même cet écran.
 */
object WidgetConfigure {

    fun intent(
        context: Context,
        widgetId: Int,
        activity: Class<out Activity>
    ): PendingIntent {
        val intent = Intent(context, activity)
            // L'URI distingue les widgets : sans elle, deux instances non
            // configurées partageraient le même PendingIntent, et donc le
            // même identifiant.
            .setData(Uri.parse("lixee://configure/$widgetId"))
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= 23) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(context, widgetId, intent, flags)
    }
}

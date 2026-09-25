package com.lixee.assist

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.util.Log
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * Rafraîchit un widget quand il apparaît à l'écran — sur le bureau HyperOS.
 *
 * Android ne dit jamais à une app que son widget est visible. Le bureau de
 * Xiaomi, lui, le fait : un récepteur qui déclare `miuiWidgetRefresh =
 * exposure` reçoit [ACTION] quand l'utilisateur arrive sur la page qui porte
 * le widget. Ailleurs, rien n'arrive, et les widgets gardent le relevé
 * périodique et l'appui.
 *
 * Le bureau limite déjà la cadence (`miuiWidgetRefreshMinInterval`, dans le
 * manifeste). On la limite aussi ici, par cible : deux widgets d'une même box
 * sur une même page ne doivent pas la relever deux fois.
 */
object ExposureRefresh {
    const val ACTION = "miui.appwidget.action.APPWIDGET_UPDATE"

    private const val TAG = "WidgetExposure"
    private const val PREFS = "lixee_exposure"
    private const val MIN_INTERVAL_MS = 30_000L

    /**
     * Traite [intent] s'il vient du bureau. Rend `false` pour les autres
     * actions, que l'appelant passe à la classe parente.
     *
     * [uriFor] donne l'URI de relevé d'un widget, ou `null` s'il n'est pas
     * encore configuré.
     */
    fun handle(
        context: Context,
        intent: Intent,
        provider: Class<*>,
        uriFor: (widgetData: SharedPreferences, widgetId: Int) -> String?,
    ): Boolean {
        if (intent.action != ACTION) return false

        val ids = intent.getIntArrayExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS)
            ?: AppWidgetManager.getInstance(context)
                .getAppWidgetIds(ComponentName(context, provider))
        val widgetData = HomeWidgetPlugin.getData(context)
        val throttle = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()

        val uris = LinkedHashSet<String>()
        for (id in ids) {
            uriFor(widgetData, id)?.let { uris.add(it) }
        }
        for (uri in uris) {
            val last = throttle.getLong(uri, 0L)
            if (now - last < MIN_INTERVAL_MS) continue
            throttle.edit().putLong(uri, now).apply()
            Log.i(TAG, "Widget visible, relevé : $uri")
            WidgetRefreshWorker.enqueueQuiet(context, uri)
        }
        return true
    }
}

package com.lixee.assist

import android.app.Activity
import android.app.AlertDialog
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject

/**
 * Confirmation avant de déclencher un groupe d'actions.
 *
 * Un groupe touche plusieurs appareils d'un coup et rien ne le défait : fermer
 * six volets par mégarde coûte plus qu'un retour arrière. Le nombre d'actions
 * est rappelé dans la question, pour que l'ampleur soit visible avant l'appui.
 */
class WidgetGroupConfirmActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val target = intent?.data
        val key = target?.lastPathSegment?.let { Uri.decode(it) }
        if (target == null || key.isNullOrEmpty()) {
            finish()
            return
        }

        val widgetId = intent?.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID

        val stored = HomeWidgetPlugin.getData(this).getString("$key.group", null)
        val name: String
        val count: Int
        if (stored.isNullOrEmpty()) {
            name = key.substringAfter('#')
            count = 0
        } else {
            val group = JSONObject(stored)
            name = group.optString("name").ifEmpty { key.substringAfter('#') }
            count = group.optInt("count")
        }

        AlertDialog.Builder(this)
            .setTitle(name)
            .setMessage(
                if (count > 0) {
                    resources.getQuantityString(
                        R.plurals.widget_group_confirm, count, count
                    )
                } else {
                    getString(R.string.widget_group_confirm_unknown)
                }
            )
            .setNegativeButton(android.R.string.cancel) { _, _ -> finish() }
            .setPositiveButton(R.string.widget_group_confirm_run) { _, _ ->
                sendBroadcast(
                    Intent(ActionGroupWidgetProvider.ACTION_RUN_GROUP)
                        .setClassName(
                            packageName, ActionGroupWidgetProvider::class.java.name
                        )
                        .setData(target)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                )
                finish()
            }
            .setOnCancelListener { finish() }
            .show()
    }
}

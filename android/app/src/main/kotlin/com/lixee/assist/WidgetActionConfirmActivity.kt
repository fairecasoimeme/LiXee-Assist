package com.lixee.assist

import android.app.Activity
import android.app.AlertDialog
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle

/**
 * Demande confirmation avant d'agir sur un appareil depuis un widget.
 *
 * Un widget se touche facilement en poche. Ouvrir l'app par mégarde se
 * rattrape d'un retour arrière ; faire descendre six volets, non. Cette
 * activité est en thème dialogue : le bureau reste visible derrière, et
 * annuler la referme sans que rien n'ait été envoyé.
 *
 * Elle ne parle pas au réseau — elle rend la main au provider, qui empruntera
 * le même chemin que le rafraîchissement.
 */
class WidgetActionConfirmActivity : Activity() {

    companion object {
        const val EXTRA_LABEL = "device_label"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val target = intent?.data
        val action = target?.lastPathSegment?.let { Uri.decode(it) }
        if (target == null || action.isNullOrEmpty()) {
            finish()
            return
        }

        val label = intent?.getStringExtra(EXTRA_LABEL).orEmpty()
        val widgetId = intent?.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID

        AlertDialog.Builder(this)
            .setTitle(getString(R.string.widget_action_title, action))
            .setMessage(getString(R.string.widget_action_message, action, label))
            .setNegativeButton(android.R.string.cancel) { _, _ -> finish() }
            .setPositiveButton(R.string.widget_action_confirm) { _, _ ->
                sendBroadcast(
                    Intent(DeviceWidgetProvider.ACTION_DEVICE_COMMAND)
                        .setClassName(packageName, DeviceWidgetProvider::class.java.name)
                        .setData(target)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                )
                finish()
            }
            // Retour ou appui hors du cadre : on reste sur le bureau.
            .setOnCancelListener { finish() }
            .show()
    }
}

package com.lixee.assist

import android.app.Activity
import android.app.AlertDialog
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle

/**
 * Demande confirmation avant d'agir sur un appareil ou une zone.
 *
 * Un widget se touche facilement en poche. Ouvrir l'app par mégarde se
 * rattrape d'un retour arrière ; faire descendre six volets ou couper un
 * chauffage, non. Cette activité est en thème dialogue : le bureau reste
 * visible derrière, et annuler la referme sans que rien n'ait été envoyé.
 *
 * Elle ne parle pas au réseau — elle rend la main au provider qui l'a lancée,
 * lequel empruntera le même chemin que le rafraîchissement. Le provider visé
 * est passé en extra : appareils et thermostats la partagent.
 */
class WidgetActionConfirmActivity : Activity() {

    companion object {
        const val EXTRA_LABEL = "device_label"

        /** Intitulé de l'action, quand il ne se lit pas dans l'URI. */
        const val EXTRA_ACTION = "action_label"

        /** Classe du receveur à prévenir. Par défaut, le widget d'appareil. */
        const val EXTRA_RECEIVER = "target_receiver"

        /** Action du broadcast à émettre. */
        const val EXTRA_BROADCAST_ACTION = "target_action"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val target = intent?.data
        if (target == null) {
            finish()
            return
        }

        // L'intitulé vient de l'extra s'il y en a un, sinon du dernier segment
        // de l'URI — c'est là que le widget d'appareil met le nom de l'action.
        val action = intent?.getStringExtra(EXTRA_ACTION)
            ?: target.lastPathSegment?.let { Uri.decode(it) }
        if (action.isNullOrEmpty()) {
            finish()
            return
        }

        val label = intent?.getStringExtra(EXTRA_LABEL).orEmpty()
        val receiver = intent?.getStringExtra(EXTRA_RECEIVER)
            ?: DeviceWidgetProvider::class.java.name
        val broadcast = intent?.getStringExtra(EXTRA_BROADCAST_ACTION)
            ?: DeviceWidgetProvider.ACTION_DEVICE_COMMAND
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
                    Intent(broadcast)
                        .setClassName(packageName, receiver)
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

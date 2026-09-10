package com.lixee.assist

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import es.antonborri.home_widget.HomeWidgetLaunchIntent

/**
 * Demande confirmation avant d'ouvrir une box depuis un widget.
 *
 * Un widget se touche facilement en poche ou en rangeant l'écran d'accueil.
 * Cette activité est en thème dialogue : le bureau reste visible derrière, et
 * annuler la referme sans jamais démarrer l'application. Faire porter la
 * confirmation par LiXee-Assist elle-même aurait imposé de la lancer d'abord,
 * ce qui revenait à subir la fausse manœuvre pour pouvoir la refuser.
 */
class WidgetLaunchConfirmActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val target = intent?.data
        val device = target?.lastPathSegment?.let { Uri.decode(it) }
        if (device.isNullOrEmpty() || device == "unconfigured") {
            finish()
            return
        }

        AlertDialog.Builder(this)
            .setTitle(R.string.widget_open_title)
            .setMessage(getString(R.string.widget_open_message, device))
            .setNegativeButton(android.R.string.cancel) { _, _ -> finish() }
            .setPositiveButton(R.string.widget_open_confirm) { _, _ ->
                startActivity(
                    Intent(this, MainActivity::class.java).apply {
                        action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
                        data = target
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                )
                finish()
            }
            // Retour ou appui hors du cadre : on reste sur le bureau.
            .setOnCancelListener { finish() }
            .show()
    }
}

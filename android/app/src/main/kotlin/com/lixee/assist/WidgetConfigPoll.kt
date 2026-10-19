package com.lixee.assist

import android.app.Activity
import android.os.Handler
import android.os.Looper

/**
 * Remplit un écran de choix ouvert trop tôt.
 *
 * Les listes proposées (box, appareils, groupes, zones) sont publiées par
 * l'application, parfois quelques secondes après la pose du widget. L'écran
 * les lisait une seule fois, à son ouverture : vide, il le restait. Il
 * revérifie donc chaque seconde, et se redessine dès qu'il y a de quoi
 * choisir.
 */
object WidgetConfigPoll {
    private const val EVERY_MS = 1000L

    /** [hasChoices] relit la liste publiée et dit si elle n'est plus vide. */
    fun whileEmpty(activity: Activity, hasChoices: () -> Boolean) {
        val handler = Handler(Looper.getMainLooper())
        handler.postDelayed(object : Runnable {
            override fun run() {
                if (activity.isFinishing || activity.isDestroyed) return
                if (hasChoices()) {
                    activity.recreate()
                } else {
                    handler.postDelayed(this, EVERY_MS)
                }
            }
        }, EVERY_MS)
    }
}

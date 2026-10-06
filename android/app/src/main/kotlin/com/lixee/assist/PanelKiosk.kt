package com.lixee.assist

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log

/**
 * Tenue du kiosque sur un panneau mural : il se lance au démarrage du
 * panneau, et revient de lui-même au premier plan après un passage par
 * l'écran du constructeur.
 *
 * Sans cela, rien sur le panneau ne permet de rouvrir l'application : elle
 * n'a pas de tuile dans le menu du constructeur.
 *
 * Rien de tout cela ne s'applique hors d'un panneau : tout est conditionné à
 * la présence de son service de rétroéclairage (voir [PanelBacklight]).
 */
object PanelKiosk {
    private const val TAG = "LiXeePanel"

    // Préférences écrites par Flutter (shared_preferences), dont les clés
    // portent ce préfixe et dont les entiers sont stockés en Long.
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val KEY_AUTOSTART = "flutter.panel_autostart"
    private const val KEY_RETURN_MINUTES = "flutter.panel_return_minutes"
    private const val DEFAULT_RETURN_MINUTES = 2L

    private const val RETURN_REQUEST = 4201
    private const val RETRY_MS = 60_000L

    /**
     * Le kiosque vient d'être ramené devant alors que l'écran était éteint :
     * il ne doit pas le rallumer. Lu une fois par Flutter, puis effacé.
     */
    @Volatile
    private var quietLaunch = false

    fun takeQuietLaunch(): Boolean {
        val quiet = quietLaunch
        quietLaunch = false
        return quiet
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)

    fun autostart(context: Context): Boolean =
        PanelBacklight.supported(context) &&
            prefs(context).getBoolean(KEY_AUTOSTART, true)

    /** Délai avant le retour au kiosque, en minutes ; 0 = jamais. */
    private fun returnMinutes(context: Context): Long =
        (prefs(context).all[KEY_RETURN_MINUTES] as? Number)?.toLong()
            ?: DEFAULT_RETURN_MINUTES

    private fun returnIntent(context: Context): PendingIntent {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= 23) flags = flags or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(
            context,
            RETURN_REQUEST,
            Intent(context, PanelReturnReceiver::class.java),
            flags
        )
    }

    /** À appeler quand le kiosque quitte le premier plan. */
    fun scheduleReturn(context: Context, afterMs: Long? = null) {
        if (!PanelBacklight.supported(context)) return
        val minutes = returnMinutes(context)
        if (minutes <= 0) return
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarms.set(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + (afterMs ?: minutes * 60_000L),
            returnIntent(context)
        )
    }

    /** À appeler quand le kiosque revient au premier plan. */
    fun cancelReturn(context: Context) {
        if (!PanelBacklight.supported(context)) return
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarms.cancel(returnIntent(context))
    }

    fun launch(context: Context, quiet: Boolean) {
        quietLaunch = quiet
        try {
            context.startActivity(
                Intent(context, MainActivity::class.java)
                    .addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                    )
            )
        } catch (e: Throwable) {
            quietLaunch = false
            Log.w(TAG, "Kiosque non relancé", e)
        }
    }

    /**
     * Délai écoulé : on ne reprend la main que si l'écran s'est éteint,
     * signe que personne ne se sert de l'écran du constructeur. Sinon, on
     * repasse dans une minute.
     */
    fun onReturnDue(context: Context) {
        if (PanelBacklight.level() == 0) {
            launch(context, quiet = true)
        } else {
            scheduleReturn(context, RETRY_MS)
        }
    }
}

/** Lance le kiosque au démarrage du panneau. */
class PanelBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (PanelKiosk.autostart(context)) PanelKiosk.launch(context, quiet = false)
    }
}

/** Ramène le kiosque au premier plan, une fois le délai écoulé. */
class PanelReturnReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        PanelKiosk.onReturnDue(context)
    }
}

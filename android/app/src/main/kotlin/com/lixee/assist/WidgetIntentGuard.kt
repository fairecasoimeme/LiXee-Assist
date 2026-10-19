package com.lixee.assist

import android.content.Context
import android.content.Intent
import android.util.Log
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Distingue nos propres intents de ceux d'une autre app.
 *
 * Les récepteurs des widgets sont exportés : sans cela, le bureau HyperOS ne
 * peut pas leur signaler qu'un widget vient d'apparaître (ExposureRefresh).
 * Mais un récepteur exporté accepte n'importe quel expéditeur, et les nôtres
 * exécutent des commandes — un volet, une consigne de thermostat. Chaque
 * intent que l'app émet porte donc un jeton tiré au hasard à l'installation,
 * gardé dans ses préférences privées. Une autre app ne peut ni le lire, ni
 * l'extraire d'un PendingIntent, dont le contenu lui reste opaque.
 */
object WidgetIntentGuard {
    private const val TAG = "WidgetGuard"
    private const val PREFS = "lixee_widget_guard"
    private const val KEY_TOKEN = "token"
    private const val EXTRA_TOKEN = "com.lixee.assist.extra.WIDGET_TOKEN"

    @Volatile
    private var cached: String? = null

    /** Ajoute le jeton à [intent], et le rend pour chaîner. */
    fun sign(context: Context, intent: Intent): Intent =
        intent.putExtra(EXTRA_TOKEN, token(context))

    /** Vrai si [intent] vient de l'app elle-même. */
    fun isOurs(context: Context, intent: Intent): Boolean {
        val presented = intent.getStringExtra(EXTRA_TOKEN)
        // Comparaison en temps constant : le jeton ne doit pas se laisser
        // deviner caractère par caractère.
        val ok = presented != null && MessageDigest.isEqual(
            presented.toByteArray(), token(context).toByteArray()
        )
        if (!ok) Log.w(TAG, "Intent refusé, jeton absent ou faux : ${intent.action}")
        return ok
    }

    @Synchronized
    private fun token(context: Context): String {
        cached?.let { return it }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getString(KEY_TOKEN, null)
        if (stored != null) return stored.also { cached = it }

        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val fresh = bytes.joinToString("") { "%02x".format(it) }
        // commit, pas apply : un PendingIntent signé avec ce jeton peut être
        // déclenché avant qu'un apply ait atteint le disque.
        prefs.edit().putString(KEY_TOKEN, fresh).commit()
        return fresh.also { cached = it }
    }
}

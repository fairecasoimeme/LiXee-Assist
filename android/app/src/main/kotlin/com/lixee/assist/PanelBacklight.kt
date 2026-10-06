package com.lixee.assist

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import java.io.File

/**
 * Rétroéclairage d'un panneau mural Sonoff NSPanel Pro.
 *
 * Sur ces panneaux, l'écran n'obéit pas à la veille d'Android : un service
 * du fabricant, « smatek », écrit lui-même le niveau du rétroéclairage, et
 * c'est l'application du constructeur qui l'éteint et le rallume. Quand une
 * autre application est au premier plan, plus personne ne le rallume au
 * toucher : le kiosque doit donc le faire.
 *
 * Le service n'est pas dans le SDK ; on l'atteint par réflexion. Sur tout
 * autre appareil, il est absent et ces fonctions ne font rien.
 */
object PanelBacklight {
    private const val TAG = "LiXeePanel"
    private const val SERVICE = "smatek"
    private val levelFile = File("/sys/class/backlight/backlight/brightness")

    /** `android.app.SmatekManager`, ou à défaut le service lui-même. */
    @SuppressLint("WrongConstant")
    private fun target(context: Context): Any? {
        try {
            context.applicationContext.getSystemService(SERVICE)?.let { return it }
        } catch (_: Throwable) {
        }
        return try {
            val binder = Class.forName("android.os.ServiceManager")
                .getMethod("getService", String::class.java)
                .invoke(null, SERVICE) ?: return null
            Class.forName("android.os.ISmatekService\$Stub")
                .getMethod("asInterface", android.os.IBinder::class.java)
                .invoke(null, binder)
        } catch (_: Throwable) {
            null
        }
    }

    fun supported(context: Context): Boolean = target(context) != null

    /** Allume (au niveau réglé sur le panneau) ou éteint le rétroéclairage. */
    fun set(context: Context, on: Boolean): Boolean {
        val target = target(context) ?: return false
        return try {
            target.javaClass
                .getMethod("setLcdBlackLight", Boolean::class.javaPrimitiveType)
                .invoke(target, on)
            true
        } catch (e: Throwable) {
            Log.w(TAG, "Rétroéclairage non piloté", e)
            false
        }
    }

    /** Niveau réel du rétroéclairage (0 = éteint), ou `null` s'il est illisible. */
    fun level(): Int? = try {
        levelFile.readText().trim().toIntOrNull()
    } catch (_: Throwable) {
        null
    }
}

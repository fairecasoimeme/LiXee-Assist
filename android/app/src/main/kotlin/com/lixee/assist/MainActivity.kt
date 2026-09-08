package com.lixee.assist

import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.work.WorkManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val WIFI_BINDER_CHANNEL = "wifi_force_binder"
    private val APP_CHANNEL = "app.channel.shared.data"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        unblockWidgetRefreshChain()

        // ✅ Channel existant pour le WiFi Force Binder
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_BINDER_CHANNEL)
            .setMethodCallHandler(WiFiForceBinder(this))

        // ✅ NOUVEAU: Channel pour ouvrir les paramètres système
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openWifiSettings" -> {
                        try {
                            // Ouvre directement les paramètres WiFi
                            val intent = Intent(Settings.ACTION_WIFI_SETTINGS)
                            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // Fallback: ouvrir les paramètres réseau sans fil
                            try {
                                val fallbackIntent = Intent(Settings.ACTION_WIRELESS_SETTINGS)
                                fallbackIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                startActivity(fallbackIntent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("UNAVAILABLE", "Impossible d'ouvrir les paramètres WiFi: ${e2.message}", null)
                            }
                        }
                    }
                    "openNetworkSettings" -> {
                        // Optionnel: ouvrir les paramètres réseau généraux
                        try {
                            val intent = Intent(Settings.ACTION_WIRELESS_SETTINGS)
                            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("UNAVAILABLE", "Impossible d'ouvrir les paramètres réseau: ${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Débloque le rafraîchissement du widget au clic.
     *
     * home_widget enfile son travail avec [ExistingWorkPolicy.APPEND] sous un
     * nom unique. Or WorkManager marque comme échoué, sans jamais l'exécuter,
     * tout travail ajouté derrière une chaîne déjà en échec : un seul échec —
     * typiquement le tout premier appui, avant que le callback Dart ne soit
     * enregistré — condamne définitivement tous les appuis suivants.
     *
     * Il faut annuler avant de purger : `pruneWork` ne supprime qu'un travail
     * sans dépendants, or la tête de chaîne en garde tant que les suivants
     * existent — purger seul la laisse en place et le problème persiste.
     */
    private fun unblockWidgetRefreshChain() {
        try {
            val workManager = WorkManager.getInstance(applicationContext)
            workManager.cancelUniqueWork(WIDGET_REFRESH_WORK).result.addListener(
                { workManager.pruneWork() },
                { runnable -> runnable.run() }
            )
        } catch (e: Exception) {
            Log.w(TAG, "Déblocage du rafraîchissement widget impossible", e)
        }
    }

    private companion object {
        const val TAG = "LiXeeWidget"

        /** Nom unique employé par home_widget pour son travail d'arrière-plan. */
        const val WIDGET_REFRESH_WORK = "home_widget_background"
    }
}
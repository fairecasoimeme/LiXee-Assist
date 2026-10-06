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
    private val PANEL_CHANNEL = "com.lixee.assist/panel"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        unblockWidgetRefreshChain()

        // ✅ Channel existant pour le WiFi Force Binder
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_BINDER_CHANNEL)
            .setMethodCallHandler(WiFiForceBinder(this))

        // Rétroéclairage des panneaux muraux (voir PanelBacklight)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PANEL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "backlightSupported" -> result.success(PanelBacklight.supported(this))
                    "setBacklight" ->
                        result.success(PanelBacklight.set(this, call.arguments as? Boolean ?: true))
                    "backlightLevel" -> result.success(PanelBacklight.level())
                    "takeQuietLaunch" -> result.success(PanelKiosk.takeQuietLaunch())
                    else -> result.notImplemented()
                }
            }

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

    override fun onStart() {
        super.onStart()
        PanelKiosk.cancelReturn(this)
    }

    override fun onStop() {
        super.onStop()
        PanelKiosk.scheduleReturn(this)
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
        // Hors du thread principal : initialiser WorkManager et attendre ses
        // opérations pendant configureFlutterEngine faisait dépasser le délai
        // de démarrage et déclenchait un ANR « failed to complete startup ».
        Thread {
            try {
                val workManager = WorkManager.getInstance(applicationContext)
                // L'annulation doit être terminée avant la purge : purger une
                // chaîne qui a encore des dépendants en épargne la tête.
                workManager.cancelUniqueWork(WIDGET_REFRESH_WORK).result.get()
                workManager.pruneWork().result.get()
            } catch (e: Exception) {
                Log.w(TAG, "Déblocage du rafraîchissement widget impossible", e)
            }
        }.start()
    }

    private companion object {
        const val TAG = "LiXeeWidget"

        /** Nom unique employé par home_widget pour son travail d'arrière-plan. */
        const val WIDGET_REFRESH_WORK = "home_widget_background"
    }
}
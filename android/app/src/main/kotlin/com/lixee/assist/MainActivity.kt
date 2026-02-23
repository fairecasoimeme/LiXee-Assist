package com.lixee.assist

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import androidx.core.view.WindowCompat
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val WIFI_BINDER_CHANNEL = "wifi_force_binder"
    private val APP_CHANNEL = "app.channel.shared.data"  // ✅ NOUVEAU: Channel pour les paramètres

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            // ⚠️ Désactiver les API obsolètes de couleurs
            window.statusBarColor = android.graphics.Color.TRANSPARENT
            window.navigationBarColor = android.graphics.Color.TRANSPARENT
        }

        // ✅ Active l'affichage bord à bord
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
}
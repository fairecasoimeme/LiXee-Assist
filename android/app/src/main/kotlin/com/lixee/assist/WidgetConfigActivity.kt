package com.lixee.assist

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Context
import android.os.Bundle
import android.widget.ArrayAdapter
import android.widget.ListView
import android.widget.TextView
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray

/**
 * Écran de configuration lancé au dépôt du widget.
 *
 * L'app gère plusieurs box : chaque instance de widget doit savoir laquelle
 * afficher. Le choix est stocké sous [deviceKeyFor], indexé par appWidgetId,
 * ce qui permet de poser autant de widgets que de box.
 */
class WidgetConfigActivity : Activity() {

    companion object {
        /** Clé du choix de box, propre à une instance de widget. */
        fun deviceKeyFor(appWidgetId: Int) = "widget_binding_$appWidgetId"
    }

    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Annuler par défaut : si l'utilisateur revient en arrière, Android
        // retire le widget au lieu d'en laisser un non configuré.
        setResult(RESULT_CANCELED)

        appWidgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID

        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        setContentView(R.layout.widget_config)

        val devices = readDeviceList()
        val empty = findViewById<TextView>(R.id.config_empty)
        val list = findViewById<ListView>(R.id.config_list)

        if (devices.isEmpty()) {
            empty.setText(R.string.widget_config_empty)
            list.visibility = ListView.GONE
            return
        }

        empty.visibility = TextView.GONE
        list.adapter = ArrayAdapter(this, android.R.layout.simple_list_item_1, devices)
        list.setOnItemClickListener { _, _, position, _ ->
            bind(devices[position])
        }
    }

    /**
     * Liste publiée par HomeWidgetBridge, plutôt que lue dans les préférences
     * de Flutter : leur encodage des listes est un détail d'implémentation du
     * plugin shared_preferences, sur lequel on ne veut pas s'appuyer ici.
     */
    private fun readDeviceList(): List<String> {
        val raw = HomeWidgetPlugin.getData(this).getString("widget_device_list", null)
            ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            (0 until array.length()).map { array.getString(it) }
        }.getOrDefault(emptyList())
    }

    private fun bind(deviceName: String) {
        HomeWidgetPlugin.getData(this).edit()
            .putString(deviceKeyFor(appWidgetId), deviceName)
            .apply()

        // Dessiner tout de suite : sans cela le widget resterait vide jusqu'au
        // prochain relevé, soit potentiellement 15 minutes.
        ConsoWidgetProvider.render(
            this,
            AppWidgetManager.getInstance(this),
            intArrayOf(appWidgetId),
            HomeWidgetPlugin.getData(this)
        )

        setResult(
            RESULT_OK,
            intent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
        )
        finish()
    }
}

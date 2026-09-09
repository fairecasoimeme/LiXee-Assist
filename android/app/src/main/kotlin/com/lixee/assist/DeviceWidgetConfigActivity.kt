package com.lixee.assist

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.ListView
import android.widget.TextView
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray

/**
 * Choix de l'appareil au dépôt d'un widget, en deux temps : la box, puis
 * l'appareil.
 *
 * Une liste unique mêlant toutes les box devenait vite illisible — six volets,
 * un thermostat et un capteur sur une seule installation, et chaque ligne
 * devait rappeler sa box pour lever l'ambiguïté. En deux écrans, chaque liste
 * tient sous les yeux et les lignes n'ont plus à se justifier.
 */
class DeviceWidgetConfigActivity : Activity() {

    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private var catalogue: List<Entry> = emptyList()

    /** Box choisie à la première étape ; `null` tant qu'on y est encore. */
    private var selectedBox: String? = null

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
        catalogue = readCatalogue()

        if (catalogue.isEmpty()) {
            findViewById<TextView>(R.id.config_title)
                .setText(R.string.widget_device_config_title)
            findViewById<TextView>(R.id.config_empty)
                .setText(R.string.widget_device_config_empty)
            findViewById<ListView>(R.id.config_list).visibility = View.GONE
            return
        }

        findViewById<TextView>(R.id.config_empty).visibility = View.GONE
        showBoxes()
    }

    /**
     * Le retour ramène au choix de la box plutôt que d'annuler la pose.
     *
     * Sans ça, se tromper de box coûtait de reposer le widget depuis le début.
     */
    @Deprecated("onBackPressed est déprécié, mais reste la voie compatible API 23")
    override fun onBackPressed() {
        if (selectedBox != null) {
            selectedBox = null
            showBoxes()
            return
        }
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    private fun showBoxes() {
        val boxes = catalogue.map { it.box }.distinct().sorted()

        // Une seule box : lui faire choisir entre une option unique n'apprend
        // rien à personne.
        if (boxes.size == 1) {
            showDevices(boxes.first())
            return
        }

        findViewById<TextView>(R.id.config_title)
            .setText(R.string.widget_device_config_box)
        bind(
            boxes.map { box ->
                val count = catalogue.count { it.box == box }
                Row(
                    box,
                    resources.getQuantityString(
                        R.plurals.widget_device_count, count, count
                    )
                )
            }
        ) { position -> showDevices(boxes[position]) }
    }

    private fun showDevices(box: String) {
        selectedBox = box
        val devices = catalogue.filter { it.box == box }

        findViewById<TextView>(R.id.config_title).text =
            getString(R.string.widget_device_config_device, box)
        // Beaucoup d'appareils n'ont pas d'alias : leur libellé est déjà le
        // modèle, et le répéter en sous-titre n'apprend rien.
        bind(
            devices.map { Row(it.label, if (it.model == it.label) "" else it.model) }
        ) { position ->
            attach(devices[position].key)
        }
    }

    private data class Row(val title: String, val detail: String)

    private fun bind(rows: List<Row>, onPick: (Int) -> Unit) {
        val list = findViewById<ListView>(R.id.config_list)
        list.visibility = View.VISIBLE
        list.adapter = object : ArrayAdapter<Row>(
            this, R.layout.widget_config_item, rows
        ) {
            override fun getView(
                position: Int,
                convertView: View?,
                parent: ViewGroup
            ): View {
                val view = convertView ?: layoutInflater.inflate(
                    R.layout.widget_config_item, parent, false
                )
                val row = rows[position]
                view.findViewById<TextView>(R.id.item_title).text = row.title
                val detail = view.findViewById<TextView>(R.id.item_detail)
                detail.text = row.detail
                detail.visibility =
                    if (row.detail.isEmpty()) View.GONE else View.VISIBLE
                return view
            }
        }
        list.setOnItemClickListener { _, _, position, _ -> onPick(position) }
    }

    private fun attach(key: String) {
        HomeWidgetPlugin.getData(this).edit()
            .putString(DeviceWidgetProvider.bindingKeyFor(appWidgetId), key)
            .apply()

        // Dessiner tout de suite : sans ça le widget resterait vide jusqu'au
        // prochain relevé, ce qui ressemble à un échec de configuration.
        AppWidgetManager.getInstance(this).updateAppWidget(
            appWidgetId,
            DeviceWidgetProvider.build(this, HomeWidgetPlugin.getData(this), appWidgetId)
        )

        setResult(
            RESULT_OK,
            Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
        )
        finish()
    }

    private data class Entry(
        val key: String,
        val box: String,
        val label: String,
        val model: String
    )

    private fun readCatalogue(): List<Entry> {
        val raw = HomeWidgetPlugin.getData(this)
            .getString(CATALOGUE_KEY, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { i ->
                val o = array.optJSONObject(i) ?: return@mapNotNull null
                val key = o.optString("key")
                if (key.isEmpty()) null
                else Entry(
                    key = key,
                    box = o.optString("box").ifEmpty { key.substringBefore('/') },
                    label = o.optString("label").ifEmpty { key.substringAfter('/') },
                    model = o.optString("model")
                )
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private companion object {
        const val CATALOGUE_KEY = "widget_device_catalog"
    }
}

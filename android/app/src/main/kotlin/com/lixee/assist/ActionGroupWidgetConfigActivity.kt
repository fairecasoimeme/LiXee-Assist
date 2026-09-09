package com.lixee.assist

import android.app.Activity
import android.appwidget.AppWidgetManager
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
 * Choix du groupe au dépôt d'un widget, en deux temps comme pour les
 * appareils : la box, puis le groupe.
 */
class ActionGroupWidgetConfigActivity : Activity() {

    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private var catalogue: List<Entry> = emptyList()
    private var selectedBox: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
                .setText(R.string.widget_group_config_title)
            findViewById<TextView>(R.id.config_empty)
                .setText(R.string.widget_group_config_empty)
            findViewById<ListView>(R.id.config_list).visibility = View.GONE
            return
        }

        findViewById<TextView>(R.id.config_empty).visibility = View.GONE
        showBoxes()
    }

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
        if (boxes.size == 1) {
            showGroups(boxes.first())
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
                        R.plurals.widget_group_count, count, count
                    )
                )
            }
        ) { position -> showGroups(boxes[position]) }
    }

    private fun showGroups(box: String) {
        selectedBox = box
        val groups = catalogue.filter { it.box == box }
        findViewById<TextView>(R.id.config_title).text =
            getString(R.string.widget_group_config_group, box)
        bind(
            groups.map { entry ->
                Row(
                    if (entry.icon.isEmpty()) entry.name
                    else entry.icon + "  " + entry.name,
                    resources.getQuantityString(
                        R.plurals.widget_group_actions, entry.count, entry.count
                    )
                )
            }
        ) { position -> attach(groups[position].key) }
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
                view.findViewById<TextView>(R.id.item_title).text = rows[position].title
                val detail = view.findViewById<TextView>(R.id.item_detail)
                detail.text = rows[position].detail
                detail.visibility =
                    if (rows[position].detail.isEmpty()) View.GONE else View.VISIBLE
                return view
            }
        }
        list.setOnItemClickListener { _, _, position, _ -> onPick(position) }
    }

    private fun attach(key: String) {
        HomeWidgetPlugin.getData(this).edit()
            .putString(ActionGroupWidgetProvider.bindingKeyFor(appWidgetId), key)
            .apply()
        AppWidgetManager.getInstance(this).updateAppWidget(
            appWidgetId,
            ActionGroupWidgetProvider.build(
                this, HomeWidgetPlugin.getData(this), appWidgetId
            )
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
        val name: String,
        val icon: String,
        val count: Int
    )

    private fun readCatalogue(): List<Entry> {
        val raw = HomeWidgetPlugin.getData(this)
            .getString("widget_group_catalog", null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { i ->
                val o = array.optJSONObject(i) ?: return@mapNotNull null
                val key = o.optString("key")
                if (key.isEmpty()) null
                else Entry(
                    key = key,
                    box = o.optString("box").ifEmpty { key.substringBefore('#') },
                    name = o.optString("name").ifEmpty { key.substringAfter('#') },
                    icon = o.optString("icon"),
                    count = o.optString("count").toIntOrNull() ?: 0
                )
            }
        } catch (e: Exception) {
            emptyList()
        }
    }
}

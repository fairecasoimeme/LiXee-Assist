package com.lixee.assist

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import es.antonborri.home_widget.HomeWidgetPlugin
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Exécute le rappel Dart d'appui sur widget, et **attend qu'il finisse**.
 *
 * Le worker fourni par home_widget rend la main dès qu'il a posté l'appel :
 * WorkManager considère alors le travail terminé, relâche son wakelock, et le
 * processus retombe au rang des caches. Sur les surcouches agressives il est
 * tué dans la seconde, en plein relevé — le widget reste sur « mise à jour… »
 * et rien ne le déloge. On refait donc le trajet nous-mêmes, en tenant le
 * worker ouvert le temps du relevé.
 *
 * Le protocole reste celui du greffon (canal `home_widget/background`,
 * poignées lues dans ses préférences) : côté Dart, rien ne change.
 */
class WidgetRefreshWorker(
    private val context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val handle = HomeWidgetPlugin.getDispatcherHandle(context)
        if (handle == 0L) {
            // L'app n'a jamais démarré depuis l'installation : personne n'a
            // enregistré de rappel. Rien à faire, et rien à réessayer.
            Log.w(TAG, "Aucun rappel enregistré, relevé abandonné")
            return Result.failure()
        }

        val info = FlutterCallbackInformation.lookupCallbackInformation(handle)
            ?: return Result.failure()

        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)

        val engine = withContext(Dispatchers.Main) { FlutterEngine(context) }
        try {
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger, CHANNEL_NAME
            )
            // Le rappel Dart s'annonce prêt avant qu'on puisse l'appeler :
            // l'isolate met un instant à s'installer, et un appel émis trop
            // tôt se perdrait sans réponse.
            val ready = CompletableDeferred<Unit>()
            channel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                if (call.method == "HomeWidget.backgroundInitialized") {
                    ready.complete(Unit)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

            withContext(Dispatchers.Main) {
                engine.dartExecutor.executeDartCallback(
                    DartExecutor.DartCallback(
                        context.assets, loader.findAppBundlePath(), info
                    )
                )
            }

            if (withTimeoutOrNull(STARTUP_TIMEOUT_MS) { ready.await() } == null) {
                Log.w(TAG, "Isolate Dart injoignable")
                return Result.failure()
            }

            val done = CompletableDeferred<Unit>()
            val args = listOf(
                HomeWidgetPlugin.getHandle(context),
                inputData.getString(DATA_KEY) ?: ""
            )
            withContext(Dispatchers.Main) {
                channel.invokeMethod(
                    "", args,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) = done.complete(Unit).let {}
                        override fun error(code: String, message: String?, details: Any?) {
                            Log.w(TAG, "Relevé en erreur: $code $message")
                            done.complete(Unit)
                        }

                        override fun notImplemented() = done.complete(Unit).let {}
                    }
                )
            }

            // Plafond de sécurité : un relevé qui traîne indéfiniment
            // retiendrait le processus et finirait de toute façon coupé par le
            // système, sans que WorkManager sache quoi en faire.
            withTimeoutOrNull(WORK_TIMEOUT_MS) { done.await() }
        } finally {
            withContext(Dispatchers.Main) { engine.destroy() }
        }
        return Result.success()
    }

    companion object {
        private const val TAG = "WidgetRefresh"
        private const val CHANNEL_NAME = "home_widget/background"
        private const val DATA_KEY = "uri_data"
        private const val STARTUP_TIMEOUT_MS = 20_000L
        private const val WORK_TIMEOUT_MS = 60_000L

        /** Un seul relevé à la fois : réappuyer relance, sans empiler. */
        private const val UNIQUE_WORK = "lixee_widget_refresh"

        fun enqueue(context: Context, uri: String?) {
            val request = OneTimeWorkRequestBuilder<WidgetRefreshWorker>()
                .setInputData(Data.Builder().putString(DATA_KEY, uri ?: "").build())
                .build()
            // REPLACE, jamais APPEND : une chaîne d'appuis se bloque tout
            // entière au premier maillon en échec, et plus aucun appui ne
            // passe jusqu'à ce qu'on la purge.
            WorkManager.getInstance(context)
                .enqueueUniqueWork(UNIQUE_WORK, ExistingWorkPolicy.REPLACE, request)
        }
    }
}

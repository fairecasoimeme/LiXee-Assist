package com.lixee.assist

import android.content.Context
import android.os.Handler
import android.os.Looper
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
import kotlinx.coroutines.NonCancellable
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
 * Le moteur Flutter survit à l'appui, quelques minutes : le démarrer coûte
 * deux secondes, plus que le relevé lui-même. L'isolate gardé en vie garde
 * aussi ses sessions et ses caches, et l'appui suivant part d'une connexion
 * déjà ouverte.
 *
 * Le protocole reste celui du greffon (canal `home_widget/background`,
 * poignées lues dans ses préférences) : côté Dart, rien ne change.
 */
class WidgetRefreshWorker(
    private val context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val tappedAt = inputData.getLong(TAPPED_AT_KEY, 0L)
        fun since() = if (tappedAt == 0L) -1 else System.currentTimeMillis() - tappedAt
        Log.i(TAG, "[TIMING] worker démarré +${since()} ms")

        val handle = HomeWidgetPlugin.getDispatcherHandle(context)
        if (handle == 0L) {
            // L'app n'a jamais démarré depuis l'installation : personne n'a
            // enregistré de rappel. Rien à faire, et rien à réessayer.
            Log.w(TAG, "Aucun rappel enregistré, relevé abandonné")
            return Result.failure()
        }

        val warm = withContext(Dispatchers.Main) { acquire(context, handle) }
            ?: return Result.failure()
        try {
            if (withTimeoutOrNull(STARTUP_TIMEOUT_MS) { warm.ready.await() } == null) {
                Log.w(TAG, "Isolate Dart injoignable")
                withContext(NonCancellable + Dispatchers.Main) { discard(warm) }
                return Result.failure()
            }
            Log.i(TAG, "[TIMING] isolate prêt +${since()} ms")

            val done = CompletableDeferred<Unit>()
            val args = listOf(
                HomeWidgetPlugin.getHandle(context),
                inputData.getString(DATA_KEY) ?: ""
            )
            withContext(Dispatchers.Main) {
                warm.channel.invokeMethod(
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
            Log.i(TAG, "[TIMING] relevé terminé +${since()} ms")
        } finally {
            // NonCancellable : un nouvel appui annule ce worker (REPLACE), et
            // sans lui le finally s'interromprait avant de rendre le moteur.
            withContext(NonCancellable + Dispatchers.Main) { release(warm) }
        }
        return Result.success()
    }

    /** Un moteur démarré, et la promesse que son isolate s'est annoncé. */
    private class WarmEngine(
        val engine: FlutterEngine,
        val channel: MethodChannel,
        val ready: CompletableDeferred<Unit>,
    ) {
        var users = 0
    }

    companion object {
        private const val TAG = "WidgetRefresh"
        private const val CHANNEL_NAME = "home_widget/background"
        private const val DATA_KEY = "uri_data"
        private const val TAPPED_AT_KEY = "tapped_at"
        private const val STARTUP_TIMEOUT_MS = 20_000L
        private const val WORK_TIMEOUT_MS = 60_000L

        /**
         * Durée de vie du moteur après le dernier appui. Assez pour enchaîner
         * les commandes d'un volet, pas assez pour peser sur la mémoire du
         * téléphone quand on ne se sert plus des widgets.
         */
        private const val IDLE_MS = 3 * 60_000L

        /** Un seul relevé à la fois : réappuyer relance, sans empiler. */
        private const val UNIQUE_WORK = "lixee_widget_refresh"

        // Tout ce qui suit n'est touché que depuis le thread principal.
        private var warm: WarmEngine? = null
        private val mainHandler = Handler(Looper.getMainLooper())
        private val idleRelease = Runnable {
            warm?.takeIf { it.users == 0 }?.let { discard(it) }
        }

        /**
         * Rend le moteur déjà chaud, ou en démarre un. Thread principal.
         *
         * Le chargeur passe **avant** la recherche du rappel : c'est lui qui
         * charge la bibliothèque native, et dans un processus froid — l'app
         * fermée, cas ordinaire d'un appui sur widget — la recherche échoue
         * sans elle.
         */
        private fun acquire(context: Context, handle: Long): WarmEngine? {
            mainHandler.removeCallbacks(idleRelease)
            warm?.let {
                it.users++
                return it
            }

            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context.applicationContext)
            loader.ensureInitializationComplete(context.applicationContext, null)

            val info = FlutterCallbackInformation.lookupCallbackInformation(handle)
                ?: return null

            val engine = FlutterEngine(context.applicationContext)
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
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
            engine.dartExecutor.executeDartCallback(
                DartExecutor.DartCallback(
                    context.assets, loader.findAppBundlePath(), info
                )
            )
            return WarmEngine(engine, channel, ready).also {
                it.users = 1
                warm = it
            }
        }

        /** Rend le moteur, et programme sa fin si plus personne ne s'en sert. */
        private fun release(engine: WarmEngine) {
            engine.users--
            if (engine === warm && engine.users <= 0) {
                engine.users = 0
                mainHandler.removeCallbacks(idleRelease)
                mainHandler.postDelayed(idleRelease, IDLE_MS)
            }
        }

        /** Détruit un moteur qui ne répond pas, ou qui a assez attendu. */
        private fun discard(engine: WarmEngine) {
            if (warm === engine) warm = null
            engine.engine.destroy()
        }

        fun enqueue(context: Context, uri: String?) {
            val request = OneTimeWorkRequestBuilder<WidgetRefreshWorker>()
                .setInputData(
                    Data.Builder()
                        .putString(DATA_KEY, uri ?: "")
                        .putLong(TAPPED_AT_KEY, System.currentTimeMillis())
                        .build()
                )
                .build()
            // REPLACE, jamais APPEND : une chaîne d'appuis se bloque tout
            // entière au premier maillon en échec, et plus aucun appui ne
            // passe jusqu'à ce qu'on la purge.
            WorkManager.getInstance(context)
                .enqueueUniqueWork(UNIQUE_WORK, ExistingWorkPolicy.REPLACE, request)
        }

        /**
         * Relevé que personne n'a demandé : le widget vient d'apparaître.
         *
         * Un nom par cible, et KEEP : plusieurs widgets d'une même page
         * arrivent ensemble, et sous le nom commun des appuis chacun
         * annulerait le précédent. Ils ne doivent pas non plus évincer un
         * appui en cours.
         */
        fun enqueueQuiet(context: Context, uri: String) {
            val request = OneTimeWorkRequestBuilder<WidgetRefreshWorker>()
                .setInputData(
                    Data.Builder()
                        .putString(DATA_KEY, uri)
                        .putLong(TAPPED_AT_KEY, System.currentTimeMillis())
                        .build()
                )
                .build()
            WorkManager.getInstance(context)
                .enqueueUniqueWork("$UNIQUE_WORK:$uri", ExistingWorkPolicy.KEEP, request)
        }
    }
}

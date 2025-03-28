package com.example.zigpower_connect

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class WiFiForceBinder(private val context: Context) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "bindNetwork") {
            val ssid = call.argument<String>("ssid")
            if (ssid != null) {
                bindToNetwork(result)
            } else {
                result.error("NO_SSID", "SSID non fourni", null)
            }
        } else {
            result.notImplemented()
        }
    }

    private fun bindToNetwork(result: MethodChannel.Result) {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()

        connectivityManager.requestNetwork(request, object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                connectivityManager.bindProcessToNetwork(network)
                Log.d("WiFiForceBinder", "✅ Connexion forcée au WiFi")
                result.success(true)
            }

            override fun onLost(network: Network) {
                Log.e("WiFiForceBinder", "❌ Perte de connexion au WiFi")
                result.success(false)
            }
        })
    }
}

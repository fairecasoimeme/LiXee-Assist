package com.lixee.assist

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class WiFiForceBinder(private val context: Context) : MethodChannel.MethodCallHandler {
    private var boundNetwork: Network? = null
    private var connectivityManager: ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "bindNetwork") {
            val ssid = call.argument<String>("ssid")
            if (ssid != null) {
                bindToNetwork(context,ssid,result)
            } else {
                result.error("NO_SSID", "SSID non fourni", null)
            }
        }else if (call.method == "unbindNetwork")
        {
            unbindNetwork(context,result)
        }else {
            result.notImplemented()
        }
    }

    private fun unbindNetwork(context: Context,result: MethodChannel.Result) {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        try {
            if (boundNetwork != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    connectivityManager!!.bindProcessToNetwork(null)
                } else {
                    ConnectivityManager.setProcessDefaultNetwork(null)
                }
                boundNetwork = null
                result.success(true)
            } else {
                result.success(false)
            }
        } catch (e: Exception) {
            result.error("UNBIND_ERROR", "Erreur pendant le débind", e.localizedMessage)
        }
    }

    private fun bindToNetwork(context: Context, ssid: String, result: MethodChannel.Result) {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()

        var hasResponded = false

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (!hasResponded) {
                    hasResponded = true
                    boundNetwork = network
                    connectivityManager.bindProcessToNetwork(network)
                    result.success(true)
                }
            }

            override fun onLost(network: Network) {
                if (!hasResponded) {
                    hasResponded = true
                    result.success(false)
                }
            }

            override fun onUnavailable() {
                if (!hasResponded) {
                    hasResponded = true
                    result.success(false)
                }
            }
        }

        connectivityManager.requestNetwork(request, callback)
    }

}


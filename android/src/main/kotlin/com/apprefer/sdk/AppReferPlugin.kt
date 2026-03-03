package com.apprefer.sdk

import android.content.Context
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class AppReferPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var adServicesChannel: MethodChannel
    private lateinit var referrerChannel: MethodChannel
    private var applicationContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext

        adServicesChannel = MethodChannel(binding.binaryMessenger, "com.apprefer.sdk/adservices")
        adServicesChannel.setMethodCallHandler(this)

        referrerChannel = MethodChannel(binding.binaryMessenger, "com.apprefer.sdk/install_referrer")
        referrerChannel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getAdServicesToken" -> {
                // AdServices is iOS only
                result.success(null)
            }
            "getInstallReferrer" -> {
                getInstallReferrer(result)
            }
            else -> result.notImplemented()
        }
    }

    private fun getInstallReferrer(result: Result) {
        val context = applicationContext
        if (context == null) {
            result.success(null)
            return
        }

        val referrerClient = InstallReferrerClient.newBuilder(context).build()

        referrerClient.startConnection(object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(responseCode: Int) {
                when (responseCode) {
                    InstallReferrerClient.InstallReferrerResponse.OK -> {
                        try {
                            val details = referrerClient.installReferrer
                            val referrerMap = hashMapOf<String, Any?>(
                                "installReferrer" to details.installReferrer,
                                "referrerClickTimestampSeconds" to details.referrerClickTimestampSeconds,
                                "installBeginTimestampSeconds" to details.installBeginTimestampSeconds,
                                "referrerClickTimestampServerSeconds" to details.referrerClickTimestampServerSeconds,
                                "installBeginTimestampServerSeconds" to details.installBeginTimestampServerSeconds,
                                "installVersion" to details.installVersion,
                                "googlePlayInstantParam" to details.googlePlayInstantParam,
                            )
                            result.success(referrerMap)
                        } catch (e: Exception) {
                            result.success(null)
                        } finally {
                            referrerClient.endConnection()
                        }
                    }
                    else -> {
                        result.success(null)
                        referrerClient.endConnection()
                    }
                }
            }

            override fun onInstallReferrerServiceDisconnected() {
                // No retry needed — one-shot read at first launch
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        adServicesChannel.setMethodCallHandler(null)
        referrerChannel.setMethodCallHandler(null)
        applicationContext = null
    }
}

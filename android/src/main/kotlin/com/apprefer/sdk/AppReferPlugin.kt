package com.apprefer.sdk

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import com.google.android.gms.ads.identifier.AdvertisingIdClient
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

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
            "getGaid" -> {
                getGaid(result)
            }
            else -> result.notImplemented()
        }
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun getGaid(result: Result) {
        val context = applicationContext
        if (context == null) {
            result.success(null)
            return
        }

        // Must be called off the main thread
        executor.execute {
            try {
                val adInfo = AdvertisingIdClient.getAdvertisingIdInfo(context)
                val gaid = if (adInfo.isLimitAdTrackingEnabled) null else adInfo.id
                mainHandler.post { result.success(gaid) }
            } catch (e: Exception) {
                mainHandler.post { result.success(null) }
            }
        }
    }

    private fun getInstallReferrer(result: Result) {
        val context = applicationContext
        if (context == null) {
            result.success(null)
            return
        }

        val handler = Handler(Looper.getMainLooper())
        val completed = AtomicBoolean(false)
        var retryCount = 0
        val maxRetries = 3
        val timeoutMs = 5000L
        val retryDelayMs = 1000L

        fun completeOnce(data: Map<String, Any?>?) {
            if (completed.compareAndSet(false, true)) {
                handler.post { result.success(data) }
            }
        }

        fun tryConnect() {
            val referrerClient = InstallReferrerClient.newBuilder(context).build()
            referrerClient.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    Log.d(TAG, "Install referrer response code: $responseCode (attempt ${retryCount + 1}/$maxRetries)")
                    when (responseCode) {
                        InstallReferrerClient.InstallReferrerResponse.OK -> {
                            try {
                                val details = referrerClient.installReferrer
                                completeOnce(mapOf(
                                    "installReferrer" to details.installReferrer,
                                    "referrerClickTimestampSeconds" to details.referrerClickTimestampSeconds,
                                    "installBeginTimestampSeconds" to details.installBeginTimestampSeconds,
                                    "referrerClickTimestampServerSeconds" to details.referrerClickTimestampServerSeconds,
                                    "installBeginTimestampServerSeconds" to details.installBeginTimestampServerSeconds,
                                    "installVersion" to details.installVersion,
                                    "googlePlayInstantParam" to details.googlePlayInstantParam,
                                ))
                            } catch (e: Exception) {
                                Log.e(TAG, "Failed to read referrer details", e)
                                completeOnce(null)
                            } finally {
                                try { referrerClient.endConnection() } catch (_: Exception) {}
                            }
                        }
                        InstallReferrerClient.InstallReferrerResponse.SERVICE_UNAVAILABLE,
                        InstallReferrerClient.InstallReferrerResponse.SERVICE_DISCONNECTED -> {
                            try { referrerClient.endConnection() } catch (_: Exception) {}
                            retryCount++
                            if (retryCount < maxRetries && !completed.get()) {
                                Log.d(TAG, "Retrying install referrer in ${retryDelayMs}ms (attempt ${retryCount + 1}/$maxRetries)")
                                handler.postDelayed({ tryConnect() }, retryDelayMs)
                            } else {
                                Log.w(TAG, "Install referrer exhausted $maxRetries retries, returning null")
                                completeOnce(null)
                            }
                        }
                        else -> {
                            Log.w(TAG, "Install referrer failed with response code: $responseCode")
                            try { referrerClient.endConnection() } catch (_: Exception) {}
                            completeOnce(null)
                        }
                    }
                }

                override fun onInstallReferrerServiceDisconnected() {
                    // Retry is handled by response code handler above
                }
            })
        }

        // Start first attempt
        tryConnect()

        // Timeout guard — ensure we always complete even if callback never fires
        handler.postDelayed({
            if (!completed.get()) {
                Log.w(TAG, "Install referrer timed out after ${timeoutMs}ms")
            }
            completeOnce(null)
        }, timeoutMs)
    }

    companion object {
        private const val TAG = "AppReferPlugin"
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        adServicesChannel.setMethodCallHandler(null)
        referrerChannel.setMethodCallHandler(null)
        applicationContext = null
    }
}

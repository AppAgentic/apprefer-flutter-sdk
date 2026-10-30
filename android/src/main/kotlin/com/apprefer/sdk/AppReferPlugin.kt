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

class AppReferPlugin : FlutterPlugin, MethodCallHandler, io.flutter.embedding.engine.plugins.activity.ActivityAware {
    private var support: SupportBridge? = null
    private var engagement: EngagementBridge? = null
    private var engagementChannel: MethodChannel? = null
    private var supportChannel: MethodChannel? = null
    private var activityBinding: io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding? = null
    override fun onAttachedToActivity(binding: io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding) {
        activityBinding = binding; support?.activity = binding.activity
        support?.let { binding.addActivityResultListener(it); binding.addRequestPermissionsResultListener(it) }
        engagement?.let { binding.addOnNewIntentListener(it); it.attach(binding.activity) }
    }
    override fun onDetachedFromActivity() {
        support?.let { activityBinding?.removeActivityResultListener(it); activityBinding?.removeRequestPermissionsResultListener(it) }
        engagement?.let { activityBinding?.removeOnNewIntentListener(it) }
        activityBinding = null; support?.detach()
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding) = onAttachedToActivity(binding)

    private lateinit var adServicesChannel: MethodChannel
    private lateinit var referrerChannel: MethodChannel
    private var applicationContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        support = SupportBridge(binding.applicationContext)
        supportChannel = MethodChannel(binding.binaryMessenger, "com.apprefer.sdk/support").also { it.setMethodCallHandler(support) }
        engagementChannel = MethodChannel(binding.binaryMessenger, "com.apprefer.sdk/engagement").also { channel ->
            engagement = EngagementBridge(binding.applicationContext, channel).also { channel.setMethodCallHandler(it) }
        }

        adServicesChannel = MethodChannel(binding.binaryMessenger, "com.apprefer.sdk/adservices")
        adServicesChannel.setMethodCallHandler(this)

        referrerChannel = MethodChannel(binding.binaryMessenger, "com.apprefer.sdk/install_referrer")
        referrerChannel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "billingAutomaticStateGet", "billingAutomaticStateSet" -> {
                try {
                    val context = applicationContext ?: throw java.io.IOException("Context unavailable")
                    if (android.os.Build.VERSION.SDK_INT >= 24 && context.isDeviceProtectedStorage) throw java.io.IOException("Credential-protected storage unavailable")
                    val directory = java.io.File(context.noBackupFilesDir, "apprefer-billing")
                    val file = android.util.AtomicFile(java.io.File(directory, "automatic-environments-v1.json"))
                    if (call.method == "billingAutomaticStateGet") {
                        if (!file.baseFile.exists() && !java.io.File(file.baseFile.path + ".bak").exists()) result.success(null)
                        else result.success(String(file.readFully(), Charsets.UTF_8))
                    } else {
                        val value = call.arguments as? String ?: throw java.io.IOException("Invalid billing state")
                        if (!directory.isDirectory && !directory.mkdirs()) throw java.io.IOException("Billing directory unavailable")
                        val output = file.startWrite()
                        try { output.write(value.toByteArray(Charsets.UTF_8)); file.finishWrite(output) }
                        catch (error: Exception) { file.failWrite(output); throw error }
                        result.success(null)
                    }
                } catch (_: Exception) { result.error("billing_storage", "Automatic billing state unavailable", null) }
            }
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
        // Track current client for cleanup on timeout
        var activeClient: InstallReferrerClient? = null
        // Track retry runnable for cancellation on timeout/completion
        var pendingRetryRunnable: Runnable? = null

        fun completeOnce(data: Map<String, Any?>?) {
            if (completed.compareAndSet(false, true)) {
                // Cancel any pending retry
                pendingRetryRunnable?.let { handler.removeCallbacks(it) }
                // Close active client if still connected
                try { activeClient?.endConnection() } catch (_: Exception) {}
                activeClient = null
                handler.post { result.success(data) }
            }
        }

        fun tryConnect() {
            if (completed.get()) return // Already completed (timeout or prior success)
            try {
                val referrerClient = InstallReferrerClient.newBuilder(context).build()
                activeClient = referrerClient
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
                                }
                            }
                            InstallReferrerClient.InstallReferrerResponse.SERVICE_UNAVAILABLE,
                            InstallReferrerClient.InstallReferrerResponse.SERVICE_DISCONNECTED -> {
                                try { referrerClient.endConnection() } catch (_: Exception) {}
                                activeClient = null
                                retryCount++
                                if (retryCount < maxRetries && !completed.get()) {
                                    Log.d(TAG, "Retrying install referrer in ${retryDelayMs}ms (attempt ${retryCount + 1}/$maxRetries)")
                                    val retryRunnable = Runnable { tryConnect() }
                                    pendingRetryRunnable = retryRunnable
                                    handler.postDelayed(retryRunnable, retryDelayMs)
                                } else {
                                    Log.w(TAG, "Install referrer exhausted $maxRetries retries, returning null")
                                    completeOnce(null)
                                }
                            }
                            else -> {
                                Log.w(TAG, "Install referrer failed with response code: $responseCode")
                                completeOnce(null)
                            }
                        }
                    }

                    override fun onInstallReferrerServiceDisconnected() {
                        // Service disconnected — retry if we have attempts left
                        Log.d(TAG, "Install referrer service disconnected")
                        try { referrerClient.endConnection() } catch (_: Exception) {}
                        activeClient = null
                        retryCount++
                        if (retryCount < maxRetries && !completed.get()) {
                            val retryRunnable = Runnable { tryConnect() }
                            pendingRetryRunnable = retryRunnable
                            handler.postDelayed(retryRunnable, retryDelayMs)
                        }
                        // If max retries exhausted, the timeout guard will complete
                    }
                })
            } catch (e: Exception) {
                // Client creation or startConnection threw synchronously
                // (e.g., Play Services missing, SecurityException)
                Log.e(TAG, "Install referrer client error", e)
                completeOnce(null)
            }
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
        supportChannel?.setMethodCallHandler(null)
        engagementChannel?.setMethodCallHandler(null)
        support?.detach()
        applicationContext = null
    }
}

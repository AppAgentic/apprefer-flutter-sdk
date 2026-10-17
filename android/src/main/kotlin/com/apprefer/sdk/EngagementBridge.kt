package com.apprefer.sdk

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.apprefer.flutter.engagement.EngagementRenderer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONObject
import java.security.KeyStore
import java.util.TimeZone
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Native side of `AppReferSDK.engagement` on Android: the install credential encrypted with an
 * Android Keystore key, and AppRefer's notifications rendered by the shared renderer
 * (`EngagementRenderer`, the same code the Android SDK ships). Taps reach the app's launch
 * activity; only nonces the renderer recorded are accepted. Outcomes wait in the renderer's
 * outbox until Dart drains them (`takeEvents`).
 */
internal class EngagementBridge(private val context: Context, private val channel: MethodChannel) : MethodChannel.MethodCallHandler, PluginRegistry.NewIntentListener {
    private val prefs = context.getSharedPreferences("apprefer_engagement_secure", Context.MODE_PRIVATE)
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun attach(activity: Activity) { handleIntent(activity.intent) }

    override fun onNewIntent(intent: Intent): Boolean = handleIntent(intent)

    private fun handleIntent(intent: Intent?): Boolean {
        val handled = EngagementRenderer.handleIntent(context, intent, System.currentTimeMillis())
        if (handled) main.post { channel.invokeMethod("eventsAvailable", null) }
        return handled
    }

    private fun key(): SecretKey {
        if (Build.VERSION.SDK_INT < 23) {
            // Android 5: an RSA Keystore key wraps a random AES key (as the Support bridge does).
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val alias = "apprefer_engagement_wrap"
            if (!store.containsAlias(alias)) {
                @Suppress("DEPRECATION")
                val spec = android.security.KeyPairGeneratorSpec.Builder(context).setAlias(alias)
                    .setSubject(javax.security.auth.x500.X500Principal("CN=AppRefer Engagement"))
                    .setSerialNumber(java.math.BigInteger.ONE).setStartDate(java.util.Date(0)).setEndDate(java.util.Date(4102444800000L)).build()
                java.security.KeyPairGenerator.getInstance("RSA", "AndroidKeyStore").apply { initialize(spec); generateKeyPair() }
            }
            val wrapped = prefs.getString("wrapped_aes", null)
            val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
            if (wrapped != null) {
                cipher.init(Cipher.DECRYPT_MODE, store.getKey(alias, null))
                return javax.crypto.spec.SecretKeySpec(cipher.doFinal(Base64.decode(wrapped, Base64.NO_WRAP)), "AES")
            }
            val raw = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
            cipher.init(Cipher.ENCRYPT_MODE, store.getCertificate(alias).publicKey)
            check(prefs.edit().putString("wrapped_aes", Base64.encodeToString(cipher.doFinal(raw), Base64.NO_WRAP)).commit())
            return javax.crypto.spec.SecretKeySpec(raw, "AES")
        }
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey("apprefer_engagement", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("apprefer_engagement", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "secureRead" -> {
                    val stored = prefs.getString(call.arguments as String, null)
                    if (stored == null) result.success(null) else {
                        val bytes = Base64.decode(stored, Base64.NO_WRAP)
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
                        result.success(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
                    }
                }
                "secureWrite" -> {
                    val name = call.argument<String>("key")!!; val value = call.argument<String>("value")
                    val edit = prefs.edit()
                    if (value == null) edit.remove(name) else {
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key())
                        edit.putString(name, Base64.encodeToString(cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP))
                    }
                    check(edit.commit()) { "Unable to save" }; result.success(null)
                }
                "configureNotifications" -> {
                    @Suppress("UNCHECKED_CAST") val labels = call.argument<Map<String, String>>("labels") ?: emptyMap()
                    @Suppress("UNCHECKED_CAST") val channels = call.argument<Map<String, String>>("channels") ?: emptyMap()
                    val hosts = call.argument<List<String>>("allowedImageHosts")?.toSet() ?: emptySet()
                    val icon = call.argument<String>("smallIcon")?.let { context.resources.getIdentifier(it, "drawable", context.packageName) } ?: 0
                    EngagementRenderer.configure(context, icon, hosts, labels, channels, null)
                    result.success(null)
                }
                "setIdentity" -> {
                    EngagementRenderer.setIdentity(context, call.argument<String>("installId"), call.argument<Int>("accountEpoch") ?: -1)
                    result.success(null)
                }
                "permission" -> result.success(EngagementRenderer.permission(context))
                "timezone" -> result.success(TimeZone.getDefault().id)
                "channelEnabled" -> result.success(EngagementRenderer.channelEnabled(context, call.arguments as String))
                "showNotification" -> {
                    @Suppress("UNCHECKED_CAST") val data = (call.arguments as Map<String, Any?>).mapValues { it.value?.toString() ?: "" }
                    // Off the main thread: the image download is bounded but blocking.
                    executor.execute {
                        val outcome = EngagementRenderer.handleMessage(context, data, System.currentTimeMillis(), 8000, 300_000)
                        main.post { result.success(outcome.name) }
                    }
                }
                "takeEvents" -> result.success(EngagementRenderer.takeEvents(context).map { toMap(it) })
                "clearForAccountChange" -> { EngagementRenderer.clearForAccountChange(context); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) { result.error("engagement_native", e.message, null) }
    }

    private fun toMap(o: JSONObject): Map<String, Any?> = o.keys().asSequence().associateWith { o.opt(it).takeUnless { v -> v == JSONObject.NULL } }
}

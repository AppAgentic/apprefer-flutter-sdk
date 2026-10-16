package com.apprefer.sdk

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.math.max
import kotlin.math.roundToInt

internal class SupportBridge(private val context: Context) : MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {
    var activity: Activity? = null
    private var pending: MethodChannel.Result? = null
    private var limit = 4
    private val prefs = context.getSharedPreferences("apprefer_support_secure", Context.MODE_PRIVATE)
    private fun key(): SecretKey {
        if (Build.VERSION.SDK_INT < 23) {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val alias = "apprefer_support_wrap"
            if (!store.containsAlias(alias)) {
                val start = java.util.Calendar.getInstance()
                val end = java.util.Calendar.getInstance().apply { add(java.util.Calendar.YEAR, 30) }
                @Suppress("DEPRECATION")
                val spec = android.security.KeyPairGeneratorSpec.Builder(context).setAlias(alias)
                    .setSubject(javax.security.auth.x500.X500Principal("CN=AppRefer Support"))
                    .setSerialNumber(java.math.BigInteger.ONE).setStartDate(start.time).setEndDate(end.time).build()
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
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("apprefer_support", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("apprefer_support", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when(call.method) {
                "keys" -> result.success(prefs.all.keys.toList())
                "read" -> {
                    val stored = prefs.getString(call.arguments as String, null)
                    if (stored == null) result.success(null) else {
                        val parts = stored.split(":")
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
                        result.success(String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8))
                    }
                }
                "write" -> {
                    val name = call.argument<String>("key")!!; val value = call.argument<String>("value")
                    val edit = prefs.edit()
                    if (value == null) edit.remove(name) else {
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key())
                        val encoded = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
                        edit.putString(name, Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(encoded, Base64.NO_WRAP))
                    }
                    check(edit.commit()) { "Unable to save support session" }; result.success(null)
                }
                "notificationChannel" -> {
                    // The channel name in the chat's language (sent by the Dart side since 0.10.0).
                    val name = (call.arguments as? String)?.takeIf { it.isNotBlank() } ?: "Support replies"
                    if (Build.VERSION.SDK_INT >= 26) (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(NotificationChannel("apprefer_support", name, NotificationManager.IMPORTANCE_DEFAULT))
                    result.success(null)
                }
                "openUrl" -> {
                    // Help article links: only http(s) and mailto, opened outside the app.
                    val url = call.arguments as? String
                    val scheme = url?.let { android.net.Uri.parse(it).scheme?.lowercase() }
                    if (url == null || scheme !in setOf("http", "https", "mailto")) result.success(false) else {
                        val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        result.success(runCatching { (activity ?: context).startActivity(intent) }.isSuccess)
                    }
                }
                "appIcon" -> {
                    // The launcher icon for the help home, full-bleed like iOS (the SDK rounds it).
                    val icon = context.packageManager.getApplicationIcon(context.packageName)
                    val size = 144
                    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                    val canvas = android.graphics.Canvas(bitmap)
                    if (Build.VERSION.SDK_INT >= 26 && icon is android.graphics.drawable.AdaptiveIconDrawable) {
                        // Layers are 108dp with the visible 72dp in the middle: draw them unmasked, cropped to it.
                        val bleed = size / 4
                        for (layer in listOfNotNull(icon.background, icon.foreground)) {
                            layer.setBounds(-bleed, -bleed, size + bleed, size + bleed)
                            layer.draw(canvas)
                        }
                    } else {
                        icon.setBounds(0, 0, size, size)
                        icon.draw(canvas)
                    }
                    val out = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                    bitmap.recycle()
                    result.success(out.toByteArray())
                }
                "pick" -> {
                    check(pending == null) { "Photo picker already open" }
                    val host = activity ?: error("No foreground activity")
                    limit = (call.arguments as? Int ?: 4).coerceIn(1,4)
                    val intent = if (Build.VERSION.SDK_INT >= 33) Intent("android.provider.action.PICK_IMAGES").apply { type = "image/*"; if (limit > 1) putExtra("android.provider.extra.PICK_IMAGES_MAX", limit) }
                    else Intent(Intent.ACTION_OPEN_DOCUMENT).apply { type = "image/*"; addCategory(Intent.CATEGORY_OPENABLE); putExtra(Intent.EXTRA_ALLOW_MULTIPLE, limit > 1) }
                    pending = result
                    try { host.startActivityForResult(intent, 51931) } catch (e: Exception) { pending = null; throw e }
                }
                else -> result.notImplemented()
            }
        } catch(e: Exception) { result.error("support_native", e.message, null) }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != 51931) return false
        val reply = pending ?: return true; pending = null
        if (resultCode != Activity.RESULT_OK) { reply.success(emptyList<ByteArray>()); return true }
        val uris = if (data?.clipData != null) (0 until data.clipData!!.itemCount).map { data.clipData!!.getItemAt(it).uri } else listOfNotNull(data?.data)
        Thread {
            try {
                val images = uris.take(limit).map { uri ->
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    context.contentResolver.openInputStream(uri).use { BitmapFactory.decodeStream(it, null, bounds) }
                    var sample = 1
                    while (max(bounds.outWidth,bounds.outHeight) / sample > 3200) sample *= 2
                    val bitmap = context.contentResolver.openInputStream(uri).use { BitmapFactory.decodeStream(it,null,BitmapFactory.Options().apply { inSampleSize = sample }) } ?: error("Unable to read image")
                    try {
                        val temp = java.io.File.createTempFile("support_exif", ".image", context.cacheDir)
                        val orientation = try {
                            context.contentResolver.openInputStream(uri).use { input -> temp.outputStream().use { output -> input?.copyTo(output) } }
                            @Suppress("DEPRECATION")
                            android.media.ExifInterface(temp.absolutePath).getAttributeInt("Orientation", 1)
                        } catch (_: Exception) { 1 } finally { temp.delete() }
                        val matrix = android.graphics.Matrix()
                        when (orientation) {
                            2 -> matrix.setScale(-1f,1f)
                            3 -> matrix.setRotate(180f)
                            4 -> matrix.setScale(1f,-1f)
                            5 -> { matrix.setRotate(90f); matrix.postScale(-1f,1f) }
                            6 -> matrix.setRotate(90f)
                            7 -> { matrix.setRotate(90f); matrix.postScale(1f,-1f) }
                            8 -> matrix.setRotate(270f)
                        }
                        val oriented = if (orientation in 2..8) Bitmap.createBitmap(bitmap,0,0,bitmap.width,bitmap.height,matrix,true) else bitmap
                        try { jpeg(oriented) } finally { if (oriented !== bitmap) oriented.recycle() }
                    } finally { bitmap.recycle() }
                }
                android.os.Handler(android.os.Looper.getMainLooper()).post { reply.success(images) }
            } catch(e: Exception) { android.os.Handler(android.os.Looper.getMainLooper()).post { reply.error("support_image",e.message,null) } }
        }.start()
        return true
    }
    fun detach() { pending?.error("activity_detached", "Photo selection interrupted. Try again.", null); pending = null; activity = null }
    companion object {
        fun jpeg(source: Bitmap): ByteArray {
            var scale = minOf(1.0, 1600.0 / max(source.width, source.height))
            while (true) {
                val resized = Bitmap.createScaledBitmap(source, max(1,(source.width*scale).roundToInt()), max(1,(source.height*scale).roundToInt()), true)
                try {
                    for (quality in listOf(80,65,50,35,20)) {
                        val out = ByteArrayOutputStream(); resized.compress(Bitmap.CompressFormat.JPEG,quality,out)
                        if (out.size() <= 700000) return out.toByteArray()
                    }
                } finally { if (resized !== source) resized.recycle() }
                scale *= 0.75
            }
        }
    }
}

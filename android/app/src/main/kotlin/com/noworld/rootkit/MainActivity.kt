package com.noworld.rootkit

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import moe.shizuku.server.IRemoteProcess
import moe.shizuku.server.IShizukuService
import rikka.shizuku.Shizuku
import java.io.ByteArrayOutputStream
import java.lang.Process
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {

    private val channelName = "rootkit/shizuku"
    private val pool = Executors.newCachedThreadPool()
    private var pendingPermissionResult: MethodChannel.Result? = null

    private val permissionListener =
        Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
            if (requestCode == 0) {
                val r = pendingPermissionResult
                pendingPermissionResult = null
                Handler(Looper.getMainLooper()).post {
                    r?.success(grantResult == PackageManager.PERMISSION_GRANTED)
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Shizuku.addRequestPermissionResultListener(permissionListener)
    }

    override fun onDestroy() {
        Shizuku.removeRequestPermissionResultListener(permissionListener)
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "check" -> result.success(
                        runCatching {
                            Shizuku.pingBinder() &&
                                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
                        }.getOrDefault(false)
                    )

                    "request" -> {
                        // 同一时刻只保留一个挂起请求；并用 10s 兜底，避免用户不点弹窗导致 Dart 永久挂起
                        pendingPermissionResult?.let { old ->
                            runCatching { old.success(false) }
                        }
                        pendingPermissionResult = result
                        Handler(Looper.getMainLooper()).postDelayed({
                            val r = pendingPermissionResult
                            if (r === result) {
                                pendingPermissionResult = null
                                runCatching { r?.success(false) }
                            }
                        }, 10000)
                        try {
                            Shizuku.requestPermission(0)
                        } catch (t: Throwable) {
                            pendingPermissionResult = null
                            result.success(false)
                        }
                    }

                    "run" -> {
                        val cmd = call.argument<String>("cmd") ?: ""
                        val stdin = call.argument<String>("stdin")
                        val timeoutMs = call.argument<Int>("timeoutMs") ?: 120000
                        pool.execute {
                            val out = runShell(cmd, stdin, timeoutMs)
                            Handler(Looper.getMainLooper()).post { result.success(out) }
                        }
                    }

                    "openUrl" -> {
                        val url = call.argument<String>("url") ?: ""
                        var ok = false
                        try {
                            val i = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(i)
                            ok = true
                        } catch (_: Throwable) {
                        }
                        result.success(ok)
                    }

                    "openApp" -> {
                        val pkg = call.argument<String>("pkg") ?: "me.weishu.kernelsu"
                        var ok = false
                        try {
                            val i = packageManager.getLaunchIntentForPackage(pkg)
                            if (i != null) {
                                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(i)
                                ok = true
                            }
                        } catch (_: Throwable) {
                        }
                        result.success(ok)
                    }

                    "filesDir" -> result.success(filesDir.absolutePath)

                    "saveImage" -> {
                        val assetPath = call.argument<String>("asset") ?: ""
                        val name = call.argument<String>("name") ?: "qrcode.png"
                        pool.execute {
                            val msg = saveImageToGallery(assetPath, name)
                            Handler(Looper.getMainLooper()).post { result.success(msg) }
                        }
                    }

                    "getPref" -> {
                        val k = call.argument<String>("key") ?: ""
                        result.success(
                            getSharedPreferences("rk", MODE_PRIVATE).getString(k, null)
                        )
                    }

                    "setPref" -> {
                        val k = call.argument<String>("key") ?: ""
                        val v = call.argument<String>("value") ?: ""
                        getSharedPreferences("rk", MODE_PRIVATE).edit().putString(k, v).apply()
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /** 把 APK assets 里的图片保存到系统相册（MediaStore，Android 10+ 无需存储权限） */
    private fun saveImageToGallery(assetPath: String, fileName: String): String {
        return try {
            // Flutter 的 asset 在 APK 内实际路径是 flutter_assets/<assetPath>
            val realPath = when {
                assetPath.startsWith("flutter_assets/") -> assetPath
                else -> "flutter_assets/$assetPath"
            }
            val src = try { assets.open(realPath) } catch (e: Throwable) { assets.open(assetPath) }
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, fileName)
                put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(android.provider.MediaStore.Images.Media.RELATIVE_PATH,
                    android.os.Environment.DIRECTORY_PICTURES + "/RootKit")
                put(android.provider.MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(
                android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: run { src.close(); return "insert fail" }
            contentResolver.openOutputStream(uri)?.use { out -> src.copyTo(out) }
            src.close()
            values.clear()
            values.put(android.provider.MediaStore.Images.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            "saved: Pictures/RootKit/$fileName"
        } catch (t: Throwable) {
            "save fail: $t"
        }
    }

    /**
     * 双接口自动适配：
     *  1) 官方 API：Shizuku.newProcess(...)（13.1.5 里是 private，反射调用）
     *  2) 直连 AIDL：IShizukuService.newProcess(...) → IRemoteProcess
     * 哪个成功用哪个，结果里带 via 字段。
     */
    private fun runShell(cmd: String, stdinB64: String?, timeoutMs: Int): MutableMap<String, Any> {
        val errors = StringBuilder()
        for (via in listOf("api", "aidl")) {
            try {
                val r = when (via) {
                    "api" -> runViaApi(cmd, stdinB64, timeoutMs)
                    else -> runViaAidl(cmd, stdinB64, timeoutMs)
                }
                r["via"] = via
                if (errors.isNotEmpty()) {
                    r["err"] = (r["err"] as String) + "\n(fallback: ${errors.trim()})"
                }
                return r
            } catch (t: Throwable) {
                val cause =
                    (t as? java.lang.reflect.InvocationTargetException)?.targetException ?: t
                errors.append("[$via] ${cause}\n")
            }
        }
        return hashMapOf(
            "code" to -1,
            "out" to "",
            "err" to "两种 Shizuku 接口都失败：\n$errors",
            "via" to "none"
        )
    }

    private fun runViaApi(cmd: String, stdinB64: String?, timeoutMs: Int): MutableMap<String, Any> {
        val m = Shizuku::class.java.getDeclaredMethod(
            "newProcess",
            Array<String>::class.java,
            Array<String>::class.java,
            String::class.java
        )
        m.isAccessible = true
        val p = m.invoke(null, arrayOf("sh", "-c", cmd), null, null) as Process
        return pumpProcess(p, stdinB64, timeoutMs)
    }

    private fun runViaAidl(cmd: String, stdinB64: String?, timeoutMs: Int): MutableMap<String, Any> {
        val binder = Shizuku.getBinder() ?: throw IllegalStateException("Shizuku 未运行")
        val svc = IShizukuService.Stub.asInterface(binder)
        val rp = svc.newProcess(arrayOf("sh", "-c", cmd), null, null)
        return pumpRemote(rp, stdinB64, timeoutMs)
    }

    private fun pumpProcess(p: Process, stdinB64: String?, timeoutMs: Int): MutableMap<String, Any> {
        val outBuf = ByteArrayOutputStream()
        val errBuf = ByteArrayOutputStream()
        val tOut = Thread {
            try {
                p.inputStream.use { it.copyTo(outBuf) }
            } catch (_: Throwable) {
            }
        }
        val tErr = Thread {
            try {
                p.errorStream.use { it.copyTo(errBuf) }
            } catch (_: Throwable) {
            }
        }
        val tIn = Thread {
            try {
                p.outputStream.use { os ->
                    if (stdinB64 != null) os.write(Base64.decode(stdinB64, Base64.DEFAULT))
                    os.flush()
                }
            } catch (_: Throwable) {
            }
        }
        tOut.start(); tErr.start(); tIn.start()

        var code = -1
        val latch = CountDownLatch(1)
        Thread {
            try {
                code = p.waitFor()
            } catch (_: Throwable) {
            }
            latch.countDown()
        }.start()

        val res = HashMap<String, Any>()
        if (!latch.await(timeoutMs.toLong(), TimeUnit.MILLISECONDS)) {
            runCatching { p.destroy() }
            res["code"] = -9
            res["err"] = "TIMEOUT after ${timeoutMs}ms"
        } else {
            res["code"] = code
            res["err"] = ""
        }
        tOut.join(3000); tErr.join(3000)
        res["out"] = outBuf.toString("UTF-8")
        res["err"] = (res["err"] as String) + errBuf.toString("UTF-8")
        return res
    }

    private fun pumpRemote(
        rp: IRemoteProcess,
        stdinB64: String?,
        timeoutMs: Int
    ): MutableMap<String, Any> {
        val outBuf = ByteArrayOutputStream()
        val errBuf = ByteArrayOutputStream()
        val tOut = Thread {
            try {
                ParcelFileDescriptor.AutoCloseInputStream(rp.inputStream).use { it.copyTo(outBuf) }
            } catch (_: Throwable) {
            }
        }
        val tErr = Thread {
            try {
                ParcelFileDescriptor.AutoCloseInputStream(rp.errorStream).use { it.copyTo(errBuf) }
            } catch (_: Throwable) {
            }
        }
        val tIn = Thread {
            try {
                ParcelFileDescriptor.AutoCloseOutputStream(rp.outputStream).use { os ->
                    if (stdinB64 != null) os.write(Base64.decode(stdinB64, Base64.DEFAULT))
                    os.flush()
                }
            } catch (_: Throwable) {
            }
        }
        tOut.start(); tErr.start(); tIn.start()

        var code = -1
        val done = CountDownLatch(1)
        Thread {
            try {
                if (!rp.waitForTimeout(timeoutMs.toLong(), "")) {
                    runCatching { rp.destroy() }
                    code = -9
                } else {
                    code = rp.exitValue()
                }
            } catch (t: Throwable) {
                try {
                    code = rp.waitFor()
                } catch (_: Throwable) {
                    code = -1
                }
            }
            done.countDown()
        }.start()

        val res = HashMap<String, Any>()
        if (!done.await(timeoutMs.toLong() + 5000, TimeUnit.MILLISECONDS)) {
            runCatching { rp.destroy() }
            res["code"] = -9
            res["err"] = "TIMEOUT(AIDL) after ${timeoutMs}ms"
        } else {
            res["code"] = code
            res["err"] = ""
        }
        tOut.join(3000); tErr.join(3000)
        res["out"] = outBuf.toString("UTF-8")
        res["err"] = (res["err"] as String) + errBuf.toString("UTF-8")
        return res
    }
}

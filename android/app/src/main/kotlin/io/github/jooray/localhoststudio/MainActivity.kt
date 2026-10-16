package io.github.jooray.localhoststudio

import android.Manifest
import android.app.ActivityManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.jooray.localhoststudio.jobs.GenerationService
import io.github.jooray.localhoststudio.jobs.SongStore
import io.github.jooray.localhoststudio.models.DownloadService
import io.github.jooray.localhoststudio.yue2.CpuInfo
import io.github.jooray.localhoststudio.yue2.Yue2Native
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.concurrent.thread

/**
 * Hosts the Flutter UI and the platform channels:
 * method channel "studio/native" (paths, jobs, downloads, sharing) and
 * event channel "studio/events" (job progress, job states, download progress).
 */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "studio/native").setMethodCallHandler(::onCall)
        EventChannel(messenger, "studio/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                Events.sink = events
            }

            override fun onCancel(arguments: Any?) {
                Events.sink = null
            }
        })
    }

    private val studioDir get() = GenerationService.dataDir(this)
    private val library get() = SongStore.libraryDir(studioDir)

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "paths" -> result.success(mapOf("data" to studioDir.absolutePath, "cache" to cacheDir.absolutePath))
                "deviceInfo" -> {
                    val mem = ActivityManager.MemoryInfo().also { getSystemService(ActivityManager::class.java).getMemoryInfo(it) }
                    result.success(mapOf(
                        "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
                        "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
                        "sdk" to Build.VERSION.SDK_INT,
                        "cpu" to CpuInfo.describe(),
                        "bigCores" to CpuInfo.bigCores.size,
                        "memoryBytes" to mem.totalMem,
                        "engine" to Yue2Native.systemInfo(),
                    ))
                }
                "enqueue" -> {
                    GenerationService.start(this)
                    result.success(true)
                }
                "cancel" -> {
                    GenerationService.cancel(this, call.argument<String>("id")!!, File(call.argument<String>("dir")!!))
                    result.success(true)
                }
                "status" -> result.success(mapOf("running" to GenerationService.current, "alive" to GenerationService.alive))
                "recover" -> {
                    // App start: a song left "running" without a live service was interrupted;
                    // queued songs start running again.
                    if (!GenerationService.alive) {
                        SongStore.markStale(library, null)
                        if (SongStore.queued(library).isNotEmpty()) GenerationService.start(this)
                    }
                    result.success(true)
                }
                "download" -> {
                    val files = JSONArray(call.argument<List<Map<String, Any?>>>("files")!!.map { JSONObject(it) })
                    DownloadService.start(this, call.argument<String>("dir")!!, files.toString())
                    result.success(true)
                }
                "cancelDownload" -> {
                    DownloadService.cancel(this)
                    result.success(true)
                }
                "modelFiles" -> {
                    val files = DownloadService.parse(JSONArray(call.argument<List<Map<String, Any?>>>("files")!!.map { JSONObject(it) }).toString())
                    result.success(DownloadService.status(this, File(call.argument<String>("dir")!!), files))
                }
                "deleteFile" -> result.success(File(call.argument<String>("path")!!).delete())
                "freeBytes" -> result.success(DownloadService.freeBytes(call.argument<String>("path") ?: studioDir.path))
                "share" -> {
                    val f = File(call.argument<String>("path")!!)
                    val uri = FileProvider.getUriForFile(this, "$packageName.files", f)
                    val send = Intent(Intent.ACTION_SEND)
                        .setType(call.argument<String>("mime") ?: "audio/mpeg")
                        .putExtra(Intent.EXTRA_STREAM, uri)
                        .putExtra(Intent.EXTRA_TITLE, call.argument<String>("title"))
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    startActivity(Intent.createChooser(send, call.argument<String>("title")))
                    result.success(true)
                }
                "convertAudio" -> {
                    val src = call.argument<String>("src")!!
                    val dst = call.argument<String>("dst")!!
                    thread(name = "studio-convert") {
                        val ok = runCatching { Yue2Native.convertToWav(src, dst) }.getOrDefault(false)
                        main.post { if (ok) result.success(dst) else result.error("convert", "Could not convert $src", null) }
                    }
                }
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("native", e.message ?: e.toString(), null)
        }
    }
}

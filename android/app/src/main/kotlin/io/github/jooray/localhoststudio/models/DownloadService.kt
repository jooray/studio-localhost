package io.github.jooray.localhoststudio.models

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import io.github.jooray.localhoststudio.Events
import io.github.jooray.localhoststudio.MainActivity
import io.github.jooray.localhoststudio.R
import io.github.jooray.localhoststudio.StudioApp
import org.json.JSONArray
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.concurrent.thread

/** One file of a model variant, as listed in the app's model registry. */
data class ModelFile(val name: String, val url: String, val bytes: Long, val sha256: String)

/**
 * Downloads model files (HTTP Range resume, retries) into a folder and verifies each SHA-256.
 * Model-agnostic: the app passes names, URLs, sizes and hashes from its registry.
 */
class DownloadService : Service() {
    @Volatile private var cancelled = false
    private var worker: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            cancelled = true
            return START_NOT_STICKY
        }
        if (worker?.isAlive == true) return START_NOT_STICKY
        val dir = File(intent?.getStringExtra(EXTRA_DIR) ?: return START_NOT_STICKY)
        val files = parse(intent.getStringExtra(EXTRA_FILES) ?: "[]")
        startForeground(NOTIF_ID, notification("Preparing…", 0, 0), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        cancelled = false
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "studio:download").apply { acquire(6 * 3600_000L) }
        @Suppress("DEPRECATION")
        wifiLock = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager)
            .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "studio:download").apply { acquire() }
        worker = thread(name = "studio-download") {
            var error: String? = null
            try {
                dir.mkdirs()
                for (m in files.distinctBy { it.name }) {
                    if (cancelled) break
                    download(dir, m)
                }
            } catch (e: Exception) {
                error = if (cancelled) null else (e.message ?: e.toString())
            }
            Events.send(mapOf(
                "type" to "download", "active" to false, "error" to error,
                "message" to when {
                    cancelled -> "Paused. The partial file is kept."
                    error == null -> "Done."
                    else -> null
                },
            ))
            wakeLock?.let { if (it.isHeld) it.release() }
            wifiLock?.let { if (it.isHeld) it.release() }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun download(dir: File, m: ModelFile) {
        val dest = File(dir, m.name)
        if (dest.exists() && dest.length() == m.bytes) {
            if (!isVerified(this, dest)) verify(m, dest)
            return
        }
        val part = File(dir, m.name + ".part")
        var attempt = 0
        while (!cancelled) {
            try {
                fetch(m, part)
                break
            } catch (e: IOException) {
                if (cancelled) return
                attempt++
                if (attempt > 8) throw IOException("${m.name}: ${e.message}", e)
                publish(m.name, "Network error, retrying ($attempt/8)", part.length(), m.bytes)
                SystemClock.sleep(3000L * attempt)
            }
        }
        if (cancelled) return
        if (part.length() != m.bytes) throw IOException("${m.name}: size ${part.length()} != ${m.bytes}")
        verify(m, part)
        if (!part.renameTo(dest)) throw IOException("Cannot move ${part.name} into place")
        markVerified(this, dest, true)
    }

    private fun verify(m: ModelFile, f: File) {
        publish(m.name, "Verifying", 0, m.bytes)
        val sum = sha256(f) { done -> publish(m.name, "Verifying", done, m.bytes) }
        if (sum != m.sha256) {
            f.delete()
            throw IOException("${m.name}: SHA-256 mismatch, the download was corrupted and has been deleted. Try again.")
        }
        markVerified(this, File(f.parentFile, m.name), true)
    }

    private fun fetch(m: ModelFile, part: File) {
        var have = if (part.exists()) part.length() else 0L
        if (have > m.bytes) {
            part.delete(); have = 0
        }
        if (have == m.bytes) return
        val conn = (URL(m.url).openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = true
            connectTimeout = 20_000
            readTimeout = 60_000
            setRequestProperty("User-Agent", "LocalhostRecordingStudio/0.3")
            if (have > 0) setRequestProperty("Range", "bytes=$have-")
        }
        try {
            val code = conn.responseCode
            val append = when (code) {
                206 -> true
                200 -> { have = 0; false }
                416 -> return
                else -> throw IOException("HTTP $code")
            }
            FileOutputStream(part, append).use { out ->
                conn.inputStream.use { inp ->
                    val buf = ByteArray(1 shl 18)
                    var lastT = SystemClock.elapsedRealtime()
                    var lastB = have
                    var done = have
                    publish(m.name, "Downloading", done, m.bytes)
                    while (!cancelled) {
                        val n = inp.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        done += n
                        val now = SystemClock.elapsedRealtime()
                        if (now - lastT >= 1000) {
                            val rate = (done - lastB) * 1000 / (now - lastT)
                            lastT = now; lastB = done
                            publish(m.name, "Downloading", done, m.bytes, rate)
                        }
                    }
                }
            }
        } finally {
            conn.disconnect()
        }
    }

    private var lastNotif = 0L
    private fun publish(file: String, phase: String, done: Long, total: Long, rate: Long = 0) {
        Events.send(mapOf("type" to "download", "active" to true, "file" to file, "phase" to phase,
            "done" to done, "total" to total, "rate" to rate))
        val now = SystemClock.elapsedRealtime()
        if (now - lastNotif > 1500) {
            lastNotif = now
            val pct = if (total > 0) (done * 100 / total).toInt() else 0
            getSystemService(android.app.NotificationManager::class.java).notify(NOTIF_ID, notification("$phase $file", pct, 100))
        }
    }

    private fun notification(text: String, progress: Int, max: Int): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val cancel = PendingIntent.getService(this, 1,
            Intent(this, DownloadService::class.java).setAction(ACTION_CANCEL), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, StudioApp.CHANNEL_DL)
            .setSmallIcon(R.drawable.ic_stat_studio)
            .setContentTitle("Model download")
            .setContentText(text)
            .setProgress(max, progress, max == 0)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Pause", cancel).build())
            .build()
    }

    companion object {
        private const val NOTIF_ID = 2
        const val ACTION_CANCEL = "cancel"
        const val EXTRA_DIR = "dir"
        const val EXTRA_FILES = "files"
        private const val PREFS = "models"

        fun parse(json: String): List<ModelFile> {
            val a = JSONArray(json)
            return (0 until a.length()).map { i ->
                val o = a.getJSONObject(i)
                ModelFile(o.getString("name"), o.getString("url"), o.getLong("bytes"), o.optString("sha256"))
            }
        }

        fun start(ctx: Context, dir: String, filesJson: String) {
            ctx.startForegroundService(Intent(ctx, DownloadService::class.java)
                .putExtra(EXTRA_DIR, dir).putExtra(EXTRA_FILES, filesJson))
        }

        fun cancel(ctx: Context) {
            ctx.startService(Intent(ctx, DownloadService::class.java).setAction(ACTION_CANCEL))
        }

        fun isVerified(ctx: Context, f: File) = ctx.getSharedPreferences(PREFS, 0).getBoolean("verified:" + f.absolutePath, false)

        fun markVerified(ctx: Context, f: File, ok: Boolean) {
            ctx.getSharedPreferences(PREFS, 0).edit().putBoolean("verified:" + f.absolutePath, ok).apply()
        }

        /** Status of each file for the setup screen. */
        fun status(ctx: Context, dir: File, files: List<ModelFile>): List<Map<String, Any>> = files.distinctBy { it.name }.map { m ->
            val f = File(dir, m.name)
            val part = File(dir, m.name + ".part")
            mapOf(
                "name" to m.name, "bytes" to m.bytes,
                "present" to (f.exists() && f.length() == m.bytes),
                "verified" to (f.exists() && isVerified(ctx, f)),
                "partBytes" to (if (part.exists()) part.length() else 0L),
            )
        }

        fun freeBytes(path: String): Long = runCatching {
            var d = File(path)
            while (!d.exists() && d.parentFile != null) d = d.parentFile!!
            StatFs(d.path).availableBytes
        }.getOrDefault(0L)

        fun sha256(f: File, onProgress: (Long) -> Unit = {}): String {
            val md = MessageDigest.getInstance("SHA-256")
            val buf = ByteArray(1 shl 20)
            var done = 0L
            FileInputStream(f).use { inp ->
                while (true) {
                    val n = inp.read(buf)
                    if (n < 0) break
                    md.update(buf, 0, n)
                    done += n
                    if (done and ((64L shl 20) - 1) < n) onProgress(done)
                }
            }
            return md.digest().joinToString("") { "%02x".format(it) }
        }
    }
}

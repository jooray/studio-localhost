package io.github.jooray.localhoststudio.jobs

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import io.github.jooray.localhoststudio.Events
import io.github.jooray.localhoststudio.MainActivity
import io.github.jooray.localhoststudio.R
import io.github.jooray.localhoststudio.StudioApp
import io.github.jooray.localhoststudio.yue2.CpuInfo
import io.github.jooray.localhoststudio.yue2.ProgressListener
import io.github.jooray.localhoststudio.yue2.Yue2Job
import io.github.jooray.localhoststudio.yue2.Yue2Native
import org.json.JSONObject
import java.io.File
import java.time.OffsetDateTime
import kotlin.concurrent.thread

/**
 * Runs the persistent queue: every song folder whose song.json says "queued", oldest queued_at
 * first, one at a time, in a foreground service with a partial wake lock. START_STICKY: if the
 * process is killed, Android restarts the service, the interrupted song is queued again and the
 * engine resumes from its checkpoints in song/work.
 */
class GenerationService : Service() {
    private var worker: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    private val library get() = SongStore.libraryDir(dataDir(this))

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            if (current != null) {
                cancelRequested = true
                Yue2Native.cancel()
            }
            return START_STICKY
        }
        try {
            startForeground(NOTIF_ID, notification("Starting…", 0, 0, ""), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } catch (e: Exception) {
            // A restart while the app is in the background may not start a foreground service:
            // leave the checkpoints for a resume from the library.
            SongStore.markStale(library, null)
            stopSelf()
            return START_NOT_STICKY
        }
        if (worker?.isAlive == true) return START_STICKY
        // Restarted after the process died: what was running continues first.
        library.listFiles().orEmpty().filter { it.isDirectory }.forEach { d ->
            val o = SongStore.read(d) ?: return@forEach
            if (o.optString("status") == "running") SongStore.update(d) { it.put("status", "queued"); it.put("resume", true) }
        }
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "studio:generate").apply { acquire(12 * 3600_000L) }
        worker = thread(name = "studio-generate") {
            Process.setThreadPriority(Process.THREAD_PRIORITY_DEFAULT)
            while (true) {
                val next = SongStore.queued(library).firstOrNull() ?: break
                runOne(next)
            }
            wakeLock?.let { if (it.isHeld) it.release() }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        return START_STICKY
    }

    private fun runOne(dir: File) {
        val song = SongStore.read(dir) ?: return
        val id = song.optString("id", dir.name)
        // "Run Towards The Sun · LRS-015": the user's (or derived) title, then the catalogue number.
        val number = song.optInt("catalogue", 0)
        val baseTitle = song.optString("title", dir.name)
        val title = if (number > 0) "$baseTitle · LRS-%03d".format(number) else baseTitle
        val previous = song.optJSONObject("timing")
        val previousTotal = previous?.optDouble("total_seconds", 0.0) ?: 0.0
        val stageSeconds = mutableMapOf<String, Double>()
        previous?.optJSONObject("stages")?.let { st -> st.keys().forEach { k -> stageSeconds[k] = st.optDouble(k) } }
        val started = SystemClock.elapsedRealtime()
        current = id
        cancelRequested = false
        SongStore.update(dir) {
            it.put("status", "running"); it.put("error", JSONObject.NULL)
            it.put("started_at", OffsetDateTime.now().toString())
        }
        Events.send(mapOf("type" to "job", "id" to id, "status" to "running"))

        var result = Yue2Native.RESULT_ERROR
        var error: String? = null
        val job = Yue2Job(dir, song)
        var stage = -1
        var stageStarted = started
        fun closeStage(now: Long) {
            if (stage >= 0) {
                val k = Yue2Native.stageKey(stage)
                stageSeconds[k] = (stageSeconds[k] ?: 0.0) + (now - stageStarted) / 1000.0
            }
        }
        try {
            if (!job.backbone.exists() || !job.vae.exists()) {
                error = "Model files are missing. Open Settings > Model setup."
            } else {
                val request = job.prepare()
                val cores = CpuInfo.bigCores.toIntArray()
                var lastEvent = 0L
                var lastNotif = 0L
                val listener = object : ProgressListener {
                    override fun onProgress(st: Int, cur: Int, total: Int) {
                        val now = SystemClock.elapsedRealtime()
                        val changed = st != stage
                        if (changed) {
                            closeStage(now)
                            stage = st
                            stageStarted = now
                        }
                        if (changed || now - lastEvent > 250) {
                            lastEvent = now
                            Events.send(mapOf(
                                "type" to "progress", "id" to id, "stage" to Yue2Native.stageKey(st),
                                "label" to Yue2Native.stageLabel(st), "done" to cur, "total" to total,
                                "unit" to Yue2Native.unit(st), "elapsed" to previousTotal + (now - started) / 1000.0,
                            ))
                        }
                        if (changed || now - lastNotif > 2000) {
                            lastNotif = now
                            val pct = if (total > 0) (cur * 100L / total).toInt() else 0
                            getSystemService(NotificationManager::class.java)
                                .notify(NOTIF_ID, notification(Yue2Native.stageLabel(st), pct, 100, "$title · $cur / $total"))
                        }
                    }
                }
                result = Yue2Native.generate(
                    job.work.absolutePath, job.backbone.absolutePath, job.vae.absolutePath, request,
                    cores.size, cores, job.maxSeq(), job.parentAudio, job.spliceAt, job.crossfade, listener,
                )
            }
        } catch (t: Throwable) {
            error = t.message ?: t.toString()
        }
        val now = SystemClock.elapsedRealtime()
        closeStage(now)
        val status = when {
            result == Yue2Native.RESULT_OK -> "done"
            result == Yue2Native.RESULT_CANCELLED || cancelRequested -> "cancelled"
            else -> "failed"
        }
        if (status == "failed" && error == null) {
            error = if (result == Yue2Native.RESULT_BUSY) "The engine is already running another song."
            else File(job.work, "engine.log").takeIf { it.exists() }?.readLines()
                ?.lastOrNull { "FATAL" in it || "error" in it.lowercase() } ?: "Engine error, see work/engine.log"
        }
        SongStore.update(dir) { o ->
            o.put("status", status)
            o.put("error", error ?: JSONObject.NULL)
            o.remove("resume")
            o.put("finished_at", OffsetDateTime.now().toString())
            if (status == "done") {
                runCatching { job.finish(o) }.onFailure { e ->
                    o.put("status", "failed"); o.put("error", "Could not save the result: ${e.message}")
                }
            }
            val stages = JSONObject()
            stageSeconds.forEach { (k, v) -> stages.put(k, Math.round(v * 100) / 100.0) }
            o.put("timing", JSONObject()
                .put("total_seconds", Math.round((previousTotal + (now - started) / 1000.0) * 100) / 100.0)
                .put("stages", stages))
        }
        val final = SongStore.read(dir)
        current = null
        Events.send(mapOf("type" to "job", "id" to id, "status" to (final?.optString("status") ?: status), "error" to error))
        notifyDone(title, final?.optString("status") ?: status, error, now - started)
    }

    private fun notifyDone(title: String, status: String, error: String?, elapsedMs: Long) {
        val text = when (status) {
            "done" -> "Finished in ${formatDuration(elapsedMs)}"
            "cancelled" -> "Cancelled; resume it from the library"
            else -> "Failed: ${error ?: "unknown error"}"
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        getSystemService(NotificationManager::class.java).notify(
            DONE_NOTIF_ID,
            Notification.Builder(this, StudioApp.CHANNEL_DONE)
                .setSmallIcon(R.drawable.ic_stat_studio)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(open)
                .setAutoCancel(true)
                .build(),
        )
    }

    private fun notification(title: String, progress: Int, max: Int, text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val cancel = PendingIntent.getService(this, 1,
            Intent(this, GenerationService::class.java).setAction(ACTION_CANCEL), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, StudioApp.CHANNEL_GEN)
            .setSmallIcon(R.drawable.ic_stat_studio)
            .setContentTitle(title)
            .setContentText(text)
            .setProgress(max, progress, max == 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Cancel", cancel).build())
            .build()
    }

    override fun onCreate() {
        super.onCreate()
        alive = true
    }

    override fun onDestroy() {
        alive = false
        super.onDestroy()
    }

    companion object {
        private const val NOTIF_ID = 1
        private const val DONE_NOTIF_ID = 3
        const val ACTION_CANCEL = "cancel"

        @Volatile var current: String? = null
        @Volatile var alive = false
        @Volatile var cancelRequested = false

        fun dataDir(ctx: Context): File = ctx.getExternalFilesDir(null) ?: ctx.filesDir

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, GenerationService::class.java))
        }

        /** Cancel the running song, or take a queued one out of the queue. */
        fun cancel(ctx: Context, id: String, dir: File) {
            if (current == id) {
                cancelRequested = true
                Yue2Native.cancel()
            } else {
                SongStore.update(dir) { if (it.optString("status") == "queued") it.put("status", "cancelled") }
                Events.send(mapOf("type" to "job", "id" to id, "status" to "cancelled"))
            }
        }

        fun formatDuration(ms: Long): String {
            val s = ms / 1000
            return if (s >= 3600) "%d h %02d min".format(s / 3600, (s % 3600) / 60)
            else if (s >= 60) "%d min %02d s".format(s / 60, s % 60) else "$s s"
        }
    }
}

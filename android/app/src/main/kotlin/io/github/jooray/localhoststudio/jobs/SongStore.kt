package io.github.jooray.localhoststudio.jobs

import org.json.JSONObject
import java.io.File

/**
 * song.json access for the service: the same file the app writes (format
 * "studio-localhost/song"). Updates are read-modify-write so fields the service does not know
 * survive. The app's library folder holds one folder per song.
 */
object SongStore {
    const val FORMAT = "studio-localhost/song"

    fun read(dir: File): JSONObject? = runCatching {
        JSONObject(File(dir, "song.json").readText()).takeIf { it.optString("format") == FORMAT }
    }.getOrNull()

    @Synchronized
    fun update(dir: File, change: (JSONObject) -> Unit): JSONObject? {
        val o = read(dir) ?: return null
        change(o)
        val tmp = File(dir, "song.json.tmp")
        tmp.writeText(o.toString(2))
        tmp.renameTo(File(dir, "song.json"))
        return o
    }

    /** Queued songs in the library, oldest queued_at first. */
    fun queued(library: File): List<File> = library.listFiles().orEmpty()
        .filter { it.isDirectory }
        .mapNotNull { d -> read(d)?.takeIf { it.optString("status") == "queued" }?.let { d to it.optString("queued_at") } }
        .sortedBy { it.second }
        .map { it.first }

    /** Songs left "running" by a process that died become "interrupted" (resumable). */
    fun markStale(library: File, activeId: String?) {
        library.listFiles().orEmpty().filter { it.isDirectory }.forEach { d ->
            val o = read(d) ?: return@forEach
            if (o.optString("status") == "running" && o.optString("id") != activeId) {
                update(d) { it.put("status", "interrupted"); it.put("error", "Stopped before it finished; resume to continue.") }
            }
        }
    }

    fun libraryDir(dataDir: File) = File(dataDir, "library").apply { mkdirs() }
}

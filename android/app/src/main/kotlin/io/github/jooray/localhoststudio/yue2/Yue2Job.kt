package io.github.jooray.localhoststudio.yue2

import android.media.MediaMetadataRetriever
import org.json.JSONObject
import java.io.File
import kotlin.math.roundToInt

/**
 * The YuE2 adapter for one song folder: turns song.json into a yue2.cpp request (mirroring the
 * desktop sidecar's request shaping and extend semantics), and after the engine ran, writes the
 * shared layout: audio.mp3, render.mp3 (extend), tokens.csv (whole timeline), score.abc.
 * The engine itself works in song/work, where its checkpoints live (score.abc,
 * tokens.partial.csv, tokens.csv), so a stopped job resumes where it was.
 */
class Yue2Job(val dir: File, private val song: JSONObject) {
    val work = File(dir, "work").apply { mkdirs() }
    private val params = song.optJSONObject("params") ?: JSONObject()
    private val extend = song.optJSONObject("extend") ?: JSONObject()
    private val cover = song.optJSONObject("cover") ?: JSONObject()
    val kind: String = song.optString("kind", "generate")
    private val files = song.optJSONObject("model")?.optJSONObject("files") ?: JSONObject()
    val backbone = File(files.optString("backbone"))
    val vae = File(files.optString("vae"))
    val sourceDir: File? = song.optString("source_dir").takeIf { it.isNotEmpty() && !song.isNull("source_dir") }?.let(::File)

    /** A cover: the recording (copied into the song folder) and the transcriber that hears it. */
    val coverSource: File? = cover.optString("source_audio").takeIf { it.isNotEmpty() }?.let { File(dir, it) }
    val transcriber: File? = cover.optString("transcriber").takeIf { it.isNotEmpty() }?.let(::File)
    val coverScore = File(work, "cover.abc")
    val coverMelodyOnly: Boolean get() = params.optString("mode") == "melody"

    /** The cover still has to listen to its recording (no transcribed score yet). */
    val needsTranscription: Boolean get() = kind == "cover" && coverScore.readTextOrNull().isNullOrBlank()

    var durationS = 0.0
    var sectionStartFrames = 0
    var parentAudio: String? = null
    var spliceAt = 0.0
    val crossfade: Double = extend.optDouble("crossfade", 2.0)

    /** Build the request JSON and stage source checkpoints. */
    fun prepare(): String {
        val shaped = shape()
        val req = JSONObject()
        req.put("style", shaped.style)
        req.put("lyrics", shaped.lyrics)
        req.put("cot", shaped.cot)
        if (shaped.abc != null) req.put("abc", shaped.abc)
        val seed = params.optLong("seed", 0)
        req.put("lm_seed", seed)
        req.put("seed", seed)
        req.put("steps", params.optInt("steps", 32))
        req.put("output_format", "mp3")
        req.put("mp3_bitrate", 192)
        when (kind) {
            "rerender" -> {
                val src = sourceDir ?: error("re-render without a source song")
                val tokens = File(work, "tokens.csv")
                if (!tokens.exists()) File(src, "tokens.csv").copyTo(tokens)
                val score = File(src, "score.abc")
                if (score.exists() && !File(work, "score.abc").exists()) score.copyTo(File(work, "score.abc"))
                durationS = countTokens(tokens.readText()) / FRAME_RATE.toDouble()
                if (params.optBoolean("refine", false)) {
                    // Refine the source's finished mix: its latents, pulled back to t and solved from there
                    val latents = File(File(src, "work"), "latents.f32")
                    require(latents.exists()) { "The source song has no saved mix to refine" }
                    if (!File(work, "refine.f32").exists()) latents.copyTo(File(work, "refine.f32"))
                    File(work, "refine.json").writeText(JSONObject().put("t", params.optDouble("refine_t", 0.25)).toString())
                }
            }
            "extend" -> {
                val src = sourceDir ?: error("extend without a source song")
                val staged = File(work, "source_tokens.csv")
                if (!staged.exists()) File(src, "tokens.csv").copyTo(staged)
                val sourceTokens = staged.readText().trim()
                val n = countTokens(sourceTokens)
                val a = (extend.optDouble("section_start", 0.0) * FRAME_RATE).roundToInt().coerceIn(0, n)
                val endS = if (extend.isNull("section_end")) -1.0 else extend.optDouble("section_end", -1.0)
                val b = if (endS < 0) n else (endS * FRAME_RATE).roundToInt().coerceIn(0, n)
                require(b > a) { "Empty source section" }
                sectionStartFrames = a
                req.put("source_tokens", sourceTokens)
                req.put("source_start", a / FRAME_RATE.toDouble())
                req.put("source_end", if (b == n) -1.0 else b / FRAME_RATE.toDouble())
                val section = (b - a) / FRAME_RATE.toDouble()
                durationS = if (extend.isNull("add_seconds") || !extend.has("add_seconds")) MAX_SECONDS
                else minOf(MAX_SECONDS, section + extend.optDouble("add_seconds", 30.0))
                if (shaped.cot != "off" && params.optBoolean("reuse_score", true)) {
                    File(src, "score.abc").takeIf { it.exists() }?.let { req.put("abc", it.readText()) }
                }
                if (a > 0) {
                    parentAudio = audioOf(src)?.absolutePath
                    spliceAt = a / FRAME_RATE.toDouble()
                }
            }
            else -> {
                durationS = if (params.has("max_seconds") && !params.isNull("max_seconds")) params.optDouble("max_seconds") else MAX_SECONDS
            }
        }
        req.put("duration", durationS)
        return req.toString()
    }

    /** KV cache: prefix + score (up to 4096) + 2 x frames for the flow-matching chunk. */
    fun maxSeq(): Int {
        val frames = (durationS * FRAME_RATE).toInt()
        val textTokens = params.optString("style").length + params.optString("lyrics").length + 256
        return (((4096 + textTokens + 2 * frames + 64) + 1023) / 1024 * 1024).coerceIn(8192, 24576)
    }

    /** After a successful run: the shared layout and the result fields for song.json. */
    fun finish(o: JSONObject) {
        val render = File(work, "song_full.mp3")
        val mp3 = File(work, "song.mp3")
        File(dir, "audio.mp3").delete()
        mp3.renameTo(File(dir, "audio.mp3"))
        val spliced = render.exists()
        if (spliced) {
            File(dir, "render.mp3").delete()
            render.renameTo(File(dir, "render.mp3"))
        }
        val renderTokens = File(work, "tokens.csv").readText().trim()
        val renderFrames = countTokens(renderTokens)
        val timeline = if (kind == "extend" && sectionStartFrames > 0) {
            val src = File(work, "source_tokens.csv").readText().trim().split(",").filter { it.isNotBlank() }
            (src.take(sectionStartFrames).joinToString(",") + "," + renderTokens)
        } else renderTokens
        File(dir, "tokens.csv.tmp").apply { writeText(timeline) }.renameTo(File(dir, "tokens.csv"))
        (File(work, "score.abc").takeIf { it.exists() } ?: coverScore.takeIf { it.exists() })
            ?.let { it.copyTo(File(dir, "score.abc"), overwrite = true) }
        o.put("audio", "audio.mp3")
        o.put("render", if (spliced) "render.mp3" else JSONObject.NULL)
        o.put("audio_seconds", audioSeconds(File(dir, "audio.mp3")))
        o.put("token_frames", countTokens(timeline))
        val requested = (durationS * FRAME_RATE).toInt()
        o.put("truncated", JSONObject().put("abc", false).put("semantic", kind != "rerender" && renderFrames >= requested - 1))
        if (kind == "extend") {
            val section = (if (extend.isNull("section_end")) -1.0 else extend.optDouble("section_end", -1.0))
            val srcFrames = countTokens(File(work, "source_tokens.csv").readText())
            val b = if (section < 0) srcFrames else (section * FRAME_RATE).roundToInt()
            o.put("section", JSONObject()
                .put("start_frame", sectionStartFrames).put("end_frame", b)
                .put("start_seconds", sectionStartFrames / FRAME_RATE.toDouble()).put("end_seconds", b / FRAME_RATE.toDouble())
                .put("source_frames", srcFrames).put("new_frames", maxOf(0, renderFrames - (b - sectionStartFrames)))
                .put("add_seconds", if (extend.isNull("add_seconds")) JSONObject.NULL else extend.opt("add_seconds")))
            o.put("seam", JSONObject()
                .put("used", if (spliced) "splice" else "render")
                .put("seam_sample", if (spliced) sectionStartFrames * SAMPLES_PER_FRAME else 0)
                .put("crossfade_samples", if (spliced) (crossfade * SAMPLE_RATE).toInt() else 0))
        }
    }

    private data class Shaped(val style: String, val lyrics: String, val cot: String, val abc: String?)

    /** Same rules as the desktop sidecar (studio_engine/yue2/prompt.py: shape_request). */
    private fun shape(): Shaped {
        var style = params.optString("style").trim()
        var lyrics = params.optString("lyrics")
        var mode = params.optString("mode", "full").ifEmpty { "full" }
        var abc: String? = params.optString("abc").takeIf { it.isNotBlank() && !params.isNull("abc") }
        if (kind == "cover") {
            // The recording's score, sung with the cover's words (never instrumental, never off)
            abc = coverScore.readTextOrNull()?.takeIf { it.isNotBlank() } ?: error("The cover has no transcribed score")
            if (mode != "melody") mode = "full"
            return Shaped(style, lyrics, mode, abc)
        }
        if (params.optBoolean("instrumental")) {
            style = instrumentalStyle(style)
            mode = "off"
            abc = null
            if (lyrics.isBlank()) lyrics = "[Intro]\n\n[Verse]\n\n[Chorus]\n\n[Outro]\n"
        }
        if (mode == "off") abc = null
        return Shaped(style, lyrics, mode, abc)
    }

    private fun instrumentalStyle(s0: String): String {
        var style = s0.ifEmpty { "Instrumental music" }
        if (!style.lowercase().contains("instrumental")) style = "Instrumental, " + style.trimStart('.', ',', ' ')
        for (cue in listOf("no vocals", "no singing")) {
            if (!style.lowercase().contains(cue)) style = style.trimEnd('.', ',', ' ') + ", $cue"
        }
        return style.trimEnd('.', ',', ' ') + "."
    }

    companion object {
        const val FRAME_RATE = 25
        const val SAMPLE_RATE = 48000
        const val SAMPLES_PER_FRAME = SAMPLE_RATE / FRAME_RATE
        const val MAX_SECONDS = 360.0

        private fun File.readTextOrNull(): String? = if (exists()) readText() else null

        fun countTokens(csv: String): Int = csv.split(",", "\n").count { it.isNotBlank() }

        fun audioOf(dir: File): File? {
            val meta = runCatching { JSONObject(File(dir, "song.json").readText()).optString("audio") }.getOrNull()
            return listOfNotNull(meta?.takeIf { it.isNotEmpty() }, "audio.mp3", "audio.wav", "audio.flac")
                .map { File(dir, it) }.firstOrNull { it.exists() }
        }

        fun audioSeconds(f: File): Double = runCatching {
            val r = MediaMetadataRetriever()
            r.setDataSource(f.absolutePath)
            val ms = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0
            r.release()
            ms / 1000.0
        }.getOrDefault(0.0)
    }
}

package io.github.jooray.localhoststudio.yue2

/** Called by the native side from the generating thread. */
interface ProgressListener {
    fun onProgress(stage: Int, current: Int, total: Int)
}

/** yue2.cpp through JNI (yue2_jni.cpp). */
object Yue2Native {
    const val STAGE_LOAD = 0
    const val STAGE_SCORE = 1
    const val STAGE_SEMANTIC = 2
    const val STAGE_NAR = 3
    const val STAGE_VAE = 4
    const val STAGE_WRITE = 5
    const val STAGE_LISTEN = 6

    const val RESULT_OK = 0
    const val RESULT_CANCELLED = 1
    const val RESULT_ERROR = -1
    const val RESULT_BUSY = -2

    init {
        System.loadLibrary("yue2jni")
    }

    /**
     * Runs one song synchronously; resumes from the checkpoints in [jobDir].
     * @param cores CPU ids to pin the engine threads to (empty = no pinning)
     * @param maxSeq KV cache size in tokens, 0 = the model context (24576)
     */
    @JvmStatic external fun generate(
        jobDir: String,
        modelPath: String,
        vaePath: String,
        requestJson: String,
        nThreads: Int,
        cores: IntArray,
        maxSeq: Int,
        parentAudio: String?,
        spliceAt: Double,
        crossfade: Double,
        listener: ProgressListener?,
    ): Int

    /**
     * A cover's first step: the score the transcriber hears in [audioPath], written to
     * [jobDir]/cover.abc. [transcriberPath] is the SheetSage2 GGUF, MERT beside it.
     */
    @JvmStatic external fun transcribe(
        jobDir: String,
        transcriberPath: String,
        audioPath: String,
        melodyOnly: Boolean,
        nThreads: Int,
        cores: IntArray,
        listener: ProgressListener?,
    ): Int

    @JvmStatic external fun cancel()
    @JvmStatic external fun lastLogLine(): String
    @JvmStatic external fun systemInfo(): String
    @JvmStatic external fun convertToWav(src: String, dst: String): Boolean

    /** The app's stage names (shared with the desktop engines). */
    fun stageKey(stage: Int): String = when (stage) {
        STAGE_LOAD -> "load"
        STAGE_LISTEN -> "listen"
        STAGE_SCORE -> "plan"
        STAGE_SEMANTIC -> "semantic"
        STAGE_NAR -> "nar"
        STAGE_VAE -> "vae"
        else -> "post"
    }

    fun stageLabel(stage: Int): String = when (stage) {
        STAGE_LOAD -> "Loading model"
        STAGE_LISTEN -> "Listening"
        STAGE_SCORE -> "Planning score"
        STAGE_SEMANTIC -> "Generating song"
        STAGE_NAR -> "Synthesizing audio"
        STAGE_VAE -> "Decoding audio"
        else -> "Saving"
    }

    fun unit(stage: Int): String = when (stage) {
        STAGE_SCORE, STAGE_SEMANTIC -> "tokens"
        STAGE_NAR -> "steps"
        STAGE_VAE -> "tiles"
        else -> ""
    }
}

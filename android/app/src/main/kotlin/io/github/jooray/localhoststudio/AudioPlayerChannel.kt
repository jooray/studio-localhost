package io.github.jooray.localhoststudio

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Song playback on Android: one Media3 ExoPlayer (pure Java/Kotlin, no native libraries).
 * Replaces media_kit/libmpv here, whose memfd_create + dlopen GrapheneOS reports as dynamic
 * code loading via memory.
 *
 * Method channel "studio/player": open(path), play, pause, stop, seek(ms), volume(v).
 * Event channel "studio/player/events": {playing, position, duration, completed, error?}
 * (milliseconds), sent on every change and every 200 ms while playing.
 */
class AudioPlayerChannel(private val context: Context, messenger: BinaryMessenger) {
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var player: ExoPlayer? = null
    private var completed = false
    private var error: String? = null

    private val tick = object : Runnable {
        override fun run() {
            send()
            if (player?.isPlaying == true) main.postDelayed(this, 200)
        }
    }

    init {
        MethodChannel(messenger, "studio/player").setMethodCallHandler(::onCall)
        EventChannel(messenger, "studio/player/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                send()
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    private fun exo(): ExoPlayer = player ?: ExoPlayer.Builder(context).build().also { p ->
        p.setAudioAttributes(
            AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
            true,
        )
        p.setHandleAudioBecomingNoisy(true)
        p.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                main.removeCallbacks(tick)
                if (isPlaying) main.post(tick) else send()
            }

            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_ENDED) {
                    completed = true
                    p.playWhenReady = false
                }
                send()
            }

            override fun onPlayerError(e: PlaybackException) {
                error = e.message ?: e.errorCodeName
                send()
            }
        })
        player = p
    }

    private fun send() {
        val p = player
        val duration = p?.duration?.takeIf { it != C.TIME_UNSET } ?: 0L
        sink?.success(mapOf(
            "playing" to (p?.isPlaying == true || (p?.playWhenReady == true && p.playbackState == Player.STATE_BUFFERING)),
            "position" to (p?.currentPosition ?: 0L),
            "duration" to duration,
            "completed" to completed,
            "error" to error,
        ))
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "open" -> {
                    val p = exo()
                    completed = false
                    error = null
                    p.setMediaItem(MediaItem.fromUri(Uri.fromFile(File(call.argument<String>("path")!!))))
                    p.prepare()
                    p.playWhenReady = true
                }
                "play" -> {
                    val p = exo()
                    if (completed || p.playbackState == Player.STATE_ENDED) p.seekTo(0)
                    completed = false
                    if (p.playbackState == Player.STATE_IDLE) p.prepare()
                    p.playWhenReady = true
                }
                "pause" -> player?.pause()
                "stop" -> {
                    player?.stop()
                    player?.clearMediaItems()
                    completed = false
                }
                "seek" -> {
                    completed = false
                    player?.seekTo((call.argument<Number>("ms") ?: 0).toLong())
                }
                "volume" -> player?.volume = (call.argument<Number>("v") ?: 1.0).toFloat()
                "dispose" -> release()
                else -> {
                    result.notImplemented()
                    return
                }
            }
            send()
            result.success(true)
        } catch (e: Exception) {
            result.error("player", e.message, null)
        }
    }

    fun release() {
        main.removeCallbacks(tick)
        player?.release()
        player = null
    }
}

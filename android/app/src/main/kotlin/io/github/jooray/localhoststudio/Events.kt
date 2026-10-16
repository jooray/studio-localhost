package io.github.jooray.localhoststudio

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Events to Dart (EventChannel "studio/events"); dropped while no Flutter UI is listening. */
object Events {
    private val main = Handler(Looper.getMainLooper())
    @Volatile var sink: EventChannel.EventSink? = null

    fun send(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }
}

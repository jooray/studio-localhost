package io.github.jooray.localhoststudio

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager

class StudioApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL_GEN, "Music generation", NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(NotificationChannel(CHANNEL_DL, "Model downloads", NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(NotificationChannel(CHANNEL_DONE, "Finished songs", NotificationManager.IMPORTANCE_DEFAULT))
    }

    companion object {
        const val CHANNEL_GEN = "generation"
        const val CHANNEL_DL = "downloads"
        const val CHANNEL_DONE = "done"
    }
}

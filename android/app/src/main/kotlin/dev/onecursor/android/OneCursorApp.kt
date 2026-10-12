package dev.onecursor.android

import android.app.Application
import android.content.Context

class OneCursorApp : Application() {
    lateinit var settings: Settings
        private set
    lateinit var controller: ClientController
        private set

    override fun onCreate() {
        super.onCreate()
        settings = Settings(this)
        controller = ClientController(settings)
    }

    companion object {
        fun of(context: Context) = context.applicationContext as OneCursorApp
    }
}

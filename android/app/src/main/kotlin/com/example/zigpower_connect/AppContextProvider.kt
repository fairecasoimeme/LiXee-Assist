package com.example.zigpower_connect

import android.app.Application
import android.content.Context

class AppContextProvider : Application() {
    init {
        instance = this
    }

    companion object {
        private lateinit var instance: AppContextProvider

        val context: Context
            get() = instance.applicationContext
    }
}

package com.xsh.notibridge

import android.app.Application
import com.xsh.notibridge.core.Forwarder
import com.xsh.notibridge.data.AppStore
import com.xsh.notibridge.data.Records

class NotiApp : Application() {
    lateinit var store: AppStore
        private set
    lateinit var records: Records
        private set
    val forwarder: Forwarder by lazy { Forwarder(store) }

    override fun onCreate() {
        super.onCreate()
        instance = this
        store = AppStore(this)
        records = Records(this)
    }

    companion object {
        lateinit var instance: NotiApp
            private set
    }
}

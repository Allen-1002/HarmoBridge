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
        // 1.1.0：协议 v2，清除旧配对（只做一次）
        store.migratePairingSchema(store.ui.getBoolean("onboarded", false))
        records = Records(this)
    }

    companion object {
        lateinit var instance: NotiApp
            private set
    }
}

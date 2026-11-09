package com.xsh.notibridge.core

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * 手机上改了同步开关或打开 App 时，临时连一次每台已配对电脑交换设置后断开。
 * 从某台电脑拿到更新后再推一轮，让其他电脑也拿到（与鸿蒙 SettingsSync.ets 一致）。
 */
object SettingsSync {
    fun run(backend: PhoneBackend, relay: Boolean = true, onDone: ((Boolean) -> Unit)? = null) {
        val list = backend.pairedComputers()
        if (list.isEmpty()) {
            onDone?.invoke(false)
            return
        }
        val remaining = AtomicInteger(list.size)
        val changed = AtomicBoolean(false)
        list.forEach { m ->
            runOne(backend, m) { c ->
                if (c) changed.set(true)
                if (remaining.decrementAndGet() > 0) return@runOne
                if (changed.get() && relay && list.size > 1) run(backend, false, null)
                onDone?.invoke(changed.get())
            }
        }
    }

    private fun runOne(backend: PhoneBackend, mac: Computer, onDone: (Boolean) -> Unit) {
        val changed = AtomicBoolean(false)
        val finished = AtomicBoolean(false)
        var link: ComputerLink? = null
        val finish = {
            if (finished.compareAndSet(false, true)) {
                link?.dispose()
                onDone(changed.get())
            }
        }
        val l = ComputerLink(backend, object : LinkListener {
            override fun onState(state: LinkState, detail: String) {
                if (state == LinkState.ONLINE) link?.later(1500) { finish() }
                else if (state == LinkState.ERROR) finish()
            }

            override fun onSettingsChanged() = changed.set(true)
        }, foreground = false, target = mac)
        link = l
        l.later(15_000) { finish() }
        l.connect()
    }
}

package com.xsh.notibridge.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.xsh.notibridge.NotiApp
import com.xsh.notibridge.core.PendingUnpair
import com.xsh.notibridge.core.SettingsSync
import com.xsh.notibridge.service.NotifyListener

class MainActivity : ComponentActivity() {
    private var resumeTick by mutableIntStateOf(0)
    private var onboarding by mutableStateOf(false)
    private var onboardingStart by mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        onboarding = !UiPrefs.onboarded
        setContent {
            NotiTheme {
                if (onboarding) {
                    OnboardingScreen(resumeTick, onboardingStart) { onboarding = false }
                } else {
                    MainScreen(resumeTick,
                        onRerunOnboarding = { onboardingStart = 0; onboarding = true; UiPrefs.onboarded = false },
                        onContinueSetup = { onboardingStart = firstUnfinishedStep(); onboarding = true })
                }
            }
        }
    }

    /** 引导里第一个还没完成的必需步骤：1 = 通知使用权，3 = 连接电脑 */
    private fun firstUnfinishedStep(): Int = when {
        !NotifyListener.isGranted(this) -> 1
        NotiApp.instance.store.pairedComputers().isEmpty() -> 3
        else -> 2
    }

    override fun onResume() {
        super.onResume()
        resumeTick++
        val store = NotiApp.instance.store
        // 打开 App 时：交换一次同步设置、通知已删除的电脑取消配对；监听没在运行时请求重新绑定
        SettingsSync.run(store)
        PendingUnpair.flush(store)
        if (NotifyListener.isGranted(this) && !NotifyListener.connected) NotifyListener.requestRebind(this)
    }
}

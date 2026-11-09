package com.xsh.notibridge.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

val Accent = Color(0xFF3D6BF5)
val AccentEnd = Color(0xFF7B5CF0)
val Success = Color(0xFF1E9E5A)
val Warning = Color(0xFFD98A00)
val Danger = Color(0xFFD93A3A)

@Composable
fun NotiTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val ctx = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= 31 && dark -> dynamicDarkColorScheme(ctx).copy(primary = Color(0xFF8AA6FF))
        Build.VERSION.SDK_INT >= 31 -> dynamicLightColorScheme(ctx).copy(primary = Accent)
        dark -> darkColorScheme(primary = Color(0xFF8AA6FF))
        else -> lightColorScheme(primary = Accent)
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

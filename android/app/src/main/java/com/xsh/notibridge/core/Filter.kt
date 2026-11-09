package com.xsh.notibridge.core

/** 手机端过滤，与鸿蒙 PhoneFilter.ets、Mac SyncFilter 默认关键词一致。 */
object Filter {
    val SENSITIVE = listOf(
        "验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "otp", "verification code",
        "银行", "信用卡", "余额", "转账", "支付", "付款", "收款",
    )

    private val OTP_KEYWORDS = listOf("验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "激活码", "otp", "code")

    /** 空字符串 = 允许转发，否则为拦截原因。 */
    fun blockReason(s: SyncSettings, bundle: String, title: String, text: String): String {
        if (s.paused) return "同步已暂停"
        if (bundle in s.blockedBundles) return "应用已屏蔽"
        if (s.blockSensitive) {
            val hay = "$title\n$text".lowercase()
            if (SENSITIVE.any { hay.contains(it) }) return "疑似敏感内容"
        }
        return ""
    }

    /** 提取 4~8 位数字验证码：取离关键词最近（40 字符内）的一个；没有返回空字符串。 */
    fun extractOtp(title: String, text: String): String {
        val content = "$title $text"
        val lower = content.lowercase()
        val keyPos = mutableListOf<Int>()
        for (k in OTP_KEYWORDS) {
            var i = lower.indexOf(k)
            while (i >= 0) {
                keyPos.add(i)
                i = lower.indexOf(k, i + k.length)
            }
        }
        if (keyPos.isEmpty()) return ""
        var best = ""
        var bestDist = Int.MAX_VALUE
        Regex("(?<![0-9])([0-9]{4,8})(?![0-9])").findAll(content).forEach { m ->
            val start = m.range.first
            for (k in keyPos) {
                val d = kotlin.math.abs(start - k)
                if (d <= 40 && d < bestDist) {
                    bestDist = d
                    best = m.groupValues[1]
                }
            }
        }
        return best
    }
}

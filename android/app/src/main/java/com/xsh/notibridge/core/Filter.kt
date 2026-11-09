package com.xsh.notibridge.core

/** 手机端过滤，与鸿蒙 PhoneFilter.ets、Mac SyncFilter 默认关键词一致。 */
object Filter {
    val SENSITIVE = listOf(
        "验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "otp", "verification code",
        "银行", "信用卡", "余额", "转账", "支付", "付款", "收款",
    )

    private val OTP_KEYWORDS = listOf("验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "激活码", "otp", "code")

    /** 银行 / 支付类内容：这类验证码默认不同步（除非用户明确允许） */
    val FINANCE = listOf("银行", "信用卡", "余额", "转账", "支付", "付款", "收款", "还款", "贷款", "bank", "payment")

    /** 包名里带这些词的视为银行 / 支付类应用 */
    val FINANCE_APP_HINTS = listOf("bank", "alipay", "wallet", "pay", "finance", "securities", "stock", "icbc", "ccb", "cmb", "abchina", "boc")

    enum class Action { FORWARD, OTP, DROP }

    /** 一条通知的处理结果。record=false 表示连元数据都不记录（敏感内容）。 */
    data class Decision(val action: Action, val reason: String, val otp: String = "", val record: Boolean = true)

    fun isFinance(bundle: String, title: String, text: String): Boolean {
        val hay = "$title\n$text".lowercase()
        val b = bundle.lowercase()
        return FINANCE.any { hay.contains(it) } || FINANCE_APP_HINTS.any { b.contains(it) }
    }

    /**
     * 手机端处理顺序（v1.1.0 起）：暂停 → 按应用屏蔽（通知和验证码都不发）→ 验证码同步（独立开关；
     * 开启敏感过滤时，银行/支付类验证码默认不发）→ 敏感内容过滤 → 转发。
     */
    fun decide(s: SyncSettings, bundle: String, title: String, text: String): Decision {
        if (s.paused) return Decision(Action.DROP, "同步已暂停")
        if (bundle in s.blockedBundles) return Decision(Action.DROP, "应用已屏蔽")
        val otp = if (s.copyOtp) extractOtp(title, text) else ""
        if (otp.isNotEmpty()) {
            val finance = s.blockSensitive && isFinance(bundle, title, text)
            return if (finance && !s.allowSensitiveOtp) {
                Decision(Action.DROP, "银行/支付类验证码未同步", record = false)
            } else {
                Decision(Action.OTP, "验证码已发送", otp)
            }
        }
        val reason = blockReason(s, bundle, title, text)
        if (reason.isNotEmpty()) return Decision(Action.DROP, reason, record = reason != "疑似敏感内容")
        return Decision(Action.FORWARD, "已转发")
    }

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

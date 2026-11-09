package com.xsh.notibridge.core

/** 协议层需要的本机存储与平台能力。Android 实现见 data/AppStore；单元测试里用内存实现。 */
interface PhoneBackend {
    val deviceId: String
    val deviceName: String

    fun findComputer(macId: String): Computer?
    fun keyFor(macId: String): ByteArray?
    fun saveComputer(c: Computer, key: ByteArray)
    /** 电脑上取消了配对：删除本机记录（不再通知电脑） */
    fun forgetComputer(macId: String)
    fun addUnpairNotice(name: String)
    fun pairedComputers(): List<Computer>

    // v1.2 待通知电脑取消配对
    fun pendingUnpairs(): List<Computer> = emptyList()
    fun pendingKey(macId: String): ByteArray? = null
    fun clearPendingUnpair(macId: String) {}
    /** 什么时候在手机上删除的（毫秒，0 = 未知），用来决定何时放弃通知 */
    fun pendingSince(macId: String): Long = 0

    fun loadSettings(): SyncSettings
    /** 写入（保留 s.updatedAt） */
    fun writeSettings(s: SyncSettings)

    /** 连不上已配对电脑时按电脑 ID 在局域网重新查找，地址变化则保存并回调 true。 */
    fun rediscover(c: Computer, done: (Boolean) -> Unit) = done(false)

    fun log(ok: Boolean, msg: String) {}
}

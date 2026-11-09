package com.xsh.notibridge.data

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import com.xsh.notibridge.core.BridgeCrypto
import com.xsh.notibridge.core.Computer
import com.xsh.notibridge.core.PhoneBackend
import com.xsh.notibridge.core.SyncSettings
import org.json.JSONArray
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 本机存储：非敏感字段放 SharedPreferences；每台电脑的配对密钥用 Android Keystore 里的 AES 主密钥加密后保存
 * （主密钥不可导出，卸载 App 后随之删除）。与鸿蒙端 PairingStore / PhoneFilter 的数据结构一致。
 */
class AppStore(private val ctx: Context) : PhoneBackend {
    private val pairing: SharedPreferences = ctx.getSharedPreferences("notibridge_pairing", Context.MODE_PRIVATE)
    private val sync: SharedPreferences = ctx.getSharedPreferences("notibridge_sync", Context.MODE_PRIVATE)
    val ui: SharedPreferences = ctx.getSharedPreferences("notibridge_ui", Context.MODE_PRIVATE)

    /** 界面监听数据变化（配对列表、设置）用 */
    val listeners = mutableSetOf<() -> Unit>()
    private fun changed() = listeners.toList().forEach { runCatching { it() } }

    override val deviceId: String
        get() = synchronized(this) {
            var id = pairing.getString("deviceId", "") ?: ""
            if (id.isEmpty()) {
                id = UUID.randomUUID().toString()
                pairing.edit().putString("deviceId", id).commit()
            }
            id
        }

    override val deviceName: String
        get() {
            val n = runCatching { Settings.Global.getString(ctx.contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull()
            if (!n.isNullOrBlank()) return n
            val brand = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
            return if (Build.MODEL.startsWith(brand, true)) Build.MODEL else "$brand ${Build.MODEL}"
        }

    // ---------- 密钥（Keystore 包装） ----------

    private fun masterKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(MASTER_ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(MASTER_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun wrap(raw: ByteArray): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, masterKey())
        return BridgeCrypto.b64(c.iv + c.doFinal(raw))
    }

    private fun unwrap(s: String?): ByteArray? {
        if (s.isNullOrEmpty()) return null
        return try {
            val all = BridgeCrypto.fromB64(s)
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, masterKey(), GCMParameterSpec(128, all, 0, 12))
            c.doFinal(all, 12, all.size - 12)
        } catch (e: Exception) {
            Log.w(TAG, "unwrap key failed: ${e.javaClass.simpleName}")
            null
        }
    }

    // ---------- 已配对电脑 ----------

    private fun readList(key: String) = Computer.listFromJson(pairing.getString(key, ""))

    override fun keyFor(macId: String): ByteArray? = unwrap(pairing.getString(KEY_PREFIX + macId, null))

    @Synchronized
    override fun pairedComputers(): List<Computer> = readList(LIST_KEY).filter { pairing.contains(KEY_PREFIX + it.macId) }

    override fun findComputer(macId: String): Computer? = pairedComputers().firstOrNull { it.macId == macId }

    @Synchronized
    override fun saveComputer(c: Computer, key: ByteArray) {
        clearPendingUnpairNoNotify(c.macId)
        val list = readList(LIST_KEY).filter { it.macId != c.macId } + c
        pairing.edit().putString(KEY_PREFIX + c.macId, wrap(key)).putString(LIST_KEY, Computer.listToJson(list)).commit()
        changed()
    }

    @Synchronized
    fun updateAddress(macId: String, host: String, port: Int): Boolean {
        val list = readList(LIST_KEY)
        val m = list.firstOrNull { it.macId == macId } ?: return false
        if (m.host == host && m.port == port) return false
        m.host = host
        m.port = port
        pairing.edit().putString(LIST_KEY, Computer.listToJson(list)).commit()
        log(true, "电脑 ${macId.take(8)} 地址已更新为 $host:$port")
        changed()
        return true
    }

    override fun forgetComputer(macId: String) = forget(macId, notifyLater = false)

    /** notifyLater=true：用户在手机上删除，密钥转存到待通知列表，之后通知电脑也取消配对。 */
    @Synchronized
    fun forget(macId: String, notifyLater: Boolean) {
        val list = readList(LIST_KEY)
        val e = pairing.edit()
        if (notifyLater) {
            val m = list.firstOrNull { it.macId == macId }
            val wrapped = pairing.getString(KEY_PREFIX + macId, null)
            if (m != null && wrapped != null) {
                val pending = readList(PENDING_KEY).filter { it.macId != macId } + m
                e.putString(PENDING_PREFIX + macId, wrapped).putString(PENDING_KEY, Computer.listToJson(pending))
            }
        }
        e.remove(KEY_PREFIX + macId).putString(LIST_KEY, Computer.listToJson(list.filter { it.macId != macId })).commit()
        log(true, "已删除配对 notifyLater=$notifyLater")
        changed()
    }

    @Synchronized
    override fun pendingUnpairs(): List<Computer> = readList(PENDING_KEY).filter { pairing.contains(PENDING_PREFIX + it.macId) }

    override fun pendingKey(macId: String): ByteArray? = unwrap(pairing.getString(PENDING_PREFIX + macId, null))

    @Synchronized
    override fun clearPendingUnpair(macId: String) = clearPendingUnpairNoNotify(macId)

    private fun clearPendingUnpairNoNotify(macId: String) {
        val pending = readList(PENDING_KEY)
        pairing.edit().remove(PENDING_PREFIX + macId)
            .putString(PENDING_KEY, Computer.listToJson(pending.filter { it.macId != macId })).commit()
    }

    @Synchronized
    fun updatePendingAddress(macId: String, host: String, port: Int) {
        val pending = readList(PENDING_KEY)
        val m = pending.firstOrNull { it.macId == macId } ?: return
        if (m.host == host && m.port == port) return
        m.host = host
        m.port = port
        pairing.edit().putString(PENDING_KEY, Computer.listToJson(pending)).commit()
    }

    @Synchronized
    override fun addUnpairNotice(name: String) {
        val l = noticeList()
        if (name !in l) l.add(name)
        pairing.edit().putString(NOTICE_KEY, JSONArray(l).toString()).commit()
        changed()
    }

    @Synchronized
    fun takeUnpairNotices(): List<String> {
        val l = noticeList()
        pairing.edit().remove(NOTICE_KEY).commit()
        return l
    }

    private fun noticeList(): MutableList<String> = try {
        val a = JSONArray(pairing.getString(NOTICE_KEY, "[]"))
        MutableList(a.length()) { a.getString(it) }
    } catch (e: Exception) {
        mutableListOf()
    }

    // ---------- 同步设置 ----------

    override fun loadSettings(): SyncSettings = SyncSettings(
        paused = sync.getBoolean("paused", false),
        blockSensitive = sync.getBoolean("blockSensitive", true),
        copyOtp = sync.getBoolean("copyOtp", true),
        blockedBundles = (sync.getStringSet("blockedBundles", emptySet()) ?: emptySet()).toMutableSet(),
        updatedAt = sync.getLong("updatedAt", 0),
    )

    /** 本机修改：刷新修改时间 */
    fun saveSettings(s: SyncSettings) {
        s.updatedAt = System.currentTimeMillis()
        writeSettings(s)
    }

    override fun writeSettings(s: SyncSettings) {
        sync.edit().putBoolean("paused", s.paused).putBoolean("blockSensitive", s.blockSensitive)
            .putBoolean("copyOtp", s.copyOtp).putStringSet("blockedBundles", s.blockedBundles.toSet())
            .putLong("updatedAt", s.updatedAt).commit()
        changed()
    }

    // ---------- 平台能力 ----------

    override fun rediscover(c: Computer, done: (Boolean) -> Unit) = Discovery.rediscover(ctx, this, c, done)

    override fun log(ok: Boolean, msg: String) {
        if (ok) Log.i(TAG, msg) else Log.w(TAG, msg)
        LogBuffer.add(ok, msg)
    }

    /** 清除所有数据：配对密钥、设置、记录、Keystore 主密钥。 */
    fun clearAll() {
        pairing.edit().clear().commit()
        sync.edit().clear().commit()
        ui.edit().clear().commit()
        runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(MASTER_ALIAS) }
        changed()
    }

    companion object {
        const val TAG = "NotiBridge"
        private const val MASTER_ALIAS = "notibridge.master"
        private const val LIST_KEY = "computers"
        private const val KEY_PREFIX = "key."
        private const val PENDING_KEY = "pendingUnpair"
        private const val PENDING_PREFIX = "unpairkey."
        private const val NOTICE_KEY = "unpairNotices"
    }
}

/** 最近的诊断日志（内存，最多 400 行），调试页显示。 */
object LogBuffer {
    data class Line(val time: Long, val ok: Boolean, val msg: String)

    private val lines = ArrayDeque<Line>()

    @Synchronized
    fun add(ok: Boolean, msg: String) {
        lines.addLast(Line(System.currentTimeMillis(), ok, msg))
        while (lines.size > 400) lines.removeFirst()
    }

    @Synchronized
    fun snapshot(): List<Line> = lines.toList()

    @Synchronized
    fun clear() = lines.clear()
}

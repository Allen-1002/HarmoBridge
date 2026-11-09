package com.xsh.notibridge.core

import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 与 docs/protocol.md “密码学约定”逐项一致（Mac BridgeCrypto.swift、Windows BridgeCrypto.cs、鸿蒙 Crypto.ets）。
 * 只用 JDK 自带的 SHA-256 / HMAC / AES-GCM；X25519 按 RFC 7748 实现（Android 8 起都能用，不依赖系统是否提供 XDH）。
 */
object BridgeCrypto {
    private const val AAD = "HB1"
    const val PAIR_INFO_PREFIX = "HarmoBridge-pair-v1|"
    private val rng = SecureRandom()

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { rng.nextBytes(it) }

    fun b64(b: ByteArray): String = Base64.getEncoder().encodeToString(b)
    fun fromB64(s: String): ByteArray = Base64.getDecoder().decode(s)

    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    fun fromHex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it.toInt() and 0xff) }

    // ---------- X25519（RFC 7748） ----------

    private val P: BigInteger = BigInteger.valueOf(2).pow(255).subtract(BigInteger.valueOf(19))
    private val A24: BigInteger = BigInteger.valueOf(121665)

    class KeyPair(val priv: ByteArray, val pub: ByteArray)

    fun generateX25519(): KeyPair {
        val priv = randomBytes(32)
        return KeyPair(priv, x25519(priv, basePoint()))
    }

    fun publicFromPrivate(priv: ByteArray): ByteArray = x25519(priv, basePoint())

    private fun basePoint(): ByteArray = ByteArray(32).also { it[0] = 9 }

    private fun decodeLE(b: ByteArray): BigInteger = BigInteger(1, b.reversedArray())

    private fun encodeLE(x: BigInteger): ByteArray {
        val be = x.toByteArray()
        val out = ByteArray(32)
        // BigInteger.toByteArray 是大端、可能带符号位前导 0
        for (i in 0 until minOf(32, be.size)) {
            out[i] = be[be.size - 1 - i]
        }
        return out
    }

    /** X25519(k, u)。 */
    fun x25519(scalar: ByteArray, uBytes: ByteArray): ByteArray {
        require(scalar.size == 32 && uBytes.size == 32) { "bad key length" }
        val k = scalar.copyOf()
        k[0] = (k[0].toInt() and 248).toByte()
        k[31] = ((k[31].toInt() and 127) or 64).toByte()
        val kn = decodeLE(k)
        val u = uBytes.copyOf()
        u[31] = (u[31].toInt() and 127).toByte()
        val x1 = decodeLE(u).mod(P)
        var x2 = BigInteger.ONE
        var z2 = BigInteger.ZERO
        var x3 = x1
        var z3 = BigInteger.ONE
        var swap = 0
        for (t in 254 downTo 0) {
            val kt = if (kn.testBit(t)) 1 else 0
            swap = swap xor kt
            if (swap == 1) {
                var tmp = x2; x2 = x3; x3 = tmp
                tmp = z2; z2 = z3; z3 = tmp
            }
            swap = kt
            val a = x2.add(z2).mod(P)
            val aa = a.multiply(a).mod(P)
            val b = x2.subtract(z2).mod(P)
            val bb = b.multiply(b).mod(P)
            val e = aa.subtract(bb).mod(P)
            val c = x3.add(z3).mod(P)
            val d = x3.subtract(z3).mod(P)
            val da = d.multiply(a).mod(P)
            val cb = c.multiply(b).mod(P)
            x3 = da.add(cb).mod(P).pow(2).mod(P)
            z3 = x1.multiply(da.subtract(cb).mod(P).pow(2)).mod(P)
            x2 = aa.multiply(bb).mod(P)
            z2 = e.multiply(aa.add(A24.multiply(e))).mod(P)
        }
        if (swap == 1) {
            x2 = x3
            z2 = z3
        }
        val r = x2.multiply(z2.modPow(P.subtract(BigInteger.valueOf(2)), P)).mod(P)
        val out = encodeLE(r)
        require(out.any { it.toInt() != 0 }) { "low-order point" }
        return out
    }

    // ---------- HKDF-SHA256（RFC 5869） ----------

    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, len: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = java.io.ByteArrayOutputStream()
        var t = ByteArray(0)
        var i = 1
        while (out.size() < len) {
            mac.update(t)
            mac.update(info)
            mac.update(i.toByte())
            t = mac.doFinal()
            out.write(t)
            i++
        }
        return out.toByteArray().copyOf(len)
    }

    /** 配对密钥：HKDF(X25519 共享密钥, SHA-256(phonePub‖macPub), "HarmoBridge-pair-v1|"+PIN)。 */
    fun derivePairKey(priv: ByteArray, phonePub: ByteArray, macPub: ByteArray, pin: String): ByteArray {
        val shared = x25519(priv, macPub)
        val salt = sha256(phonePub + macPub)
        return hkdfSha256(shared, salt, (PAIR_INFO_PREFIX + pin).toByteArray(Charsets.UTF_8), 32)
    }

    /** 校验码：salt 前 3 字节大写十六进制。 */
    fun sas(phonePub: ByteArray, macPub: ByteArray): String =
        hex(sha256(phonePub + macPub).copyOf(3)).uppercase()

    // ---------- AES-256-GCM ----------

    fun seal(key: ByteArray, plaintext: String): String {
        val iv = randomBytes(12)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        c.updateAAD(AAD.toByteArray(Charsets.UTF_8))
        return b64(iv + c.doFinal(plaintext.toByteArray(Charsets.UTF_8)))
    }

    fun open(key: ByteArray, box: String): String {
        val all = fromB64(box)
        require(all.size > 28) { "box too short" }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, all, 0, 12))
        c.updateAAD(AAD.toByteArray(Charsets.UTF_8))
        return String(c.doFinal(all, 12, all.size - 12), Charsets.UTF_8)
    }
}

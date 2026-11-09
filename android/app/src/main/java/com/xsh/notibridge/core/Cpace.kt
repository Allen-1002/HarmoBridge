package com.xsh.notibridge.core

import org.bouncycastle.math.ec.rfc7748.X25519
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.MessageDigest

/**
 * CPace（draft-irtf-cfrg-cpace-21，CPACE-X25519-SHA512）中 NotiBridge 用到的部分，
 * 与 Mac Cpace.swift、Windows Cpace.cs、鸿蒙 Cpace.ets 逐项一致（docs/test-vectors/pairing-v2.json）。
 * Elligator2 用 java.math.BigInteger；X25519 用 BouncyCastle 的常量时间实现。
 */
object Cpace {
    val DSI = "CPace255".toByteArray(Charsets.UTF_8)
    private const val S_IN_BYTES = 128
    private val P: BigInteger = BigInteger.ONE.shiftLeft(255).subtract(BigInteger.valueOf(19))
    private val A: BigInteger = BigInteger.valueOf(486662)
    private val TWO: BigInteger = BigInteger.valueOf(2)

    class LowOrderPoint : Exception("low-order point")

    fun prependLen(data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        var len = data.size
        do {
            out.write(if (len < 128) len else (len and 0x7f) + 0x80)
            len = len shr 7
        } while (len != 0)
        out.write(data)
        return out.toByteArray()
    }

    fun lvCat(vararg items: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        items.forEach { out.write(prependLen(it)) }
        return out.toByteArray()
    }

    fun generatorString(prs: ByteArray, ci: ByteArray, sid: ByteArray): ByteArray {
        val zpad = maxOf(0, S_IN_BYTES - 1 - prependLen(prs).size - prependLen(DSI).size)
        return lvCat(DSI, prs, ByteArray(zpad), ci, sid)
    }

    private fun decodeLe(b: ByteArray) = BigInteger(1, b.reversedArray())

    private fun encodeLe(x: BigInteger): ByteArray {
        val be = x.mod(P).toByteArray()
        val out = ByteArray(32)
        for (i in 0 until minOf(32, be.size)) out[i] = be[be.size - 1 - i]
        return out
    }

    /** Elligator2（草案附录 A.5）：v = -A/(1+2r²)，ε = legendre(v³+Av²+v)，x = εv − (1−ε)A/2。 */
    internal fun elligator2(r: BigInteger): BigInteger {
        val v = A.negate().multiply(BigInteger.ONE.add(TWO.multiply(r).multiply(r)).mod(P).modPow(P.subtract(TWO), P)).mod(P)
        val gx = v.pow(3).add(A.multiply(v).multiply(v)).add(v).mod(P)
        val eps = gx.modPow(P.subtract(BigInteger.ONE).shiftRight(1), P)
        val halfA = A.multiply(TWO.modPow(P.subtract(TWO), P)).mod(P)
        return eps.multiply(v).subtract(BigInteger.ONE.subtract(eps).multiply(halfA)).mod(P)
    }

    /** 生成元 g（32 字节小端 u 坐标）。 */
    fun generator(prs: ByteArray, ci: ByteArray, sid: ByteArray): ByteArray {
        val hash = MessageDigest.getInstance("SHA-512").digest(generatorString(prs, ci, sid)).copyOf(32)
        hash[31] = (hash[31].toInt() and 0x7f).toByte()
        return encodeLe(elligator2(decodeLe(hash)))
    }

    /** X25519(scalar, point)；结果全 0（低阶点）时抛 LowOrderPoint。 */
    fun scalarMultVfy(scalar: ByteArray, point: ByteArray): ByteArray {
        require(scalar.size == 32 && point.size == 32) { "bad point length" }
        val r = ByteArray(32)
        if (!X25519.calculateAgreement(scalar, 0, point, 0, r, 0)) throw LowOrderPoint()
        return r
    }
}

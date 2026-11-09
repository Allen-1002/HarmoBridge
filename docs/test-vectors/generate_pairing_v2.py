#!/usr/bin/env python3
"""
NotiBridge 协议 v2 配对测试向量生成器（独立参考实现）。

- CPace（draft-irtf-cfrg-cpace-21，CPACE-X25519-SHA512）：generator_string / Elligator2 / X25519
  这里用纯 Python 大整数实现，并先用草案附录 B.1 的官方测试向量自检，再与 cryptography 库的 X25519 交叉验证。
- 之后按 docs/protocol.md “配对（v2）”一节计算 NotiBridge 自己的派生值，写入 pairing-v2.json。

四个平台（Mac / Windows / Android / 鸿蒙）的单元测试都读取 pairing-v2.json，确认实现与本脚本逐字节一致。

用法：python3 docs/test-vectors/generate_pairing_v2.py   （需要 pip 包 cryptography）
"""
import hashlib
import hmac
import json
import os
import sys

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

P = 2**255 - 19
A = 486662


# ---------------- CPace 工具函数（草案附录 A） ----------------

def prepend_len(data: bytes) -> bytes:
    length = len(data)
    out = b""
    while True:
        if length < 128:
            out += bytes([length])
        else:
            out += bytes([(length & 0x7F) + 0x80])
        length >>= 7
        if length == 0:
            break
    return out + data


def lv_cat(*args: bytes) -> bytes:
    return b"".join(prepend_len(a) for a in args)


def generator_string(dsi: bytes, prs: bytes, ci: bytes, sid: bytes, s_in_bytes: int) -> bytes:
    len_zpad = max(0, s_in_bytes - 1 - len(prepend_len(prs)) - len(prepend_len(dsi)))
    return lv_cat(dsi, prs, bytes(len_zpad), ci, sid)


def decode_u(b: bytes) -> int:
    lst = bytearray(b)
    lst[31] &= 0x7F
    return int.from_bytes(lst, "little")


def encode_u(x: int) -> bytes:
    return (x % P).to_bytes(32, "little")


def elligator2(r: int) -> int:
    """草案附录 A.5：v = -A/(1+2r²)；ε = legendre(v³+Av²+v)；x = εv − (1−ε)A/2。"""
    r %= P
    v = (-A * pow(1 + 2 * r * r, P - 2, P)) % P
    eps = pow((v * v * v + A * v * v + v) % P, (P - 1) // 2, P)
    half_a = A * pow(2, P - 2, P) % P
    return (eps * v - (1 - eps) * half_a) % P


def calculate_generator(prs: bytes, ci: bytes, sid: bytes) -> bytes:
    gen_str = generator_string(b"CPace255", prs, ci, sid, 128)
    h = hashlib.sha512(gen_str).digest()[:32]
    return encode_u(elligator2(decode_u(h)))


def x25519(k: bytes, u: bytes) -> bytes:
    """RFC 7748 X25519，纯 Python Montgomery ladder。"""
    kb = bytearray(k)
    kb[0] &= 248
    kb[31] &= 127
    kb[31] |= 64
    kn = int.from_bytes(kb, "little")
    x1 = decode_u(u) % P
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in range(254, -1, -1):
        kt = (kn >> t) & 1
        swap ^= kt
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = kt
        a = (x2 + z2) % P
        aa = a * a % P
        b = (x2 - z2) % P
        bb = b * b % P
        e = (aa - bb) % P
        c = (x3 + z3) % P
        d = (x3 - z3) % P
        da = d * a % P
        cb = c * b % P
        x3 = (da + cb) ** 2 % P
        z3 = x1 * (da - cb) ** 2 % P
        x2 = aa * bb % P
        z2 = e * (aa + 121665 * e) % P
    if swap:
        x2, z2 = x3, z3
    return encode_u(x2 * pow(z2, P - 2, P))


def x25519_lib(k: bytes, u: bytes) -> bytes:
    """cryptography 库（OpenSSL）的 X25519，用于交叉验证。全 0 结果会抛异常。"""
    return X25519PrivateKey.from_private_bytes(k).exchange(X25519PublicKey.from_public_bytes(u))


def h(s: str) -> bytes:
    return bytes.fromhex("".join(s.split()))


# ---------------- 官方测试向量自检（草案附录 B.1 / B.1.10） ----------------

OFFICIAL = {
    "prs": "50617373776f7264",  # b"Password"
    "ci": "0b415f696e69746961746f720b425f726573706f6e646572",
    "sid": "7e4b4791d6a8ef019b936c79fb7f2c57",
    "generator_string": (
        "0843506163653235350850617373776f72646d000000000000000000"
        "00000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000180b415f696e69746961746f"
        "720b425f726573706f6e646572107e4b4791d6a8ef019b936c79fb7f"
        "2c57"),
    "hash": "03998087bdb1a2617bbe25ef5a7c18cd4f84f902328701790958755ee4aed1d3",
    "g": "d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b62f05a73f",
    "ya": "21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b319097153044080",
    "Ya": "1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32",
    "yb": "848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19c51ac40a",
    "Yb": "248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32185623",
    "K": "5b067effbdc0b2a0e1d907b21ebb25cfedb96a852179a847c37e43ee71322c6b",
}

LOW_ORDER_SCALAR = "af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff"
LOW_ORDER = [
    ("0000000000000000000000000000000000000000000000000000000000000000", None),
    ("0100000000000000000000000000000000000000000000000000000000000000", None),
    ("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", None),
    ("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800", None),
    ("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157", None),
    ("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", None),
    ("daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
     "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806"),
    ("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", None),
    ("dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
     "c85c655ebe8be44ba9c0ffde69f2fe10194458d137f09bbff725ce58803cdb38"),
    ("d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
     "db64dafa9b8fdd136914e61461935fe92aa372cb056314e1231bc4ec12417456"),
    ("cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880",
     "e062dcd5376d58297be2618c7498f55baa07d7e03184e8aada20bca28888bf7a"),
    ("4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7",
     "993c6ad11c4c29da9a56f7691fd0ff8d732e49de6250b6c2e80003ff4629a175"),
]


def self_check() -> None:
    o = OFFICIAL
    assert prepend_len(b"") == h("00")
    assert prepend_len(bytes(range(128)))[:2] == h("8001")
    assert lv_cat(b"1234", b"5", b"", b"678") == h("043132333401350003363738")
    gs = generator_string(b"CPace255", h(o["prs"]), h(o["ci"]), h(o["sid"]), 128)
    assert gs == h(o["generator_string"]), "generator_string"
    assert hashlib.sha512(gs).digest()[:32] == h(o["hash"]), "hash"
    g = calculate_generator(h(o["prs"]), h(o["ci"]), h(o["sid"]))
    assert g == h(o["g"]), "generator g"
    for f in (x25519, x25519_lib):
        assert f(h(o["ya"]), g) == h(o["Ya"]), "Ya"
        assert f(h(o["yb"]), g) == h(o["Yb"]), "Yb"
        assert f(h(o["ya"]), h(o["Yb"])) == h(o["K"]), "K"
        assert f(h(o["yb"]), h(o["Ya"])) == h(o["K"]), "K"
    s = h(LOW_ORDER_SCALAR)
    for u, q in LOW_ORDER:
        r = x25519(s, h(u))
        assert r == (h(q) if q else bytes(32)), u


# ---------------- NotiBridge v2 派生（docs/protocol.md） ----------------

INFO_PAIR_KEY = b"NotiBridge-v2 pair key"
INFO_CONFIRM_PHONE = b"NotiBridge-v2 confirm phone"
INFO_CONFIRM_COMPUTER = b"NotiBridge-v2 confirm computer"
TRANSCRIPT_LABEL = b"NotiBridge-pair-v2"
AAD_TO_COMPUTER = b"NB2|p2c"
AAD_TO_PHONE = b"NB2|c2p"


def hkdf(ikm: bytes, salt: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(ikm)


def sas(th: bytes) -> str:
    n = int.from_bytes(th[:5], "big") % 100_000_000
    s = f"{n:08d}"
    return s[:4] + " " + s[4:]


def derive(pin, device_id, device_name, phone_platform, mac_id, mac_name, mac_platform,
           phone_nonce, mac_nonce, ya, yb):
    u = lambda s: s.encode("utf-8")
    sid = phone_nonce + mac_nonce
    ci = lv_cat(u(device_id), u(mac_id))
    g = calculate_generator(u(pin), ci, sid)
    Ya = x25519(ya, g)
    Yb = x25519(yb, g)
    assert Ya == x25519_lib(ya, g) and Yb == x25519_lib(yb, g)
    K = x25519(ya, Yb)
    assert K == x25519(yb, Ya) and K != bytes(32)
    transcript = lv_cat(TRANSCRIPT_LABEL, sid, u(device_id), u(device_name), u(phone_platform),
                        u(mac_id), u(mac_name), u(mac_platform), Ya, Yb)
    th = hashlib.sha256(transcript).digest()
    pair_key = hkdf(K, th, INFO_PAIR_KEY)
    kc_p = hkdf(K, th, INFO_CONFIRM_PHONE)
    kc_c = hkdf(K, th, INFO_CONFIRM_COMPUTER)
    return {
        "ci": ci, "sid": sid, "generatorString": generator_string(b"CPace255", u(pin), ci, sid, 128),
        "g": g, "Ya": Ya, "Yb": Yb, "K": K, "transcript": transcript, "transcriptHash": th,
        "pairKey": pair_key, "confirmKeyPhone": kc_p, "confirmKeyComputer": kc_c,
        "confirmPhone": hmac.new(kc_p, th + b"phone", hashlib.sha256).digest(),
        "confirmComputer": hmac.new(kc_c, th + b"computer", hashlib.sha256).digest(),
        "sas": sas(th),
    }


def main() -> None:
    self_check()
    inputs = {
        "pin": "123456",
        "deviceId": "8f14e45f-ceea-467f-a0e6-b1c2d3e4f501",
        "deviceName": "测试手机 Mate",
        "phonePlatform": "android",
        "macId": "c9f0f895-fb98-4b91-9c1d-0a1b2c3d4e5f",
        "macName": "我的 Mac mini",
        "macPlatform": "mac",
        "phoneNonce": bytes(range(0, 16)),
        "macNonce": bytes(range(16, 32)),
        "ya": bytes(range(32, 64)),
        "yb": bytes(range(64, 96)),
    }
    d = derive(inputs["pin"], inputs["deviceId"], inputs["deviceName"], inputs["phonePlatform"], inputs["macId"],
               inputs["macName"], inputs["macPlatform"], inputs["phoneNonce"], inputs["macNonce"], inputs["ya"],
               inputs["yb"])
    wrong = derive("654321", inputs["deviceId"], inputs["deviceName"], inputs["phonePlatform"], inputs["macId"],
                   inputs["macName"], inputs["macPlatform"], inputs["phoneNonce"], inputs["macNonce"], inputs["ya"],
                   inputs["yb"])
    assert wrong["pairKey"] != d["pairKey"]

    # AES-256-GCM 固定 IV 样本：Base64(iv ‖ ct ‖ tag)，两个方向 AAD 不同
    iv = bytes(12)
    box_p2c = iv + AESGCM(d["pairKey"]).encrypt(iv, "通知 hello".encode(), AAD_TO_COMPUTER)
    box_c2p = iv + AESGCM(d["pairKey"]).encrypt(iv, "通知 hello".encode(), AAD_TO_PHONE)

    # 发布签名（Ed25519，RFC 8032 7.1 TEST 2 的密钥）：签 SHA256SUMS.txt 样本
    sk = Ed25519PrivateKey.from_private_bytes(h("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"))
    pk = sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    assert pk == h("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
    sums = ("0000000000000000000000000000000000000000000000000000000000000000  NotiBridge-1.1.0-macOS.dmg\n"
            "1111111111111111111111111111111111111111111111111111111111111111  NotiBridge-1.1.0-Windows-x64.zip\n")
    sig = sk.sign(sums.encode())

    import base64
    b64 = lambda b: base64.b64encode(b).decode()
    hexs = lambda b: b.hex()
    out = {
        "comment": "由 docs/test-vectors/generate_pairing_v2.py 生成，四端单元测试共用。二进制字段为小写十六进制，box 为 Base64。",
        "cpaceOfficial": {
            "source": "draft-irtf-cfrg-cpace-21 Appendix B.1 (CPACE-X25519-SHA512)",
            "prs": OFFICIAL["prs"], "ci": OFFICIAL["ci"], "sid": OFFICIAL["sid"],
            "generatorString": OFFICIAL["generator_string"], "hash": OFFICIAL["hash"], "g": OFFICIAL["g"],
            "ya": OFFICIAL["ya"], "Ya": OFFICIAL["Ya"], "yb": OFFICIAL["yb"], "Yb": OFFICIAL["Yb"],
            "K": OFFICIAL["K"],
            "lowOrderScalar": LOW_ORDER_SCALAR,
            "lowOrder": [{"u": u, "q": q or "00" * 32, "mustAbort": q is None} for u, q in LOW_ORDER],
        },
        "pairing": {
            "inputs": {
                "pin": inputs["pin"], "deviceId": inputs["deviceId"], "deviceName": inputs["deviceName"],
                "phonePlatform": inputs["phonePlatform"], "macId": inputs["macId"], "macName": inputs["macName"],
                "macPlatform": inputs["macPlatform"], "phoneNonce": hexs(inputs["phoneNonce"]),
                "macNonce": hexs(inputs["macNonce"]), "ya": hexs(inputs["ya"]), "yb": hexs(inputs["yb"]),
            },
            "outputs": {k: (v if isinstance(v, str) else hexs(v)) for k, v in d.items()},
            "wrongPin": {"pin": "654321", "pairKey": hexs(wrong["pairKey"]),
                         "confirmPhone": hexs(wrong["confirmPhone"]), "Ya": hexs(wrong["Ya"])},
            "boxes": {"plaintext": "通知 hello", "toComputer": b64(box_p2c), "toPhone": b64(box_c2p)},
        },
        "releaseSignature": {
            "comment": "RFC 8032 7.1 TEST 2 密钥（测试专用，不是发布密钥）",
            "publicKey": hexs(pk), "message": sums, "signature": b64(sig),
        },
    }
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pairing-v2.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("self-check ok; wrote", path)
    print(json.dumps(out["pairing"]["outputs"], ensure_ascii=False, indent=1))


if __name__ == "__main__":
    sys.exit(main())

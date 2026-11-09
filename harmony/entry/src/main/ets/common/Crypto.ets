import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { CryptoPrimitives, x25519Ref } from './Cpace';

/**
 * 与 Mac 端 BridgeCrypto.swift 逐项一致（见 docs/protocol.md “密码学约定”，协议 v2）。
 * X25519 公钥在线路上用 32 字节原始格式；鸿蒙 getEncoded() 返回 SPKI DER（12 字节前缀 + 32 字节原始公钥）。
 */
const X25519_SPKI_PREFIX = new Uint8Array([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]);
/** X25519 私钥的 PKCS#8 DER 前缀（16 字节）+ 32 字节原始私钥 */
const X25519_PKCS8_PREFIX = new Uint8Array([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e,
  0x04, 0x22, 0x04, 0x20]);
export const PROTOCOL_VERSION = 2;

/** 消息方向：AAD 不同，把一方的消息反射回去也解不开（docs/protocol.md） */
export type Direction = 'toComputer' | 'toPhone';

function aadOf(dir: Direction): string {
  return dir === 'toComputer' ? 'NB2|p2c' : 'NB2|c2p';
}

export function utf8(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}

export function fromUtf8(b: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(b);
}

export function b64(b: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(b);
}

export function fromB64(s: string): Uint8Array {
  return new util.Base64Helper().decodeSync(s);
}

export function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

export function randomBytes(n: number): Uint8Array {
  return cryptoFramework.createRandom().generateRandomSync(n).data;
}

export function sha256(data: Uint8Array): Uint8Array {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: data });
  return md.digestSync().data;
}

export function hkdfSha256(ikm: Uint8Array, salt: Uint8Array, info: Uint8Array, len: number): Uint8Array {
  const spec: cryptoFramework.HKDFSpec = {
    algName: 'HKDF',
    key: ikm,
    salt: salt,
    info: info,
    keySize: len,
  };
  return cryptoFramework.createKdf('HKDF|SHA256').generateSecretSync(spec).data;
}

export function sha512(data: Uint8Array): Uint8Array {
  const md = cryptoFramework.createMd('SHA512');
  md.updateSync({ data: data });
  return md.digestSync().data;
}

export function hmacSha256(key: Uint8Array, data: Uint8Array): Uint8Array {
  const symKey = cryptoFramework.createSymKeyGenerator('HMAC').convertKeySync({ data: key });
  const mac = cryptoFramework.createMac('SHA256');
  mac.initSync(symKey);
  mac.updateSync({ data: data });
  return mac.doFinalSync().data;
}

/** X25519(scalar, point)：用系统实现（常量时间）；系统不支持导入原始私钥时退回纯 ArkTS 实现。结果全 0 抛错。 */
export function x25519(scalar: Uint8Array, point: Uint8Array): Uint8Array {
  if (scalar.length !== 32 || point.length !== 32) {
    throw new Error('bad point length');
  }
  let out: Uint8Array;
  try {
    const gen = cryptoFramework.createAsyKeyGenerator('X25519');
    const pri = gen.convertKeySync(null, { data: concat(X25519_PKCS8_PREFIX, scalar) }).priKey;
    const pub = gen.convertKeySync({ data: concat(X25519_SPKI_PREFIX, point) }, null).pubKey;
    out = cryptoFramework.createKeyAgreement('X25519').generateSecretSync(pri, pub).data;
  } catch (e) {
    // 低阶点时系统实现也会抛错：用纯实现再算一次，得到同样的结论（抛错）或结果
    out = x25519Ref(scalar, point);
  }
  if (out.length !== 32 || out.every((x: number) => x === 0)) {
    throw new Error('low-order point');
  }
  return out;
}

/** 供 Cpace.ets 使用的系统密码学原语 */
export const PRIMITIVES: CryptoPrimitives = {
  utf8: utf8,
  sha256: sha256,
  sha512: sha512,
  hmacSha256: hmacSha256,
  hkdfSha256: hkdfSha256,
  x25519: x25519,
};

function aesKey(raw: Uint8Array): cryptoFramework.SymKey {
  return cryptoFramework.createSymKeyGenerator('AES256').convertKeySync({ data: raw });
}

/** AES-256-GCM，输出 Base64(iv12 ‖ ciphertext ‖ tag16)，与 CryptoKit SealedBox.combined 相同。 */
export function seal(key: Uint8Array, plaintext: string, dir: Direction): string {
  const iv = randomBytes(12);
  const spec: cryptoFramework.GcmParamsSpec = {
    algName: 'GcmParamsSpec',
    iv: { data: iv },
    aad: { data: utf8(aadOf(dir)) },
    authTag: { data: new Uint8Array(16) },
  };
  const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
  cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, aesKey(key), spec);
  const out = cipher.doFinalSync({ data: utf8(plaintext) }).data; // ciphertext ‖ tag
  return b64(concat(iv, out));
}

export function open(key: Uint8Array, box: string, dir: Direction): string {
  const all = fromB64(box);
  if (all.length <= 28) {
    throw new Error('box too short');
  }
  const spec: cryptoFramework.GcmParamsSpec = {
    algName: 'GcmParamsSpec',
    iv: { data: all.slice(0, 12) },
    aad: { data: utf8(aadOf(dir)) },
    authTag: { data: all.slice(all.length - 16) },
  };
  const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
  cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, aesKey(key), spec);
  return fromUtf8(cipher.doFinalSync({ data: all.slice(12, all.length - 16) }).data);
}

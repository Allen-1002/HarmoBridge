import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

/**
 * 与 Mac 端 BridgeCrypto.swift 逐项一致（见 docs/protocol.md “密码学约定”）。
 * X25519 公钥在线路上用 32 字节原始格式；鸿蒙 getEncoded() 返回 SPKI DER（12 字节前缀 + 32 字节原始公钥）。
 */
const X25519_SPKI_PREFIX = new Uint8Array([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]);
const AAD = 'HB1';
export const PAIR_INFO_PREFIX = 'HarmoBridge-pair-v1|';

export interface X25519Pair {
  keyPair: cryptoFramework.KeyPair;
  rawPub: Uint8Array;
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

export function generateX25519(): X25519Pair {
  const kp = cryptoFramework.createAsyKeyGenerator('X25519').generateKeyPairSync();
  const der = kp.pubKey.getEncoded().data;
  return { keyPair: kp, rawPub: der.slice(der.length - 32) };
}

export function x25519Shared(priKey: cryptoFramework.PriKey, peerRawPub: Uint8Array): Uint8Array {
  if (peerRawPub.length !== 32) {
    throw new Error('bad peer public key');
  }
  const peer = cryptoFramework.createAsyKeyGenerator('X25519')
    .convertKeySync({ data: concat(X25519_SPKI_PREFIX, peerRawPub) }, null).pubKey;
  return cryptoFramework.createKeyAgreement('X25519').generateSecretSync(priKey, peer).data;
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

/** 配对密钥与校验码。 */
export function derivePairKey(priKey: cryptoFramework.PriKey, phonePub: Uint8Array, macPub: Uint8Array,
  pin: string): Uint8Array {
  const shared = x25519Shared(priKey, macPub);
  const salt = sha256(concat(phonePub, macPub));
  return hkdfSha256(shared, salt, utf8(PAIR_INFO_PREFIX + pin), 32);
}

export function sas(phonePub: Uint8Array, macPub: Uint8Array): string {
  const salt = sha256(concat(phonePub, macPub));
  let s = '';
  for (let i = 0; i < 3; i++) {
    s += salt[i].toString(16).padStart(2, '0').toUpperCase();
  }
  return s;
}

function aesKey(raw: Uint8Array): cryptoFramework.SymKey {
  return cryptoFramework.createSymKeyGenerator('AES256').convertKeySync({ data: raw });
}

/** AES-256-GCM，输出 Base64(iv12 ‖ ciphertext ‖ tag16)，与 CryptoKit SealedBox.combined 相同。 */
export function seal(key: Uint8Array, plaintext: string): string {
  const iv = randomBytes(12);
  const spec: cryptoFramework.GcmParamsSpec = {
    algName: 'GcmParamsSpec',
    iv: { data: iv },
    aad: { data: utf8(AAD) },
    authTag: { data: new Uint8Array(16) },
  };
  const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
  cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, aesKey(key), spec);
  const out = cipher.doFinalSync({ data: utf8(plaintext) }).data; // ciphertext ‖ tag
  return b64(concat(iv, out));
}

export function open(key: Uint8Array, box: string): string {
  const all = fromB64(box);
  if (all.length <= 28) {
    throw new Error('box too short');
  }
  const spec: cryptoFramework.GcmParamsSpec = {
    algName: 'GcmParamsSpec',
    iv: { data: all.slice(0, 12) },
    aad: { data: utf8(AAD) },
    authTag: { data: all.slice(all.length - 16) },
  };
  const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
  cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, aesKey(key), spec);
  return fromUtf8(cipher.doFinalSync({ data: all.slice(12, all.length - 16) }).data);
}

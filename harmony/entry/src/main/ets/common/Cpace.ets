/**
 * CPace（draft-irtf-cfrg-cpace-21，CPACE-X25519-SHA512）与 NotiBridge 协议 v2 的派生计算。
 * 与 Mac Cpace.swift / BridgeCrypto.swift、Windows Cpace.cs、Android Cpace.kt 逐项一致，
 * 测试向量见 docs/test-vectors/pairing-v2.json。
 *
 * 这个文件只用纯 ArkTS（bigint 做 Elligator2 的域运算），不引用任何系统 Kit：
 * SHA-256/512、HMAC、HKDF、X25519、UTF-8 由调用方通过 CryptoPrimitives 传入
 * （App 里用 cryptoFramework，见 Crypto.ets；单元测试里用 Node 的 crypto），所以可以在电脑上用测试向量验证。
 */
export interface CryptoPrimitives {
  utf8: (s: string) => Uint8Array;
  sha256: (data: Uint8Array) => Uint8Array;
  sha512: (data: Uint8Array) => Uint8Array;
  hmacSha256: (key: Uint8Array, data: Uint8Array) => Uint8Array;
  hkdfSha256: (ikm: Uint8Array, salt: Uint8Array, info: Uint8Array, len: number) => Uint8Array;
  /** X25519(scalar, point)；结果全 0（低阶点）时必须抛错 */
  x25519: (scalar: Uint8Array, point: Uint8Array) => Uint8Array;
}

/** 配对双方都知道的公开信息（字符串按线路上的原样） */
export interface PairingContext {
  deviceId: string;
  deviceName: string;
  phonePlatform: string;
  macId: string;
  macName: string;
  macPlatform: string;
  phoneNonce: Uint8Array;
  macNonce: Uint8Array;
}

export interface PairingKeys {
  pairKey: Uint8Array;
  transcriptHash: Uint8Array;
  confirmPhone: Uint8Array;
  confirmComputer: Uint8Array;
  sas: string;
}

const S_IN_BYTES = 128;
const P: bigint = (BigInt(1) << BigInt(255)) - BigInt(19);
const A: bigint = BigInt(486662);

export function concatBytes(parts: Array<Uint8Array>): Uint8Array {
  let n = 0;
  for (const p of parts) {
    n += p.length;
  }
  const out = new Uint8Array(n);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

export function prependLen(data: Uint8Array): Uint8Array {
  const len: Array<number> = [];
  let n = data.length;
  do {
    len.push(n < 128 ? n : (n & 0x7f) + 0x80);
    n = n >> 7;
  } while (n !== 0);
  return concatBytes([new Uint8Array(len), data]);
}

export function lvCat(items: Array<Uint8Array>): Uint8Array {
  return concatBytes(items.map((x: Uint8Array) => prependLen(x)));
}

export function generatorString(p: CryptoPrimitives, prs: Uint8Array, ci: Uint8Array, sid: Uint8Array): Uint8Array {
  const dsi = p.utf8('CPace255');
  const zpad = Math.max(0, S_IN_BYTES - 1 - prependLen(prs).length - prependLen(dsi).length);
  return lvCat([dsi, prs, new Uint8Array(zpad), ci, sid]);
}

function mod(x: bigint): bigint {
  const r = x % P;
  return r < BigInt(0) ? r + P : r;
}

function powMod(base: bigint, exp: bigint): bigint {
  let r = BigInt(1);
  let b = mod(base);
  let e = exp;
  while (e > BigInt(0)) {
    if ((e & BigInt(1)) === BigInt(1)) {
      r = mod(r * b);
    }
    b = mod(b * b);
    e = e >> BigInt(1);
  }
  return r;
}

function decodeLe(b: Uint8Array): bigint {
  let x = BigInt(0);
  for (let i = b.length - 1; i >= 0; i--) {
    x = (x << BigInt(8)) + BigInt(b[i]);
  }
  return x;
}

function encodeLe(x: bigint): Uint8Array {
  const out = new Uint8Array(32);
  let v = mod(x);
  for (let i = 0; i < 32; i++) {
    out[i] = Number(v & BigInt(0xff));
    v = v >> BigInt(8);
  }
  return out;
}

/** Elligator2（草案附录 A.5）：v = -A/(1+2r²)，ε = legendre(v³+Av²+v)，x = εv − (1−ε)A/2 */
export function elligator2(r: bigint): bigint {
  const two = BigInt(2);
  const one = BigInt(1);
  const v = mod(-A * powMod(one + two * r * r, P - two));
  const gx = mod(v * v * v + A * v * v + v);
  const eps = powMod(gx, (P - one) >> one);
  const halfA = mod(A * powMod(two, P - two));
  return mod(eps * v - (one - eps) * halfA);
}

/** CPace 生成元 g（32 字节小端 u 坐标） */
export function generator(p: CryptoPrimitives, prs: Uint8Array, ci: Uint8Array, sid: Uint8Array): Uint8Array {
  const hash = p.sha512(generatorString(p, prs, ci, sid)).slice(0, 32);
  hash[31] = hash[31] & 0x7f;
  return encodeLe(elligator2(decodeLe(hash)));
}

export function sidOf(ctx: PairingContext): Uint8Array {
  return concatBytes([ctx.phoneNonce, ctx.macNonce]);
}

export function ciOf(p: CryptoPrimitives, ctx: PairingContext): Uint8Array {
  return lvCat([p.utf8(ctx.deviceId), p.utf8(ctx.macId)]);
}

export function pairingGenerator(p: CryptoPrimitives, ctx: PairingContext, pin: string): Uint8Array {
  return generator(p, p.utf8(pin), ciOf(p, ctx), sidOf(ctx));
}

export function transcript(p: CryptoPrimitives, ctx: PairingContext, ya: Uint8Array, yb: Uint8Array): Uint8Array {
  return lvCat([p.utf8('NotiBridge-pair-v2'), sidOf(ctx), p.utf8(ctx.deviceId), p.utf8(ctx.deviceName),
    p.utf8(ctx.phonePlatform), p.utf8(ctx.macId), p.utf8(ctx.macName), p.utf8(ctx.macPlatform), ya, yb]);
}

/** 8 位数字校验码：th 前 5 字节大端整数 mod 10^8，显示为 "1234 5678" */
export function sasOf(th: Uint8Array): string {
  let n = 0;
  for (let i = 0; i < 5; i++) {
    n = n * 256 + th[i];
  }
  const s = (n % 100000000).toString().padStart(8, '0');
  return `${s.substring(0, 4)} ${s.substring(4)}`;
}

export function pairingKeys(p: CryptoPrimitives, k: Uint8Array, ctx: PairingContext, ya: Uint8Array,
  yb: Uint8Array): PairingKeys {
  const th = p.sha256(transcript(p, ctx, ya, yb));
  const kcP = p.hkdfSha256(k, th, p.utf8('NotiBridge-v2 confirm phone'), 32);
  const kcC = p.hkdfSha256(k, th, p.utf8('NotiBridge-v2 confirm computer'), 32);
  return {
    pairKey: p.hkdfSha256(k, th, p.utf8('NotiBridge-v2 pair key'), 32),
    transcriptHash: th,
    confirmPhone: p.hmacSha256(kcP, concatBytes([th, p.utf8('phone')])),
    confirmComputer: p.hmacSha256(kcC, concatBytes([th, p.utf8('computer')])),
    sas: sasOf(th),
  };
}

/** 常量时间比较 */
export function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff = diff | (a[i] ^ b[i]);
  }
  return diff === 0;
}

/**
 * RFC 7748 X25519（bigint Montgomery ladder，非常量时间）。只在系统 cryptoFramework 无法导入原始私钥时兜底，
 * 也用于单元测试交叉验证；正常情况下 App 用 cryptoFramework 的实现。结果全 0 时抛错。
 */
export function x25519Ref(scalar: Uint8Array, point: Uint8Array): Uint8Array {
  if (scalar.length !== 32 || point.length !== 32) {
    throw new Error('bad point length');
  }
  const k = scalar.slice(0, 32);
  k[0] = k[0] & 248;
  k[31] = (k[31] & 127) | 64;
  const kn = decodeLe(k);
  const u = point.slice(0, 32);
  u[31] = u[31] & 127;
  const x1 = mod(decodeLe(u));
  let x2 = BigInt(1);
  let z2 = BigInt(0);
  let x3 = x1;
  let z3 = BigInt(1);
  let swap = 0;
  const a24 = BigInt(121665);
  for (let t = 254; t >= 0; t--) {
    const kt = Number((kn >> BigInt(t)) & BigInt(1));
    swap = swap ^ kt;
    if (swap === 1) {
      const tx = x2;
      x2 = x3;
      x3 = tx;
      const tz = z2;
      z2 = z3;
      z3 = tz;
    }
    swap = kt;
    const a = mod(x2 + z2);
    const aa = mod(a * a);
    const b = mod(x2 - z2);
    const bb = mod(b * b);
    const e = mod(aa - bb);
    const c = mod(x3 + z3);
    const d = mod(x3 - z3);
    const da = mod(d * a);
    const cb = mod(c * b);
    x3 = mod((da + cb) * (da + cb));
    z3 = mod(x1 * mod((da - cb) * (da - cb)));
    x2 = mod(aa * bb);
    z2 = mod(e * mod(aa + a24 * e));
  }
  if (swap === 1) {
    x2 = x3;
    z2 = z3;
  }
  const out = encodeLe(mod(x2 * powMod(z2, P - BigInt(2))));
  if (out.every((x: number) => x === 0)) {
    throw new Error('low-order point');
  }
  return out;
}

// 鸿蒙端 CPace / 协议 v2 派生计算的单元测试（在电脑上用 Node 运行，不需要手机）：
//   node harmony/scripts/test_cpace.mjs
// entry/src/main/ets/common/Cpace.ets 是纯 ArkTS（不引用系统 Kit），这里把它复制成 .ts、用 Node 的类型擦除加载，
// 密码学原语换成 Node crypto，然后读取四端共用的 docs/test-vectors/pairing-v2.json 逐项比对。
// App 里的原语（cryptoFramework）只能在真机上验证。
import { createHash, createHmac, hkdfSync, createDecipheriv, createCipheriv, diffieHellman, createPrivateKey, createPublicKey } from 'node:crypto';
import { copyFileSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const work = mkdtempSync(join(tmpdir(), 'nb-cpace-'));
copyFileSync(join(root, 'harmony/entry/src/main/ets/common/Cpace.ets'), join(work, 'Cpace.ts'));
const C = await import(pathToFileURL(join(work, 'Cpace.ts')).href);
copyFileSync(join(root, 'harmony/entry/src/main/ets/common/FilterLogic.ets'), join(work, 'FilterLogic.ts'));
const F = await import(pathToFileURL(join(work, 'FilterLogic.ts')).href);
const V = JSON.parse(readFileSync(join(root, 'docs/test-vectors/pairing-v2.json'), 'utf8'));

const hex = (s) => new Uint8Array(Buffer.from(s, 'hex'));
const toHex = (b) => Buffer.from(b).toString('hex');
const u8 = (b) => new Uint8Array(b);

// Node 的 X25519：用 PKCS#8 / SPKI 导入原始字节（与 App 里 cryptoFramework 的导入方式相同）
const PKCS8 = Buffer.from('302e020100300506032b656e04220420', 'hex');
const SPKI = Buffer.from('302a300506032b656e032100', 'hex');
function x25519Node(scalar, point) {
  const pri = createPrivateKey({ key: Buffer.concat([PKCS8, Buffer.from(scalar)]), format: 'der', type: 'pkcs8' });
  const pub = createPublicKey({ key: Buffer.concat([SPKI, Buffer.from(point)]), format: 'der', type: 'spki' });
  const out = u8(diffieHellman({ privateKey: pri, publicKey: pub }));
  if (out.every((x) => x === 0)) throw new Error('low-order point');
  return out;
}

const P = {
  utf8: (s) => u8(Buffer.from(s, 'utf8')),
  sha256: (d) => u8(createHash('sha256').update(d).digest()),
  sha512: (d) => u8(createHash('sha512').update(d).digest()),
  hmacSha256: (k, d) => u8(createHmac('sha256', k).update(d).digest()),
  hkdfSha256: (ikm, salt, info, len) => u8(hkdfSync('sha256', ikm, salt, info, len)),
  x25519: x25519Node,
};

let passed = 0;
function test(name, fn) {
  fn();
  passed++;
  console.log('ok -', name);
}

test('lv_cat / prepend_len', () => {
  assert.equal(toHex(C.lvCat([P.utf8('1234'), P.utf8('5'), new Uint8Array(0), P.utf8('678')])), '043132333401350003363738');
  assert.equal(toHex(C.prependLen(new Uint8Array(128)).slice(0, 2)), '8001');
});

test('CPace 官方向量（draft-21 附录 B.1）', () => {
  const o = V.cpaceOfficial;
  assert.equal(toHex(C.generatorString(P, hex(o.prs), hex(o.ci), hex(o.sid))), o.generatorString);
  const g = C.generator(P, hex(o.prs), hex(o.ci), hex(o.sid));
  assert.equal(toHex(g), o.g);
  for (const x of [P.x25519, C.x25519Ref]) {
    assert.equal(toHex(x(hex(o.ya), g)), o.Ya);
    assert.equal(toHex(x(hex(o.yb), g)), o.Yb);
    assert.equal(toHex(x(hex(o.ya), hex(o.Yb))), o.K);
    assert.equal(toHex(x(hex(o.yb), hex(o.Ya))), o.K);
  }
});

test('低阶点必须中止（附录 B.1.10）', () => {
  const o = V.cpaceOfficial;
  for (const item of o.lowOrder) {
    for (const x of [P.x25519, C.x25519Ref]) {
      if (item.mustAbort) assert.throws(() => x(hex(o.lowOrderScalar), hex(item.u)), item.u);
      else assert.equal(toHex(x(hex(o.lowOrderScalar), hex(item.u))), item.q);
    }
  }
});

test('NotiBridge v2 配对向量', () => {
  const i = V.pairing.inputs;
  const out = V.pairing.outputs;
  const ctx = {
    deviceId: i.deviceId, deviceName: i.deviceName, phonePlatform: i.phonePlatform, macId: i.macId,
    macName: i.macName, macPlatform: i.macPlatform, phoneNonce: hex(i.phoneNonce), macNonce: hex(i.macNonce),
  };
  assert.equal(toHex(C.ciOf(P, ctx)), out.ci);
  assert.equal(toHex(C.sidOf(ctx)), out.sid);
  const g = C.pairingGenerator(P, ctx, i.pin);
  assert.equal(toHex(g), out.g);
  const ya = P.x25519(hex(i.ya), g);
  const yb = P.x25519(hex(i.yb), g);
  assert.equal(toHex(ya), out.Ya);
  assert.equal(toHex(yb), out.Yb);
  const k = P.x25519(hex(i.ya), yb);
  assert.equal(toHex(k), out.K);
  assert.equal(toHex(C.transcript(P, ctx, ya, yb)), out.transcript);
  const keys = C.pairingKeys(P, k, ctx, ya, yb);
  assert.equal(toHex(keys.transcriptHash), out.transcriptHash);
  assert.equal(toHex(keys.pairKey), out.pairKey);
  assert.equal(toHex(keys.confirmPhone), out.confirmPhone);
  assert.equal(toHex(keys.confirmComputer), out.confirmComputer);
  assert.equal(keys.sas, out.sas);
  assert.ok(C.constantTimeEqual(keys.confirmPhone, hex(out.confirmPhone)));
  assert.ok(!C.constantTimeEqual(keys.confirmPhone, hex(out.confirmComputer)));
  // 错误 PIN
  assert.equal(toHex(P.x25519(hex(i.ya), C.pairingGenerator(P, ctx, V.pairing.wrongPin.pin))), V.pairing.wrongPin.Ya);
  // AES-GCM 方向 AAD（与 Crypto.ets 的 seal/open 约定一致：iv12 ‖ ct ‖ tag16）
  const openBox = (key, b64, aad) => {
    const all = Buffer.from(b64, 'base64');
    const d = createDecipheriv('aes-256-gcm', key, all.subarray(0, 12));
    d.setAAD(Buffer.from(aad));
    d.setAuthTag(all.subarray(all.length - 16));
    return Buffer.concat([d.update(all.subarray(12, all.length - 16)), d.final()]).toString('utf8');
  };
  assert.equal(openBox(keys.pairKey, V.pairing.boxes.toComputer, 'NB2|p2c'), V.pairing.boxes.plaintext);
  assert.equal(openBox(keys.pairKey, V.pairing.boxes.toPhone, 'NB2|c2p'), V.pairing.boxes.plaintext);
  assert.throws(() => openBox(keys.pairKey, V.pairing.boxes.toComputer, 'NB2|c2p'));
  void createCipheriv;
});

test('SAS 格式', () => {
  assert.equal(C.sasOf(new Uint8Array(32)), '0000 0000');
  assert.equal(C.sasOf(new Uint8Array(32).fill(0xff)), '1162 7775');
});

test('验证码在按应用屏蔽和敏感过滤之后', () => {
  const s = { paused: false, blockSensitive: true, blockedBundles: [], copyOtp: true, updatedAt: 0, allowSensitiveOtp: false };
  let d = F.decide(s, 'com.ohos.mms', '短信', '您的验证码是 483920');
  assert.equal(d.action, 'otp');
  assert.equal(d.otp, '483920');
  s.blockedBundles = ['com.ohos.mms'];
  assert.equal(F.decide(s, 'com.ohos.mms', '短信', '您的验证码是 483920').action, 'drop');
  s.blockedBundles = [];
  d = F.decide(s, 'com.ohos.mms', '短信', '【某银行】您正在转账，验证码 556677');
  assert.equal(d.action, 'drop');
  assert.equal(d.record, false);
  assert.equal(F.decide(s, 'com.icbc.mobile', '工行', '动态码 1234').action, 'drop');
  s.allowSensitiveOtp = true;
  assert.equal(F.decide(s, 'com.ohos.mms', '短信', '【某银行】您正在转账，验证码 556677').action, 'otp');
  s.copyOtp = false;
  d = F.decide(s, 'com.ohos.mms', '短信', '您的验证码是 483920');
  assert.equal(d.action, 'drop');
  assert.equal(d.record, false);
  s.copyOtp = true;
  s.paused = true;
  assert.equal(F.decide(s, 'com.ohos.mms', '短信', '您的验证码是 483920').action, 'drop');
  s.paused = false;
  assert.equal(F.decide(s, 'com.tencent.wechat', '张三', '晚上吃饭').action, 'forward');
});

test('通知记录：7 天 / 200 条 / 256 KB 上限', () => {
  const now = 1_800_000_000_000;
  const len = (x) => Buffer.byteLength(x);
  const mk = (t, i) => ({ kind: 'publish', recordTime: t, hashCode: String(i), appName: 'A', result: '已转发' });
  const old = [mk(now - 8 * 86400000, 0), mk(now - 1000, 1)];
  assert.deepEqual(F.trimRecords(old, now, len).map((r) => r.hashCode), ['1']);
  const many = Array.from({ length: 300 }, (_, i) => mk(now - 300 + i, i));
  const t = F.trimRecords(many, now, len);
  assert.equal(t.length, 200);
  assert.equal(t[t.length - 1].hashCode, '299', '保留最新的');
  const big = Array.from({ length: 150 }, (_, i) => ({ ...mk(now, i), targets: 'x'.repeat(3000) }));
  const tb = F.trimRecords(big, now, len);
  const bytes = tb.reduce((n, r) => n + len(JSON.stringify(r)) + 1, 0);
  assert.ok(bytes <= 256 * 1024 && tb.length < 150);
  assert.ok(!('title' in mk(now, 1)) && !('text' in mk(now, 1)));
});

console.log(`\n${passed} tests passed`);

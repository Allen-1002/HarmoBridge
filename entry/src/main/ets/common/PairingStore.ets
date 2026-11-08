import { asset } from '@kit.AssetStoreKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { utf8 } from './Crypto';
import { Logger } from './Logger';

/**
 * 配对信息：非敏感字段放 preferences；配对密钥放系统 Asset Store（加密存储，首次解锁后可读）。
 */
export interface MacInfo {
  host: string;
  port: number;
  macId: string;
  macName: string;
}

const PREF_NAME = 'harmobridge_pairing';
const KEY_ALIAS = 'harmobridge.mac.pairkey';

function prefs(ctx: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(ctx, { name: PREF_NAME });
}

export function deviceId(ctx: common.Context): string {
  const p = prefs(ctx);
  let id = p.getSync('deviceId', '') as string;
  if (id.length === 0) {
    id = util.generateRandomUUID();
    p.putSync('deviceId', id);
    p.flushSync();
  }
  return id;
}

export function loadMac(ctx: common.Context): MacInfo | undefined {
  const raw = prefs(ctx).getSync('mac', '') as string;
  if (raw.length === 0) {
    return undefined;
  }
  return JSON.parse(raw) as MacInfo;
}

export function saveMac(ctx: common.Context, info: MacInfo): void {
  const p = prefs(ctx);
  p.putSync('mac', JSON.stringify(info));
  p.flushSync();
}

export function saveKey(key: Uint8Array): void {
  removeKey();
  const attrs: asset.AssetMap = new Map();
  attrs.set(asset.Tag.ALIAS, utf8(KEY_ALIAS));
  attrs.set(asset.Tag.SECRET, key);
  attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  asset.addSync(attrs);
}

export function loadKey(): Uint8Array | undefined {
  const q: asset.AssetMap = new Map();
  q.set(asset.Tag.ALIAS, utf8(KEY_ALIAS));
  q.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
  try {
    const res = asset.querySync(q);
    if (res.length === 0) {
      return undefined;
    }
    return res[0].get(asset.Tag.SECRET) as Uint8Array;
  } catch (e) {
    // 24000002 = 未找到，属正常情况
    return undefined;
  }
}

export function removeKey(): void {
  const q: asset.AssetMap = new Map();
  q.set(asset.Tag.ALIAS, utf8(KEY_ALIAS));
  try {
    asset.removeSync(q);
  } catch (e) {
    // 不存在时忽略
  }
}

export function forgetMac(ctx: common.Context): void {
  removeKey();
  const p = prefs(ctx);
  p.deleteSync('mac');
  p.flushSync();
  Logger.info('pairing removed');
}

import { asset } from '@kit.AssetStoreKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { utf8 } from './Crypto';
import { Logger } from './Logger';

/**
 * 已配对的电脑（Mac 或 Windows，可以有多台）。
 * 非敏感字段放 preferences；每台电脑各自的配对密钥放系统 Asset Store（加密存储，首次解锁后可读）。
 */
export interface MacInfo {
  host: string;
  port: number;
  macId: string; // 电脑的唯一 ID（协议字段名沿用 macId）
  macName: string;
  platform?: string; // 'mac' | 'windows'，旧版 Mac 不发送，按 'mac' 处理
}

const PREF_NAME = 'harmobridge_pairing';
const LIST_KEY = 'computers';
const LEGACY_KEY_ALIAS = 'harmobridge.mac.pairkey'; // 1.0.x 只支持一台 Mac 时的密钥别名
const KEY_ALIAS_PREFIX = 'harmobridge.computer.pairkey.';

function prefs(ctx: common.Context): preferences.Preferences {
  // 配对列表可能被另一个进程（App 界面 / 通知订阅扩展）改过：先丢弃本进程缓存
  try {
    preferences.removePreferencesFromCacheSync(ctx, { name: PREF_NAME });
  } catch (e) {
    // 首次读取时没有缓存，忽略
  }
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

export function platformLabel(m: MacInfo): string {
  return m.platform === 'windows' ? 'Windows' : 'Mac';
}

// ---------- 密钥 ----------

function aliasFor(macId: string): string {
  return KEY_ALIAS_PREFIX + macId;
}

function addSecret(alias: string, key: Uint8Array): void {
  removeSecret(alias);
  const attrs: asset.AssetMap = new Map();
  attrs.set(asset.Tag.ALIAS, utf8(alias));
  attrs.set(asset.Tag.SECRET, key);
  attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  asset.addSync(attrs);
}

function querySecret(alias: string): Uint8Array | undefined {
  const q: asset.AssetMap = new Map();
  q.set(asset.Tag.ALIAS, utf8(alias));
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

function removeSecret(alias: string): void {
  const q: asset.AssetMap = new Map();
  q.set(asset.Tag.ALIAS, utf8(alias));
  try {
    asset.removeSync(q);
  } catch (e) {
    // 不存在时忽略
  }
}

export function loadKeyFor(macId: string): Uint8Array | undefined {
  return querySecret(aliasFor(macId));
}

// ---------- 列表 ----------

function readList(p: preferences.Preferences): Array<MacInfo> {
  const raw = p.getSync(LIST_KEY, '') as string;
  if (raw.length === 0) {
    return [];
  }
  try {
    return JSON.parse(raw) as Array<MacInfo>;
  } catch (e) {
    return [];
  }
}

function writeList(p: preferences.Preferences, list: Array<MacInfo>): void {
  p.putSync(LIST_KEY, JSON.stringify(list));
  p.flushSync();
}

/** 1.0.x 只保存一台 Mac（prefs 'mac' + 固定别名的密钥），首次读取时迁移到列表。 */
function migrateLegacy(p: preferences.Preferences): void {
  const raw = p.getSync('mac', '') as string;
  if (raw.length === 0) {
    return;
  }
  try {
    const legacy = JSON.parse(raw) as MacInfo;
    const key = querySecret(LEGACY_KEY_ALIAS);
    if (key !== undefined) {
      if (legacy.macId.length === 0) {
        legacy.macId = `legacy-${legacy.host}`;
      }
      legacy.platform = 'mac';
      addSecret(aliasFor(legacy.macId), key);
      const list = readList(p).filter((m: MacInfo) => m.macId !== legacy.macId);
      list.push(legacy);
      writeList(p, list);
      Logger.info('pairing migrated to multi-computer list');
    }
    removeSecret(LEGACY_KEY_ALIAS);
  } catch (e) {
    Logger.warn('legacy pairing migration failed');
  }
  p.deleteSync('mac');
  p.flushSync();
}

/** 所有已配对、且密钥仍在的电脑。 */
export function pairedComputers(ctx: common.Context): Array<MacInfo> {
  const p = prefs(ctx);
  migrateLegacy(p);
  return readList(p).filter((m: MacInfo) => loadKeyFor(m.macId) !== undefined);
}

export function findComputer(ctx: common.Context, macId: string): MacInfo | undefined {
  return pairedComputers(ctx).find((m: MacInfo) => m.macId === macId);
}

/** 配对成功：保存（同一台电脑重新配对时覆盖旧的）。 */
export function saveComputer(ctx: common.Context, info: MacInfo, key: Uint8Array): void {
  addSecret(aliasFor(info.macId), key);
  const p = prefs(ctx);
  const list = readList(p).filter((m: MacInfo) => m.macId !== info.macId);
  list.push(info);
  writeList(p, list);
}

/** 电脑换了 IP（DHCP 重新分配等）：局域网自动发现到后更新地址。 */
export function updateComputerAddress(ctx: common.Context, macId: string, host: string, port: number): boolean {
  const p = prefs(ctx);
  const list = readList(p);
  const m = list.find((x: MacInfo) => x.macId === macId);
  if (m === undefined || (m.host === host && m.port === port)) {
    return false;
  }
  m.host = host;
  m.port = port;
  writeList(p, list);
  Logger.info(`computer address updated ${macId.substring(0, 8)}`);
  return true;
}

export function forgetComputer(ctx: common.Context, macId: string): void {
  removeSecret(aliasFor(macId));
  const p = prefs(ctx);
  writeList(p, readList(p).filter((m: MacInfo) => m.macId !== macId));
  Logger.info('pairing removed');
}

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

const PREF_NAME = 'notibridge_pairing';
const LIST_KEY = 'computers';
const LEGACY_KEY_ALIAS = 'notibridge.mac.pairkey'; // 1.0.x 只支持一台 Mac 时的密钥别名
const KEY_ALIAS_PREFIX = 'notibridge.computer.pairkey.';
// v1.2：在手机上删除、但还没来得及通知到的电脑（电脑上线后发 unpair，让电脑也取消配对）
const PENDING_KEY = 'pendingUnpair';
const PENDING_ALIAS_PREFIX = 'notibridge.computer.unpairkey.';
// v1.2：被电脑取消配对、已自动从列表移除的电脑名称，等界面提示一次
const NOTICE_KEY = 'unpairNotices';
// 1.1.0：配对方式版本（协议 v2，CPace）。小于 2 时清除旧配对一次
const SCHEMA_KEY = 'pairingSchema';
const PAIRING_SCHEMA = 2;
const REPAIR_NOTICE_KEY = 'repairNotice';
const PENDING_SINCE_PREFIX = 'unpairSince.';

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

/** filter 为 'mac' / 'windows' 时只保留对应平台；为空时全部保留。旧版 Mac 不发送平台，按 Mac 处理。 */
export function matchesPlatform(m: MacInfo, filter: string): boolean {
  if (filter.length === 0) {
    return true;
  }
  return filter === 'windows' ? m.platform === 'windows' : m.platform !== 'windows';
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

/**
 * 1.1.0：协议 v1 的配对全部作废。第一次读配对列表时（App 界面或通知订阅扩展，谁先运行都行）清除一次，
 * 以前有过配对时记下提示，首页弹一次“请重新配对”。
 */
function migratePairingSchema(p: preferences.Preferences): void {
  if ((p.getSync(SCHEMA_KEY, 0) as number) >= PAIRING_SCHEMA) {
    return;
  }
  migrateLegacy(p);
  const list = readList(p);
  const pending = readPending(p);
  list.forEach((m: MacInfo) => removeSecret(aliasFor(m.macId)));
  pending.forEach((m: MacInfo) => removeSecret(PENDING_ALIAS_PREFIX + m.macId));
  p.deleteSync(LIST_KEY);
  p.deleteSync(PENDING_KEY);
  p.deleteSync(NOTICE_KEY);
  if (list.length > 0 || pending.length > 0) {
    p.putSync(REPAIR_NOTICE_KEY, true);
  }
  p.putSync(SCHEMA_KEY, PAIRING_SCHEMA);
  p.flushSync();
  Logger.info(`pairing schema migrated to v${PAIRING_SCHEMA}: cleared ${list.length} pairing(s)`);
}

/** 取出并清除“请重新配对”提示（升级前有过配对时才有） */
export function takeRepairNotice(ctx: common.Context): boolean {
  const p = prefs(ctx);
  migratePairingSchema(p);
  const v = p.getSync(REPAIR_NOTICE_KEY, false) as boolean;
  if (v) {
    p.deleteSync(REPAIR_NOTICE_KEY);
    p.flushSync();
  }
  return v;
}

/** 所有已配对、且密钥仍在的电脑。 */
export function pairedComputers(ctx: common.Context): Array<MacInfo> {
  const p = prefs(ctx);
  migratePairingSchema(p);
  return readList(p).filter((m: MacInfo) => loadKeyFor(m.macId) !== undefined);
}

export function findComputer(ctx: common.Context, macId: string): MacInfo | undefined {
  return pairedComputers(ctx).find((m: MacInfo) => m.macId === macId);
}

/** 配对成功：保存（同一台电脑重新配对时覆盖旧的）。 */
export function saveComputer(ctx: common.Context, info: MacInfo, key: Uint8Array): void {
  migratePairingSchema(prefs(ctx)); // 先完成升级清理，避免之后把刚配好的 v2 配对当成旧配对删掉
  clearPendingUnpair(ctx, info.macId); // 重新配对了同一台电脑：不再需要通知它取消配对
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

/**
 * 删除一台电脑。notifyLater = true（用户在手机上删除）时，把密钥转存到待通知列表，
 * 之后连上这台电脑时发 unpair，让电脑也取消配对；电脑主动取消配对时为 false。
 */
export function forgetComputer(ctx: common.Context, macId: string, notifyLater: boolean = false): void {
  const p = prefs(ctx);
  const list = readList(p);
  if (notifyLater) {
    const m = list.find((x: MacInfo) => x.macId === macId);
    const key = loadKeyFor(macId);
    if (m !== undefined && key !== undefined) {
      addSecret(PENDING_ALIAS_PREFIX + macId, key);
      const pending = readPending(p).filter((x: MacInfo) => x.macId !== macId);
      pending.push(m);
      p.putSync(PENDING_KEY, JSON.stringify(pending));
      p.putSync(PENDING_SINCE_PREFIX + macId, Date.now());
    }
  }
  removeSecret(aliasFor(macId));
  writeList(p, list.filter((m: MacInfo) => m.macId !== macId));
  Logger.info(`pairing removed notifyLater=${notifyLater}`);
}

// ---------- 待通知电脑取消配对（v1.2） ----------

function readPending(p: preferences.Preferences): Array<MacInfo> {
  const raw = p.getSync(PENDING_KEY, '') as string;
  if (raw.length === 0) {
    return [];
  }
  try {
    return JSON.parse(raw) as Array<MacInfo>;
  } catch (e) {
    return [];
  }
}

/** 在手机上删除了、但电脑还不知道的电脑（密钥仍在待通知别名下）。 */
export function pendingUnpairs(ctx: common.Context): Array<MacInfo> {
  const p = prefs(ctx);
  migratePairingSchema(p);
  return readPending(p).filter((m: MacInfo) => loadPendingKey(m.macId) !== undefined);
}

export function loadPendingKey(macId: string): Uint8Array | undefined {
  return querySecret(PENDING_ALIAS_PREFIX + macId);
}

/** 什么时候在手机上删除的（毫秒，0 = 未知），用来决定何时放弃通知电脑 */
export function pendingSince(ctx: common.Context, macId: string): number {
  return prefs(ctx).getSync(PENDING_SINCE_PREFIX + macId, 0) as number;
}

/** 已通知到电脑（或一直无法确认、已放弃）：删掉保留的密钥。 */
export function clearPendingUnpair(ctx: common.Context, macId: string): void {
  removeSecret(PENDING_ALIAS_PREFIX + macId);
  const p = prefs(ctx);
  p.deleteSync(PENDING_SINCE_PREFIX + macId);
  const pending = readPending(p);
  if (pending.find((m: MacInfo) => m.macId === macId) !== undefined) {
    p.putSync(PENDING_KEY, JSON.stringify(pending.filter((m: MacInfo) => m.macId !== macId)));
  }
  p.flushSync();
}

/** 局域网发现到待通知的电脑换了地址时更新。 */
export function updatePendingAddress(ctx: common.Context, macId: string, host: string, port: number): void {
  const p = prefs(ctx);
  const pending = readPending(p);
  const m = pending.find((x: MacInfo) => x.macId === macId);
  if (m === undefined || (m.host === host && m.port === port)) {
    return;
  }
  m.host = host;
  m.port = port;
  p.putSync(PENDING_KEY, JSON.stringify(pending));
  p.flushSync();
}

// ---------- 电脑取消配对的提示（v1.2） ----------

export function addUnpairNotice(ctx: common.Context, name: string): void {
  const p = prefs(ctx);
  const raw = p.getSync(NOTICE_KEY, '') as string;
  let list: Array<string> = [];
  try {
    list = raw.length === 0 ? [] : JSON.parse(raw) as Array<string>;
  } catch (e) {
    list = [];
  }
  if (list.indexOf(name) < 0) {
    list.push(name);
  }
  p.putSync(NOTICE_KEY, JSON.stringify(list));
  p.flushSync();
}

/** 取出并清空待提示的电脑名称。 */
export function takeUnpairNotices(ctx: common.Context): Array<string> {
  const p = prefs(ctx);
  const raw = p.getSync(NOTICE_KEY, '') as string;
  if (raw.length === 0) {
    return [];
  }
  p.deleteSync(NOTICE_KEY);
  p.flushSync();
  try {
    return JSON.parse(raw) as Array<string>;
  } catch (e) {
    return [];
  }
}

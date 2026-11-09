import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

import { SyncSettings } from './FilterLogic';

/**
 * 手机端过滤设置的存储。过滤逻辑本身在 FilterLogic.ets（纯逻辑，可在电脑上测试）。
 * 与 Mac 端 SyncFilter 的默认关键词保持一致；电脑端还会再过滤一次。
 */
export { blockReason, decide, Decision, DEFAULT_SENSITIVE_KEYWORDS, extractOtp, SyncSettings } from './FilterLogic';

const PREF_NAME = 'notibridge_sync';

function prefs(ctx: common.Context): preferences.Preferences {
  // 设置可能被另一个进程（通知订阅扩展）改过：先丢弃本进程缓存，保证读到磁盘上的最新值
  try {
    preferences.removePreferencesFromCacheSync(ctx, { name: PREF_NAME });
  } catch (e) {
    // 首次读取时没有缓存，忽略
  }
  return preferences.getPreferencesSync(ctx, { name: PREF_NAME });
}

export function loadSettings(ctx: common.Context): SyncSettings {
  const p = prefs(ctx);
  const blocked = p.getSync('blockedBundles', '[]') as string;
  return {
    paused: p.getSync('paused', false) as boolean,
    blockSensitive: p.getSync('blockSensitive', true) as boolean,
    blockedBundles: JSON.parse(blocked) as Array<string>,
    copyOtp: p.getSync('copyOtp', true) as boolean,
    updatedAt: p.getSync('updatedAt', 0) as number,
    allowSensitiveOtp: p.getSync('allowSensitiveOtp', false) as boolean,
  };
}

/** 保存本机修改：刷新修改时间。 */
export function saveSettings(ctx: common.Context, s: SyncSettings): void {
  s.updatedAt = Date.now();
  writeSettings(ctx, s);
}

/** 写入设置（保留 s.updatedAt，用于应用电脑同步过来的设置）。 */
export function writeSettings(ctx: common.Context, s: SyncSettings): void {
  const p = prefs(ctx);
  p.putSync('paused', s.paused);
  p.putSync('blockSensitive', s.blockSensitive);
  p.putSync('blockedBundles', JSON.stringify(s.blockedBundles));
  p.putSync('copyOtp', s.copyOtp);
  p.putSync('updatedAt', s.updatedAt);
  p.putSync('allowSensitiveOtp', s.allowSensitiveOtp);
  p.flushSync();
}

import { asset } from '@kit.AssetStoreKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { clearRecords } from './NotificationStore';
import { unsubscribe } from './SubscriptionService';
import { utf8 } from './Crypto';
import { Logger } from './Logger';
import { MacInfo } from './PairingStore';

/** 本应用用到的全部 preferences 文件。 */
const PREF_FILES: Array<string> = ['notibridge_pairing', 'notibridge_sync', 'notibridge_ui'];
/** 已知的 Asset 别名（查询全部失败时兜底）。 */
const KNOWN_ALIASES: Array<string> = ['notibridge.mac.pairkey'];
const ALIAS_PREFIX = 'notibridge.computer.pairkey.';

export interface ResetResult {
  assets: number;
  prefs: number;
  unsubscribed: boolean;
  errors: Array<string>;
}

function removeAlias(alias: Uint8Array): boolean {
  const q: asset.AssetMap = new Map();
  q.set(asset.Tag.ALIAS, alias);
  try {
    asset.removeSync(q);
    return true;
  } catch (e) {
    return false; // 24000002 = 不存在
  }
}

/** 删除本应用写入 Asset Store 的所有密钥（各台电脑的配对密钥 + 1.0.x 旧别名）。返回删除数。 */
function removeAllAssets(knownMacIds: Array<string>): number {
  let removed = 0;
  // 不带别名查询 = 本应用的全部 Asset（只取属性，不取密钥明文）
  const q: asset.AssetMap = new Map();
  q.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
  try {
    const all = asset.querySync(q);
    const decoder = util.TextDecoder.create('utf-8');
    for (const item of all) {
      const alias = item.get(asset.Tag.ALIAS) as Uint8Array;
      if (alias !== undefined && removeAlias(alias)) {
        removed++;
        Logger.info(`reset: removed asset ${decoder.decodeToString(alias).slice(0, 40)}`);
      }
    }
  } catch (e) {
    // 24000002 = 一个都没有
  }
  const aliases: Array<string> = KNOWN_ALIASES.concat(knownMacIds.map((id: string) => ALIAS_PREFIX + id));
  for (const a of aliases) {
    if (removeAlias(utf8(a))) {
      removed++;
    }
  }
  return removed;
}

function pairedMacIds(ctx: common.Context): Array<string> {
  try {
    preferences.removePreferencesFromCacheSync(ctx, { name: 'notibridge_pairing' });
    const raw = preferences.getPreferencesSync(ctx, { name: 'notibridge_pairing' }).getSync('computers', '') as string;
    if (raw.length === 0) {
      return [];
    }
    const list = JSON.parse(raw) as Array<MacInfo>;
    return list.map((m: MacInfo) => m.macId);
  } catch (e) {
    return [];
  }
}

/**
 * 清除所有数据：停止通知订阅（扩展不再被拉起转发）、删除所有电脑的配对密钥（Asset）、
 * 设备 ID、配对列表、过滤和同步设置、引导状态、使用方式，以及本机的通知记录。
 * 电脑端认证失败后会断开连接；电脑上的配对记录需要在电脑端另外删除。
 */
export async function resetAllData(ctx: common.Context): Promise<ResetResult> {
  const result: ResetResult = { assets: 0, prefs: 0, unsubscribed: false, errors: [] };
  try {
    await unsubscribe();
    result.unsubscribed = true;
  } catch (e) {
    // 没有订阅时也会报错，忽略
  }
  result.assets = removeAllAssets(pairedMacIds(ctx));
  for (const name of PREF_FILES) {
    try {
      await preferences.deletePreferences(ctx, { name: name });
      result.prefs++;
    } catch (e) {
      result.errors.push(`${name}: ${JSON.stringify(e)}`);
    }
  }
  clearRecords(ctx.filesDir);
  Logger.info(`reset: assets=${result.assets} prefs=${result.prefs} unsubscribed=${result.unsubscribed}`);
  return result;
}

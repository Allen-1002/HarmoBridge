import { http } from '@kit.NetworkKit';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Logger } from './Logger';

/**
 * 检查 GitHub Releases 上的新版本（只提醒，不安装）。
 * 鸿蒙应用不能自己安装 hap，而且 hap 需要用户自己的调试签名，所以这里只比较版本号，提供“查看新版本”打开发布页。
 */
const LATEST_URL = 'https://api.github.com/repos/Allen-1002/NotiBridge/releases/latest';
const UI_PREF = 'notibridge_ui';
const CHECK_INTERVAL_MS = 6 * 3600 * 1000;

export interface UpdateInfo {
  current: string;
  latest: string;
  hasUpdate: boolean;
  pageUrl: string;
  checkedAt: number;
}

interface ReleaseJson {
  tag_name?: string;
  html_url?: string;
  draft?: boolean;
  prerelease?: boolean;
}

/** "v1.3.0" / "1.3" -> [1,3,0]；无法解析返回 undefined。忽略 - 或 + 之后的预发布后缀。 */
export function parseVersion(s: string): Array<number> | undefined {
  let t = s.trim();
  if (t.startsWith('v') || t.startsWith('V')) {
    t = t.substring(1);
  }
  const cut = t.search(/[-+]/);
  if (cut >= 0) {
    t = t.substring(0, cut);
  }
  const parts = t.split('.');
  if (parts.length === 0 || parts.length > 4) {
    return undefined;
  }
  const out: Array<number> = [];
  for (const p of parts) {
    if (!/^[0-9]+$/.test(p)) {
      return undefined;
    }
    out.push(parseInt(p, 10));
  }
  return out;
}

/** latest 是否比 current 新（无法解析时视为不新） */
export function isNewer(latest: string, current: string): boolean {
  const a = parseVersion(latest);
  const b = parseVersion(current);
  if (a === undefined || b === undefined) {
    return false;
  }
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const x = i < a.length ? a[i] : 0;
    const y = i < b.length ? b[i] : 0;
    if (x !== y) {
      return x > y;
    }
  }
  return false;
}

export function currentVersion(): string {
  try {
    return bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
  } catch (e) {
    return '0.0.0';
  }
}

function pref(ctx: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(ctx, { name: UI_PREF });
}

/** 上次检查的结果（没有检查过返回 undefined） */
export function cachedUpdate(ctx: common.Context): UpdateInfo | undefined {
  const p = pref(ctx);
  const latest = p.getSync('updateLatest', '') as string;
  if (latest.length === 0) {
    return undefined;
  }
  const cur = currentVersion();
  return {
    current: cur,
    latest: latest,
    hasUpdate: isNewer(latest, cur),
    pageUrl: p.getSync('updatePage', '') as string,
    checkedAt: p.getSync('updateCheckedAt', 0) as number,
  };
}

/** 联网检查。force=false 时距上次检查不到 6 小时直接返回缓存结果。失败时抛出错误。 */
export async function checkUpdate(ctx: common.Context, force: boolean): Promise<UpdateInfo | undefined> {
  const cached = cachedUpdate(ctx);
  if (!force && cached !== undefined && Date.now() - cached.checkedAt < CHECK_INTERVAL_MS) {
    return cached;
  }
  const req = http.createHttp();
  try {
    Logger.info(`检查更新：${LATEST_URL}（当前 ${currentVersion()}）`);
    const resp = await req.request(LATEST_URL, {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': 'NotiBridge-Updater', 'Accept': 'application/vnd.github+json' },
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 15000,
    });
    if (resp.responseCode !== 200) {
      throw new Error(`GitHub 返回 HTTP ${resp.responseCode}`);
    }
    const r = JSON.parse(resp.result as string) as ReleaseJson;
    if (r.draft === true || r.prerelease === true || r.tag_name === undefined) {
      throw new Error('最新 Release 无效（草稿或预发布）');
    }
    let latest = r.tag_name.trim();
    if (latest.startsWith('v') || latest.startsWith('V')) {
      latest = latest.substring(1);
    }
    const page = r.html_url !== undefined ? r.html_url : 'https://github.com/Allen-1002/NotiBridge/releases/latest';
    const p = pref(ctx);
    p.putSync('updateLatest', latest);
    p.putSync('updatePage', page);
    p.putSync('updateCheckedAt', Date.now());
    p.flushSync();
    const cur = currentVersion();
    Logger.info(`最新版本 ${latest}，当前 ${cur}`);
    return {
      current: cur, latest: latest, hasUpdate: isNewer(latest, cur), pageUrl: page, checkedAt: Date.now()
    };
  } finally {
    req.destroy();
  }
}

/** 用浏览器打开发布页 */
export function openReleasePage(ctx: common.UIAbilityContext, url: string): void {
  const want: Want = {
    action: 'ohos.want.action.viewData',
    entities: ['entity.system.browsable'],
    uri: url.length > 0 ? url : 'https://github.com/Allen-1002/NotiBridge/releases/latest',
  };
  ctx.startAbility(want).catch((e: Error) => Logger.warn(`打开发布页失败：${e.message}`));
}

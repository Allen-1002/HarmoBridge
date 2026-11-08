import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 手机端过滤：在通知离开手机之前判断。默认拦截验证码、银行、支付类通知。
 * 与 Mac 端 SyncFilter 的默认关键词保持一致；Mac 端还会再过滤一次。
 */
export const DEFAULT_SENSITIVE_KEYWORDS: Array<string> = [
  '验证码', '校验码', '动态码', '动态密码', '确认码', '安全码', 'otp', 'verification code',
  '银行', '信用卡', '余额', '转账', '支付', '付款', '收款',
];

const PREF_NAME = 'harmobridge_sync';

export interface SyncSettings {
  paused: boolean;
  blockSensitive: boolean;
  blockedBundles: Array<string>;
  copyOtp: boolean; // 验证码发送到电脑并复制到剪贴板
  updatedAt: number; // 最近一次修改时间（毫秒），与电脑双向同步时“后改的为准”
}

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
  p.flushSync();
}

/** 返回空字符串表示允许转发，否则返回拦截原因。 */
export function blockReason(s: SyncSettings, bundleName: string, title: string, text: string): string {
  if (s.paused) {
    return '同步已暂停';
  }
  if (s.blockedBundles.indexOf(bundleName) >= 0) {
    return '应用已屏蔽';
  }
  if (s.blockSensitive) {
    const hay = `${title}\n${text}`.toLowerCase();
    for (const k of DEFAULT_SENSITIVE_KEYWORDS) {
      if (hay.indexOf(k) >= 0) {
        return '疑似敏感内容';
      }
    }
  }
  return '';
}

const OTP_KEYWORDS: Array<string> = ['验证码', '校验码', '动态码', '动态密码', '确认码', '安全码', '激活码', 'otp', 'code'];

/**
 * 从验证码短信/通知中提取验证码（4~8 位数字）。没有关键词或找不到时返回空字符串。
 * 有多个数字时取离关键词最近的一个（相距 40 个字符以内）。
 */
export function extractOtp(title: string, text: string): string {
  const content = `${title} ${text}`;
  const lower = content.toLowerCase();
  const keyPos: Array<number> = [];
  for (const k of OTP_KEYWORDS) {
    let i = lower.indexOf(k);
    while (i >= 0) {
      keyPos.push(i);
      i = lower.indexOf(k, i + k.length);
    }
  }
  if (keyPos.length === 0) {
    return '';
  }
  const re = /(^|[^0-9])([0-9]{4,8})(?![0-9])/g;
  let best = '';
  let bestDist = Number.MAX_SAFE_INTEGER;
  let m: RegExpExecArray | null = re.exec(content);
  while (m !== null) {
    const start = m.index + m[1].length;
    for (const k of keyPos) {
      const d = Math.abs(start - k);
      if (d <= 40 && d < bestDist) {
        bestDist = d;
        best = m[2];
      }
    }
    m = re.exec(content);
  }
  return best;
}

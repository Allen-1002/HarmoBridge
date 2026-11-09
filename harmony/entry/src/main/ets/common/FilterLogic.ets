/**
 * 手机端过滤与通知记录的纯逻辑（不引用系统 Kit），与 Android Filter.kt / Records.kt 一致，
 * 可以在电脑上用 Node 测试（harmony/scripts/test_cpace.mjs）。
 */
export const DEFAULT_SENSITIVE_KEYWORDS: Array<string> = [
  '验证码', '校验码', '动态码', '动态密码', '确认码', '安全码', 'otp', 'verification code',
  '银行', '信用卡', '余额', '转账', '支付', '付款', '收款',
];

/** 银行 / 支付类内容：这类验证码默认不同步（除非用户明确允许） */
export const FINANCE_KEYWORDS: Array<string> = ['银行', '信用卡', '余额', '转账', '支付', '付款', '收款', '还款', '贷款',
  'bank', 'payment'];

/** 包名里带这些词的视为银行 / 支付类应用 */
export const FINANCE_APP_HINTS: Array<string> = ['bank', 'alipay', 'wallet', 'pay', 'finance', 'securities', 'stock',
  'icbc', 'ccb', 'cmb', 'abchina', 'boc'];

export interface SyncSettings {
  paused: boolean;
  blockSensitive: boolean;
  blockedBundles: Array<string>;
  copyOtp: boolean; // 验证码同步：只把验证码发到电脑剪贴板
  updatedAt: number; // 最近一次修改时间（毫秒），与电脑双向同步时“后改的为准”
  allowSensitiveOtp: boolean; // 只在手机本地：银行/支付类验证码也同步（默认不同步）
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

export function isFinance(bundleName: string, title: string, text: string): boolean {
  const hay = `${title}\n${text}`.toLowerCase();
  const b = bundleName.toLowerCase();
  return FINANCE_KEYWORDS.some((k: string) => hay.indexOf(k) >= 0) ||
    FINANCE_APP_HINTS.some((k: string) => b.indexOf(k) >= 0);
}

export type FilterAction = 'forward' | 'otp' | 'drop';

/** 一条通知的处理结果。record = false 表示连元数据都不记录（敏感内容）。 */
export interface Decision {
  action: FilterAction;
  reason: string;
  otp: string;
  record: boolean;
}

/**
 * 手机端处理顺序（1.1.0 起）：暂停 → 按应用屏蔽（通知和验证码都不发）→ 验证码同步（独立开关；
 * 开启敏感过滤时，银行/支付类验证码默认不发）→ 敏感内容过滤 → 转发。
 */
export function decide(s: SyncSettings, bundleName: string, title: string, text: string): Decision {
  if (s.paused) {
    return { action: 'drop', reason: '同步已暂停', otp: '', record: true };
  }
  if (s.blockedBundles.indexOf(bundleName) >= 0) {
    return { action: 'drop', reason: '应用已屏蔽', otp: '', record: true };
  }
  const otp = s.copyOtp ? extractOtp(title, text) : '';
  if (otp.length > 0) {
    const finance = s.blockSensitive && isFinance(bundleName, title, text);
    if (finance && !s.allowSensitiveOtp) {
      return { action: 'drop', reason: '银行/支付类验证码未同步', otp: '', record: false };
    }
    return { action: 'otp', reason: '验证码已发送', otp: otp, record: true };
  }
  const reason = blockReason(s, bundleName, title, text);
  if (reason.length > 0) {
    return { action: 'drop', reason: reason, otp: '', record: reason !== '疑似敏感内容' };
  }
  return { action: 'forward', reason: '已转发', otp: '', record: true };
}

// ---------- 通知记录（只存元数据） ----------

export interface EventRecord {
  kind: string; // 'publish' | 'cancel'
  recordTime: number;
  hashCode?: string;
  bundleName?: string;
  appName?: string;
  deliveryTime?: number;
  result?: string; // 处理结果：已转发 / 验证码已发送 / 应用已屏蔽 …
  targets?: string; // 发往哪些电脑（名称，顿号分隔）
  cancelHashCodes?: Array<string>;
}

export const MAX_RECORDS = 200;
export const MAX_RECORD_BYTES = 256 * 1024;
export const MAX_RECORD_AGE_MS = 7 * 24 * 3600 * 1000;

/** 按时间（7 天）、条数（200）、字节数（256 KB，JSON Lines）三重上限裁剪；list 按时间从旧到新。 */
export function trimRecords(list: Array<EventRecord>, now: number, byteLen: (s: string) => number): Array<EventRecord> {
  let out = list.filter((r: EventRecord) => now - r.recordTime < MAX_RECORD_AGE_MS);
  if (out.length > MAX_RECORDS) {
    out = out.slice(out.length - MAX_RECORDS);
  }
  let size = 0;
  const lens: Array<number> = out.map((r: EventRecord) => byteLen(JSON.stringify(r)) + 1);
  lens.forEach((n: number) => {
    size += n;
  });
  let start = 0;
  while (start < out.length && size > MAX_RECORD_BYTES) {
    size -= lens[start];
    start++;
  }
  return out.slice(start);
}

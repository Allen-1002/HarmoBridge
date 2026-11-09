import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x4842; // 'HB'
const TAG = 'NotiBridge';

/**
 * 统一日志。只允许输出非隐私信息（状态、错误码、包名、hashCode）。
 * 通知标题/正文绝不能直接传入；需要时先用 maskText() 处理。
 */
export class Logger {
  static info(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
  }

  static warn(msg: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', msg);
  }

  static error(msg: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
  }
}

/** 隐私脱敏：只保留长度信息，例如 "<12 chars>"。 */
export function maskText(text: string | undefined): string {
  if (text === undefined || text.length === 0) {
    return '<empty>';
  }
  return `<${text.length} chars>`;
}

/** 蓝牙地址脱敏：11:22:33:AA:BB:FF -> **:**:**:**:BB:FF */
export function maskAddr(addr: string): string {
  const parts = addr.split(':');
  if (parts.length !== 6) {
    return '<invalid addr>';
  }
  return `**:**:**:**:${parts[4]}:${parts[5]}`;
}

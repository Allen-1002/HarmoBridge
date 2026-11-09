import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';
import { displayName, FoundMac, MacDiscovery } from './MacDiscovery';
import { MacInfo, updateComputerAddress } from './PairingStore';

// 每台电脑两次重新发现之间至少间隔这么久，避免电脑关机时反复搜索
const MIN_INTERVAL_MS = 60000;
const lastRun: Map<string, number> = new Map<string, number>();

/**
 * 设备 ID 绑定：连不上已配对的电脑时，在局域网里按电脑 ID 重新查找（mDNS TXT 记录或“你是谁”探测），
 * 找到新地址就保存，返回 true 由调用方重连。只在同一局域网内有效。
 */
export function rediscover(ctx: common.Context, mac: MacInfo, timeoutMs: number = 6000): Promise<boolean> {
  const now = Date.now();
  const last = lastRun.get(mac.macId);
  if (last !== undefined && now - last < MIN_INTERVAL_MS) {
    return Promise.resolve(false);
  }
  lastRun.set(mac.macId, now);
  return new Promise<boolean>((resolve: (v: boolean) => void) => {
    const d = new MacDiscovery();
    let done = false;
    const finish = (v: boolean): void => {
      if (done) {
        return;
      }
      done = true;
      d.stop();
      resolve(v);
    };
    try {
      d.start(ctx, (m: FoundMac) => {
        // 优先按 ID 匹配；旧版 Mac 没有 ID 时退回按名称匹配
        const same = m.id.length > 0 ? m.id === mac.macId : displayName(m.name) === mac.macName;
        if (!same) {
          return;
        }
        if (m.host === mac.host && m.port === mac.port) {
          finish(false); // 地址没变，是电脑本身没响应
          return;
        }
        updateComputerAddress(ctx, mac.macId, m.host, m.port);
        Logger.info(`rediscover: ${mac.macId.substring(0, 8)} 地址已更新`);
        finish(true);
      }, () => finish(false), timeoutMs);
    } catch (e) {
      Logger.warn('rediscover: mdns 不可用');
      finish(false);
    }
  });
}

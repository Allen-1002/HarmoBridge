import { mdns } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fromUtf8 } from './Crypto';
import { probeComputer, ProbeResult } from './ComputerProbe';
import { Logger } from './Logger';

export const SERVICE_TYPE = '_harmobridge._tcp';

export interface FoundMac {
  name: string;
  host: string;
  port: number;
  id: string; // TXT 记录里的电脑 ID（旧版 Mac 没有，为空）
  platform: string; // TXT 记录里的平台，未知时为空
}

/** 服务名形如 “HarmoBridge-电脑名”，返回电脑名。 */
export function displayName(serviceName: string): string {
  return serviceName.startsWith('HarmoBridge-') ? serviceName.substring('HarmoBridge-'.length) : serviceName;
}

function txt(info: mdns.LocalServiceInfo, key: string): string {
  try {
    const attrs = info.serviceAttribute;
    if (attrs === undefined) {
      return '';
    }
    for (const a of attrs) {
      if (a.key === key) {
        return fromUtf8(new Uint8Array(a.value));
      }
    }
  } catch (e) {
    // 部分系统版本不返回 TXT，忽略
  }
  return '';
}

/**
 * 用 mDNS 发现局域网内的 HarmoBridge 电脑（Mac 用 Bonjour、Windows 用系统 DNS-SD 广播 _harmobridge._tcp）。
 * 找不到时可手动输入 IP。
 */
export class MacDiscovery {
  private service: mdns.DiscoveryService | undefined = undefined;
  private timer: number = -1;

  start(ctx: common.Context, onFound: (m: FoundMac) => void, onDone: () => void, timeoutMs: number = 8000): void {
    this.stop();
    const svc = mdns.createDiscoveryService(ctx, SERVICE_TYPE);
    this.service = svc;
    svc.on('serviceFound', (info: mdns.LocalServiceInfo) => {
      mdns.resolveLocalService(ctx, info).then(async (r: mdns.LocalServiceInfo) => {
        if (r.host === undefined || r.port === undefined) {
          return;
        }
        const found: FoundMac = {
          name: r.serviceName, host: r.host.address, port: r.port, id: txt(r, 'id'), platform: txt(r, 'platform'),
        };
        if (found.id.length === 0 || found.platform.length === 0) {
          // TXT 读不到（系统版本差异或旧版 Mac）：直接问电脑“你是谁”
          const p: ProbeResult | undefined = await probeComputer(found.host, found.port);
          if (p !== undefined) {
            found.id = found.id.length > 0 ? found.id : p.id;
            found.platform = found.platform.length > 0 ? found.platform : p.platform;
          }
        }
        onFound(found);
      }).catch((err: BusinessError) => {
        Logger.warn(`mdns resolve failed ${err.code}`);
      });
    });
    svc.startSearchingMDNS();
    this.timer = setTimeout(() => {
      this.stop();
      onDone();
    }, timeoutMs);
  }

  stop(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    if (this.service !== undefined) {
      try {
        this.service.stopSearchingMDNS();
        this.service.off('serviceFound');
      } catch (e) {
        Logger.warn('mdns stop failed');
      }
      this.service = undefined;
    }
  }
}

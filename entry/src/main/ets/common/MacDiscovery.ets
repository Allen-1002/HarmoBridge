import { mdns } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

export const SERVICE_TYPE = '_harmobridge._tcp';

export interface FoundMac {
  name: string;
  host: string;
  port: number;
}

/** 用 mDNS 发现局域网内的 HarmoBridge Mac（Mac 端用 Bonjour 广播）。找不到时可手动输入 IP。 */
export class MacDiscovery {
  private service: mdns.DiscoveryService | undefined = undefined;
  private timer: number = -1;

  start(ctx: common.Context, onFound: (m: FoundMac) => void, onDone: () => void, timeoutMs: number = 8000): void {
    this.stop();
    const svc = mdns.createDiscoveryService(ctx, SERVICE_TYPE);
    this.service = svc;
    svc.on('serviceFound', (info: mdns.LocalServiceInfo) => {
      mdns.resolveLocalService(ctx, info).then((r: mdns.LocalServiceInfo) => {
        if (r.host !== undefined && r.port !== undefined) {
          onFound({ name: r.serviceName, host: r.host.address, port: r.port });
        }
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

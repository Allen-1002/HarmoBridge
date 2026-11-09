import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 探测到的电脑身份（公开信息，不涉及密钥）。 */
export interface ProbeResult {
  id: string; // 电脑 ID；旧版 Mac 不支持探测，为空
  name: string;
  platform: string; // 'mac' | 'windows'
}

interface InfoFrame {
  t: string;
  macId?: string;
  macName?: string;
  platform?: string;
}

/**
 * 向电脑发一条未认证的 {"t":"info"}（“你是谁”），电脑回电脑 ID、名称、平台后断开。
 * 用于局域网发现时 TXT 记录读不到的情况。旧版 Mac 不认识 info，会回 error：按 Mac 处理。
 * 超时或连不上返回 undefined。
 */
export function probeComputer(host: string, port: number, timeoutMs: number = 3000): Promise<ProbeResult | undefined> {
  return new Promise<ProbeResult | undefined>((resolve: (r: ProbeResult | undefined) => void) => {
    const ws = webSocket.createWebSocket();
    let done = false;
    const finish = (r: ProbeResult | undefined): void => {
      if (done) {
        return;
      }
      done = true;
      ws.close().catch(() => {
      });
      resolve(r);
    };
    ws.on('open', () => {
      ws.send(JSON.stringify({ t: 'info' } as InfoFrame)).catch(() => finish(undefined));
    });
    ws.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (err || typeof data !== 'string') {
        return;
      }
      try {
        const f = JSON.parse(data) as InfoFrame;
        if (f.t === 'info') {
          finish({
            id: f.macId === undefined ? '' : f.macId,
            name: f.macName === undefined ? '' : f.macName,
            platform: f.platform === undefined ? 'mac' : f.platform,
          });
        } else if (f.t === 'error') {
          finish({ id: '', name: '', platform: 'mac' }); // 旧版 Mac
        }
      } catch (e) {
        finish(undefined);
      }
    });
    ws.on('error', () => finish(undefined));
    ws.on('close', () => finish(undefined));
    setTimeout(() => finish(undefined), timeoutMs);
    ws.connect(`ws://${host}:${port}`).catch(() => finish(undefined));
  });
}

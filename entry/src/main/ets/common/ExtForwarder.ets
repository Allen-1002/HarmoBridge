import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';
import { LinkState, MacLink, OutgoingNotification } from './MacLink';

/**
 * 在通知订阅扩展进程内使用的转发器。
 * 扩展由系统按需拉起、空闲后销毁，所以这里按需连接 Mac：有消息时连接并认证，发完空闲一段时间后断开。
 * 不做常驻、不做后台保活。
 */
export interface OtpMessage {
  id: string;
  bundleName: string;
  appName: string;
  code: string;
}

interface Pending {
  notify?: OutgoingNotification;
  cancelIds?: Array<string>;
  otp?: OtpMessage;
}

const IDLE_CLOSE_MS = 30000;
const MAX_PENDING = 50;
const STALE_MS = 15000;

export class ExtForwarder {
  private link: MacLink;
  private pending: Array<Pending> = [];
  private idleTimer: number = -1;
  private lastActive: number = 0;
  private retryCount: number = 0;

  constructor(ctx: common.Context) {
    this.link = new MacLink(ctx, {
      onState: (s: LinkState, detail: string) => this.onState(s, detail),
      onLog: (ok: boolean, msg: string) => ok ? Logger.info(`forwarder: ${msg}`) : Logger.warn(`forwarder: ${msg}`),
      onSas: () => {
      },
      onAck: (seq: number, result: string) => {
        this.lastActive = Date.now();
        Logger.info(`forwarder ack seq=${seq} result=${result}`);
      },
    }, false);
  }

  isPaired(): boolean {
    return this.link.pairedMac() !== undefined;
  }

  forward(n: OutgoingNotification): void {
    this.enqueue({ notify: n });
  }

  forwardOtp(o: OtpMessage): void {
    this.enqueue({ otp: o });
  }

  cancel(ids: Array<string>): void {
    this.enqueue({ cancelIds: ids });
  }

  close(): void {
    this.clearIdle();
    this.link.stop();
  }

  private enqueue(p: Pending): void {
    if (!this.isPaired()) {
      Logger.info('forwarder: 未与 Mac 配对，跳过转发');
      return;
    }
    this.pending.push(p);
    if (this.pending.length > MAX_PENDING) {
      this.pending.shift();
    }
    let s = this.link.getState();
    const idleFor = Date.now() - this.lastActive;
    // 扩展进程可能被系统冻结过：计时器没有按时触发，旧连接可能已失效或卡在半路。
    // 距上次活动超过阈值时，丢弃旧连接，重新建立。
    if (s !== 'idle' && s !== 'error' && idleFor > STALE_MS) {
      Logger.warn(`forwarder: 连接状态 ${s} 已 ${Math.round(idleFor / 1000)} 秒无活动，重新连接`);
      this.link.stop();
      s = this.link.getState();
    }
    Logger.info(`forwarder enqueue pending=${this.pending.length} state=${s}`);
    if (s === 'online') {
      this.flush();
    } else if (s === 'idle' || s === 'error') {
      this.lastActive = Date.now();
      this.link.connect();
    }
  }

  private onState(s: LinkState, detail: string): void {
    Logger.info(`forwarder state=${s} ${detail}`);
    this.lastActive = Date.now();
    if (s === 'online') {
      this.retryCount = 0;
      this.flush();
    } else if (s === 'error' && this.pending.length > 0 && this.retryCount < 3) {
      // 有待发消息时有限次重试（2s / 4s / 8s），不做无限重连
      const delay = 2000 * Math.pow(2, this.retryCount);
      this.retryCount++;
      setTimeout(() => {
        if (this.link.getState() === 'error' && this.pending.length > 0) {
          this.lastActive = Date.now();
          this.link.connect();
        }
      }, delay);
    }
  }

  private flush(): void {
    while (this.pending.length > 0 && this.link.getState() === 'online') {
      const p = this.pending.shift()!;
      if (p.notify !== undefined) {
        this.link.sendNotification(p.notify);
      } else if (p.cancelIds !== undefined) {
        this.link.sendCancel(p.cancelIds);
      } else if (p.otp !== undefined) {
        this.link.sendOtp(p.otp.id, p.otp.bundleName, p.otp.appName, p.otp.code);
      }
    }
    this.lastActive = Date.now();
    this.armIdle();
  }

  private armIdle(): void {
    this.clearIdle();
    this.idleTimer = setTimeout(() => {
      this.idleTimer = -1;
      if (this.pending.length === 0) {
        this.link.stop();
      }
    }, IDLE_CLOSE_MS);
  }

  private clearIdle(): void {
    if (this.idleTimer !== -1) {
      clearTimeout(this.idleTimer);
      this.idleTimer = -1;
    }
  }
}

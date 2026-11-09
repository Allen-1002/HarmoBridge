import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';
import { LinkState, MacLink, OutgoingNotification } from './MacLink';
import { MacInfo, pairedComputers } from './PairingStore';
import { PendingUnpair } from './PendingUnpair';

/**
 * 在通知订阅扩展进程内使用的转发器。
 * 扩展由系统按需拉起、空闲后销毁，所以这里按需连接电脑：有消息时连接并认证，发完空闲一段时间后断开。
 * 不做常驻、不做后台保活。
 *
 * 可以同时配对多台电脑（Mac / Windows）：每台电脑一个 PeerForwarder，各自排队、各自连接，
 * 一台电脑关机或不在同一网络不影响其他电脑收到通知。
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
  private ctx: common.Context;
  private peers: Map<string, PeerForwarder> = new Map<string, PeerForwarder>();

  constructor(ctx: common.Context) {
    this.ctx = ctx;
  }

  /** 按最新的配对列表增删转发器（用户可能刚在 App 里添加或删除了电脑）。 */
  private sync(): Array<PeerForwarder> {
    const list: Array<MacInfo> = pairedComputers(this.ctx);
    const ids: Array<string> = list.map((m: MacInfo) => m.macId);
    const stale: Array<string> = [];
    this.peers.forEach((p: PeerForwarder, id: string) => {
      if (ids.indexOf(id) < 0) {
        p.close();
        stale.push(id);
      }
    });
    stale.forEach((id: string) => {
      this.peers.delete(id);
    });
    const out: Array<PeerForwarder> = [];
    list.forEach((m: MacInfo) => {
      let p = this.peers.get(m.macId);
      if (p === undefined) {
        p = new PeerForwarder(this.ctx, m);
        this.peers.set(m.macId, p);
      }
      out.push(p);
    });
    if (out.length === 0) {
      Logger.info('forwarder: 未配对任何电脑，跳过转发');
    }
    return out;
  }

  isPaired(): boolean {
    return pairedComputers(this.ctx).length > 0;
  }

  forward(n: OutgoingNotification): void {
    this.sync().forEach((p: PeerForwarder) => p.forward(n));
    // 顺便通知在手机上删除过、当时不在线的电脑取消配对（有最短间隔限制）
    PendingUnpair.flush(this.ctx);
  }

  forwardOtp(o: OtpMessage): void {
    this.sync().forEach((p: PeerForwarder) => p.forwardOtp(o));
  }

  cancel(ids: Array<string>): void {
    this.sync().forEach((p: PeerForwarder) => p.cancel(ids));
  }

  close(): void {
    this.peers.forEach((p: PeerForwarder) => p.close());
    this.peers.clear();
  }
}

/** 转发到一台电脑。 */
class PeerForwarder {
  private link: MacLink;
  private tag: string;
  private pending: Array<Pending> = [];
  private idleTimer: number = -1;
  private lastActive: number = 0;
  private retryCount: number = 0;

  constructor(ctx: common.Context, mac: MacInfo) {
    this.tag = mac.macId.substring(0, 8);
    this.link = new MacLink(ctx, {
      onState: (s: LinkState, detail: string) => this.onState(s, detail),
      onLog: (ok: boolean, msg: string) => ok ? Logger.info(`forwarder[${this.tag}]: ${msg}`) :
      Logger.warn(`forwarder[${this.tag}]: ${msg}`),
      onSas: () => {
      },
      onAck: (seq: number, result: string) => {
        this.lastActive = Date.now();
        Logger.info(`forwarder[${this.tag}] ack seq=${seq} result=${result}`);
      },
    }, false, mac);
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
    this.pending.push(p);
    if (this.pending.length > MAX_PENDING) {
      this.pending.shift();
    }
    let s = this.link.getState();
    const idleFor = Date.now() - this.lastActive;
    // 扩展进程可能被系统冻结过：计时器没有按时触发，旧连接可能已失效或卡在半路。
    // 距上次活动超过阈值时，丢弃旧连接，重新建立。
    if (s !== 'idle' && s !== 'error' && idleFor > STALE_MS) {
      Logger.warn(`forwarder[${this.tag}]: 连接状态 ${s} 已 ${Math.round(idleFor / 1000)} 秒无活动，重新连接`);
      this.link.stop();
      s = this.link.getState();
    }
    Logger.info(`forwarder[${this.tag}] enqueue pending=${this.pending.length} state=${s}`);
    if (s === 'online') {
      this.flush();
    } else if (s === 'idle' || s === 'error') {
      this.lastActive = Date.now();
      this.link.connect();
    }
  }

  private onState(s: LinkState, detail: string): void {
    Logger.info(`forwarder[${this.tag}] state=${s} ${detail}`);
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

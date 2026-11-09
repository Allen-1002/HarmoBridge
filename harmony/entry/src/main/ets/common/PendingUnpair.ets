import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';
import { LinkState, MacLink } from './MacLink';
import { clearPendingUnpair, loadPendingKey, MacInfo, pendingSince, pendingUnpairs } from './PairingStore';

/** 同一台电脑两次尝试之间至少间隔这么久（除非刚在局域网里发现它） */
const MIN_INTERVAL_MS = 30000;
/** 认证后等电脑回执的时间；旧版电脑不认识 unpair、不会回执 */
const ACK_WAIT_MS = 3000;
const GIVE_UP_MS = 15000;
/** v2：电脑回 unknown_device / auth_failed 未经认证（可能是伪造的），不立即放弃，最多重试这么久 */
const MAX_PENDING_MS = 7 * 24 * 3600 * 1000;

export type UnpairOutcome = 'delivered' | 'notPaired' | 'oldVersion' | 'offline';

const inflight: Set<string> = new Set<string>();
const lastTry: Map<string, number> = new Map<string, number>();

/**
 * 双向取消配对：用户在手机上删除了电脑，但当时电脑不一定在线。
 * 删除时密钥转存到待通知列表；之后每次打开 App、通知转发、局域网发现到这台电脑时，
 * 用这把密钥认证后发送 unpair，让电脑也删除这台手机。只有认证后的 ack(unpaired) 才算送达；
 * 未认证的错误回复不会让手机提前丢掉密钥（最多重试 7 天）。
 */
export class PendingUnpair {
  /** 尝试通知所有待通知的电脑（force = 不受最短间隔限制）。 */
  static flush(ctx: common.Context, onlyMacId?: string, force: boolean = false,
    onDone?: (mac: MacInfo, r: UnpairOutcome) => void): void {
    let list: Array<MacInfo> = [];
    try {
      list = pendingUnpairs(ctx);
    } catch (e) {
      return;
    }
    const now = Date.now();
    list.forEach((m: MacInfo) => {
      if (onlyMacId !== undefined && m.macId !== onlyMacId) {
        return;
      }
      if (inflight.has(m.macId)) {
        return;
      }
      const last = lastTry.get(m.macId);
      if (!force && last !== undefined && now - last < MIN_INTERVAL_MS) {
        return;
      }
      lastTry.set(m.macId, now);
      PendingUnpair.runOne(ctx, m, (r: UnpairOutcome) => {
        if (onDone !== undefined) {
          onDone(m, r);
        }
      });
    });
  }

  private static runOne(ctx: common.Context, mac: MacInfo, onDone: (r: UnpairOutcome) => void): void {
    const key = loadPendingKey(mac.macId);
    if (key === undefined) {
      clearPendingUnpair(ctx, mac.macId);
      return;
    }
    inflight.add(mac.macId);
    let finished = false;
    let link: MacLink | undefined = undefined;
    const finish = (r: UnpairOutcome): void => {
      if (finished) {
        return;
      }
      finished = true;
      inflight.delete(mac.macId);
      link?.stop();
      if (r !== 'offline') {
        clearPendingUnpair(ctx, mac.macId);
      }
      Logger.info(`pending unpair ${mac.macId.substring(0, 8)}: ${r}`);
      onDone(r);
    };
    link = new MacLink(ctx, {
      onState: (s: LinkState, detail: string): void => {
        if (s === 'online') {
          // 旧版电脑不认识 unpair，会忽略且不回执：等一会儿没有回执就放弃（无法让旧版电脑自动删除）
          setTimeout(() => finish('oldVersion'), ACK_WAIT_MS);
        } else if (s === 'error') {
          // 电脑说不认识这台手机：可能早已删除，也可能是局域网上有人伪造回复。保留密钥继续重试，超过 7 天才放弃。
          const denied = detail === 'unknown_device' || detail === 'auth_failed';
          const since = pendingSince(ctx, mac.macId);
          const expired = since > 0 && Date.now() - since > MAX_PENDING_MS;
          finish(denied && expired ? 'notPaired' : 'offline');
        }
      },
      onLog: (ok: boolean, msg: string): void => {
        if (!ok) {
          Logger.warn(`pending unpair: ${msg}`);
        }
      },
      onSas: (): void => {
      },
      onAck: (seq: number, result: string): void => {
        if (result === 'unpaired') {
          finish('delivered');
        }
      },
    }, false, mac);
    setTimeout(() => finish('offline'), GIVE_UP_MS);
    link.connectForUnpair(mac, key);
  }
}

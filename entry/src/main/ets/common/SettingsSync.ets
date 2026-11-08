import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';
import { LinkState, MacLink } from './MacLink';
import { MacInfo, pairedComputers } from './PairingStore';

/**
 * 手机界面上改了同步开关，或打开 App 时，临时连一次每台已配对的电脑交换设置（连上即自动交换），随后断开。
 * 未配对或连不上时静默跳过：下一条通知转发时也会自动交换。
 * 手机是多台电脑之间的“中转”：从某台电脑拿到更新的设置后，会再推给其他电脑一次。
 */
export class SettingsSync {
  static run(ctx: common.Context, onDone?: (changed: boolean) => void, relay: boolean = true): void {
    const list: Array<MacInfo> = pairedComputers(ctx);
    if (list.length === 0) {
      if (onDone !== undefined) {
        onDone(false);
      }
      return;
    }
    let remaining = list.length;
    let changed = false;
    list.forEach((m: MacInfo) => {
      SettingsSync.runOne(ctx, m, (c: boolean) => {
        changed = changed || c;
        remaining--;
        if (remaining > 0) {
          return;
        }
        if (changed && relay && list.length > 1) {
          // 有电脑上的设置更新：再推一轮，让其他电脑也拿到
          SettingsSync.run(ctx, undefined, false);
        }
        if (onDone !== undefined) {
          onDone(changed);
        }
      });
    });
  }

  private static runOne(ctx: common.Context, mac: MacInfo, onDone: (changed: boolean) => void): void {
    let changed = false;
    let finished = false;
    let link: MacLink | undefined = undefined;
    const finish = (): void => {
      if (finished) {
        return;
      }
      finished = true;
      link?.stop();
      onDone(changed);
    };
    link = new MacLink(ctx, {
      onState: (s: LinkState): void => {
        if (s === 'online') {
          // 等电脑回传它的设置
          setTimeout(() => finish(), 1500);
        } else if (s === 'error') {
          finish();
        }
      },
      onLog: (ok: boolean, msg: string): void => {
        if (!ok) {
          Logger.warn(`settings sync: ${msg}`);
        }
      },
      onSas: (): void => {
      },
      onAck: (): void => {
      },
      onSettingsChanged: (): void => {
        changed = true;
      },
    }, false, mac);
    // 连接超时等情况下 MacLink 最终会进入 error；再加一道保险
    setTimeout(() => finish(), 15000);
    link.connect();
  }
}

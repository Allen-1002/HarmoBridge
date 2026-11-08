import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';
import { LinkState, MacLink } from './MacLink';

/**
 * 手机界面上改了同步开关，或打开 App 时，临时连一次 Mac 交换设置（连上即自动交换），随后断开。
 * 未配对或连不上时静默跳过：下一条通知转发时也会自动交换。
 */
export class SettingsSync {
  static run(ctx: common.Context, onDone?: (changed: boolean) => void): void {
    let changed = false;
    let finished = false;
    let link: MacLink | undefined = undefined;
    const finish = (): void => {
      if (finished) {
        return;
      }
      finished = true;
      link?.stop();
      if (onDone !== undefined) {
        onDone(changed);
      }
    };
    link = new MacLink(ctx, {
      onState: (s: LinkState): void => {
        if (s === 'online') {
          // 等 Mac 回传它的设置
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
    }, false);
    if (link.pairedMac() === undefined) {
      return;
    }
    link.connect();
  }
}

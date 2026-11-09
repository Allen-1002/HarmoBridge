import { common } from '@kit.AbilityKit';
import { connection } from '@kit.ConnectivityKit';
import { preferences } from '@kit.ArkData';
import { readRecords } from './NotificationStore';
import { MacInfo, matchesPlatform, pairedComputers, platformLabel } from './PairingStore';
import { loadSettings } from './PhoneFilter';
import {
  getGrantedBundles,
  getSubscribeInfo,
  isBluetoothOn,
  isPermissionGranted,
  isUserGranted,
  PERM_BLUETOOTH,
  PERM_SUBSCRIBE,
  supportsSubscription,
} from './SubscriptionService';

/** 首页需要的整体状态快照。所有查询失败都降级为“未知/未完成”，不会抛出。 */
export class AppStatus {
  apiSupported: boolean = false;
  permGranted: boolean = false;
  btPermGranted: boolean = false;
  bluetoothOn: boolean = false;
  userGranted: boolean = false;
  grantedApps: number = 0;
  subscribedAddr: string = '';
  subscribedName: string = '';
  macName: string = '';
  macHost: string = '';
  computerCount: number = 0;
  macNames: string = ''; // 已配对的 Mac，名称用顿号连接
  windowsNames: string = ''; // 已配对的 Windows 电脑
  syncOn: boolean = true;
  todayCount: number = 0;

  get notificationReady(): boolean {
    return this.permGranted && this.userGranted;
  }

  get bluetoothReady(): boolean {
    return this.subscribedAddr.length > 0;
  }

  get macReady(): boolean {
    return this.macName.length > 0;
  }

  get allReady(): boolean {
    return this.notificationReady && this.bluetoothReady && this.macReady;
  }
}

function deviceName(addr: string): string {
  try {
    const n = connection.getRemoteDeviceName(addr);
    return n.length > 0 ? n : addr;
  } catch (e) {
    return addr;
  }
}

export async function loadStatus(ctx: common.Context): Promise<AppStatus> {
  const s = new AppStatus();
  s.apiSupported = supportsSubscription();
  try {
    s.permGranted = isPermissionGranted(PERM_SUBSCRIBE);
    s.btPermGranted = isPermissionGranted(PERM_BLUETOOTH);
  } catch (e) {
    // 保持默认
  }
  try {
    s.bluetoothOn = isBluetoothOn();
  } catch (e) {
    s.bluetoothOn = false;
  }
  if (s.permGranted) {
    try {
      s.userGranted = await isUserGranted();
      s.grantedApps = (await getGrantedBundles()).length;
    } catch (e) {
      s.userGranted = false;
    }
    try {
      const infos = await getSubscribeInfo();
      if (infos.length > 0) {
        s.subscribedAddr = infos[0].addr;
        s.subscribedName = s.btPermGranted ? deviceName(infos[0].addr) : '已订阅设备';
      }
    } catch (e) {
      s.subscribedAddr = '';
    }
  }
  const computers: Array<MacInfo> = pairedComputers(ctx);
  s.computerCount = computers.length;
  s.macNames = computers.filter((m: MacInfo) => matchesPlatform(m, 'mac')).map((m: MacInfo) => m.macName).join('、');
  s.windowsNames = computers.filter((m: MacInfo) => matchesPlatform(m, 'windows')).map((m: MacInfo) => m.macName)
    .join('、');
  if (computers.length === 1) {
    s.macName = computers[0].macName;
    s.macHost = `${platformLabel(computers[0])} · ${computers[0].host}`;
  } else if (computers.length > 1) {
    s.macName = computers.map((m: MacInfo) => m.macName).join('、');
    s.macHost = `${computers.length} 台电脑`;
  }
  s.syncOn = !loadSettings(ctx).paused;
  const startOfDay = new Date();
  startOfDay.setHours(0, 0, 0, 0);
  s.todayCount = readRecords(ctx.filesDir)
    .filter((r) => r.kind === 'publish' && r.recordTime >= startOfDay.getTime()).length;
  return s;
}

const UI_PREF = 'notibridge_ui';

export function isOnboarded(ctx: common.Context): boolean {
  return preferences.getPreferencesSync(ctx, { name: UI_PREF }).getSync('onboarded', false) as boolean;
}

export function setOnboarded(ctx: common.Context, v: boolean): void {
  const p = preferences.getPreferencesSync(ctx, { name: UI_PREF });
  p.putSync('onboarded', v);
  p.flushSync();
}

/** 使用方式：纯软件，或使用 ESP32 模块（额外支持在电脑上接打电话）。 */
export type UseMode = 'software' | 'esp32';

export function getUseMode(ctx: common.Context): UseMode {
  const v = preferences.getPreferencesSync(ctx, { name: UI_PREF }).getSync('useMode', 'software') as string;
  return v === 'esp32' ? 'esp32' : 'software';
}

export function setUseMode(ctx: common.Context, m: UseMode): void {
  const p = preferences.getPreferencesSync(ctx, { name: UI_PREF });
  p.putSync('useMode', m);
  p.flushSync();
}

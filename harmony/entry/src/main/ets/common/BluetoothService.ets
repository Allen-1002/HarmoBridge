import { access, connection } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, maskAddr } from './Logger';

export interface NearbyDevice {
  addr: string;
  name: string;
  rssi: number;
}

/**
 * App 内扫描附近蓝牙设备、发起配对（官方 connection 接口，需要 ACCESS_BLUETOOTH）。
 * 配对仍由系统弹窗让用户确认配对码，App 不会绕过系统确认。
 */
export class BluetoothScanner {
  private found: Map<string, NearbyDevice> = new Map<string, NearbyDevice>();
  private onUpdate: (list: Array<NearbyDevice>) => void = () => {
  };
  private onBond: (addr: string, bonded: boolean) => void = () => {
  };
  private timer: number = -1;

  private resultCb = (results: Array<connection.DiscoveryResult>) => {
    for (const r of results) {
      const name = r.deviceName.length > 0 ? r.deviceName : this.nameOf(r.deviceId);
      if (name.length === 0) {
        continue; // 没有名称的设备通常不是用户要找的，隐藏
      }
      this.found.set(r.deviceId, { addr: r.deviceId, name: name, rssi: r.rssi });
    }
    this.emit();
  };

  private bondCb = (p: connection.BondStateParam) => {
    if (p.state === connection.BondState.BOND_STATE_BONDED) {
      Logger.info(`bonded ${maskAddr(p.deviceId)}`);
      this.onBond(p.deviceId, true);
    } else if (p.state === connection.BondState.BOND_STATE_INVALID) {
      this.onBond(p.deviceId, false);
    }
  };

  start(onUpdate: (list: Array<NearbyDevice>) => void, onBond: (addr: string, bonded: boolean) => void,
    durationMs: number = 15000, onDone: () => void = () => {
    }): void {
    this.stop();
    this.found.clear();
    this.onUpdate = onUpdate;
    this.onBond = onBond;
    if (access.getState() !== access.BluetoothState.STATE_ON) {
      throw new Error('蓝牙未打开');
    }
    connection.on('discoveryResult', this.resultCb);
    connection.on('bondStateChange', this.bondCb);
    connection.startBluetoothDiscovery();
    this.timer = setTimeout(() => {
      this.stopDiscovery();
      onDone();
    }, durationMs);
  }

  pair(addr: string): Promise<void> {
    this.stopDiscovery();
    return connection.pairDevice(addr);
  }

  stopDiscovery(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    try {
      if (connection.isBluetoothDiscovering()) {
        connection.stopBluetoothDiscovery();
      }
      connection.off('discoveryResult', this.resultCb);
    } catch (e) {
      Logger.warn(`stop discovery: ${(e as BusinessError).code}`);
    }
  }

  stop(): void {
    this.stopDiscovery();
    try {
      connection.off('bondStateChange', this.bondCb);
    } catch (e) {
      Logger.warn('off bondStateChange failed');
    }
  }

  private nameOf(addr: string): string {
    try {
      return connection.getRemoteDeviceName(addr);
    } catch (e) {
      return '';
    }
  }

  private emit(): void {
    const list = Array.from(this.found.values()).sort((a: NearbyDevice, b: NearbyDevice) => b.rssi - a.rssi);
    this.onUpdate(list);
  }
}

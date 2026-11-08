import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { BluetoothScanner, NearbyDevice } from '../common/BluetoothService';
import { describeError } from '../common/ErrorDescriber';
import { Logger, maskAddr } from '../common/Logger';
import {
  getSubscribeInfo,
  isBluetoothOn,
  isPermissionGranted,
  listPairedDevices,
  PairedDevice,
  PERM_BLUETOOTH,
  requestBluetoothPermission,
  subscribe,
  unsubscribe,
} from '../common/SubscriptionService';
import { Card, Chip, IconBadge, SectionTitle } from './UI';

/**
 * 蓝牙订阅设备设置：选择已配对设备订阅，或扫描附近设备并在 App 内发起配对。
 * 引导页和“蓝牙设备”页共用。
 */
@Component
export struct BluetoothPanel {
  @State permGranted: boolean = false;
  @State btOn: boolean = true;
  @State paired: Array<PairedDevice> = [];
  @State nearby: Array<NearbyDevice> = [];
  @State scanning: boolean = false;
  @State subscribed: string = '';
  @State busyAddr: string = '';
  onChanged: (subscribedAddr: string) => void = () => {
  };
  private scanner: BluetoothScanner = new BluetoothScanner();

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.refresh();
  }

  aboutToDisappear(): void {
    this.scanner.stop();
  }

  private sameAddr(a: string, b: string): boolean {
    return a.length > 0 && a.toUpperCase() === b.toUpperCase();
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 2500 });
  }

  private async refresh(): Promise<void> {
    try {
      this.permGranted = isPermissionGranted(PERM_BLUETOOTH);
      this.btOn = isBluetoothOn();
      if (this.permGranted && this.btOn) {
        this.paired = listPairedDevices();
      }
      const infos = await getSubscribeInfo();
      this.subscribed = infos.length > 0 ? infos[0].addr : '';
      Logger.info(`subscribed=${maskAddr(this.subscribed)} paired=${this.paired.map((p: PairedDevice) => maskAddr(p.addr)).join(',')}`);
      this.onChanged(this.subscribed);
    } catch (e) {
      Logger.warn(`bluetooth panel refresh: ${describeError(e)}`);
    }
  }

  private async grant(): Promise<void> {
    try {
      this.permGranted = await requestBluetoothPermission(this.ctx());
      if (!this.permGranted) {
        this.toast('需要蓝牙权限才能选择设备，可在 设置 > 应用 中开启');
      }
      await this.refresh();
    } catch (e) {
      this.toast(describeError(e));
    }
  }

  private async choose(addr: string): Promise<void> {
    this.busyAddr = addr;
    try {
      await subscribe(addr);
      this.subscribed = addr;
      this.toast('已设为通知订阅设备');
      this.onChanged(addr);
    } catch (e) {
      this.toast(`订阅失败：${describeError(e)}`);
    }
    this.busyAddr = '';
  }

  private async cancelSubscription(): Promise<void> {
    try {
      await unsubscribe();
      this.subscribed = '';
      this.onChanged('');
    } catch (e) {
      this.toast(describeError(e));
    }
  }

  private scan(): void {
    try {
      this.nearby = [];
      this.scanning = true;
      this.scanner.start((list: Array<NearbyDevice>) => {
        const pairedAddrs = this.paired.map((p: PairedDevice) => p.addr);
        this.nearby = list.filter((d: NearbyDevice) => pairedAddrs.indexOf(d.addr) < 0);
      }, (addr: string, bonded: boolean) => {
        this.busyAddr = '';
        if (bonded) {
          this.toast('配对成功');
          this.refresh().then(() => this.choose(addr));
        }
      }, 15000, () => {
        this.scanning = false;
      });
    } catch (e) {
      this.scanning = false;
      this.toast(e instanceof Error ? e.message : describeError(e));
    }
  }

  private async pair(d: NearbyDevice): Promise<void> {
    this.busyAddr = d.addr;
    this.scanning = false;
    try {
      await this.scanner.pair(d.addr);
      this.toast('请在系统弹窗中确认配对码');
    } catch (e) {
      this.busyAddr = '';
      this.toast(`配对失败：${describeError(e)}`);
    }
  }

  @Builder
  DeviceRow(name: string, sub: string, isCurrent: boolean, action: string, busy: boolean, onTap: () => void) {
    Row() {
      IconBadge({ symbol: $r('sys.symbol.bluetooth'), tone: isCurrent ? 'success' : 'accent', boxSize: 34 })
      Column() {
        Text(name).fontSize(15).fontColor($r('app.color.hb_text')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(sub).fontSize(12).fontColor($r('app.color.hb_text2')).margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12, right: 8 })

      if (isCurrent) {
        Chip({ text: '订阅中', tone: 'success' })
      } else if (busy) {
        LoadingProgress().width(24).height(24).color($r('app.color.hb_accent'))
      } else {
        Button(action)
          .fontSize(13)
          .height(30)
          .padding({ left: 12, right: 12 })
          .fontColor($r('app.color.hb_accent'))
          .backgroundColor($r('app.color.hb_accent_soft'))
          .onClick(onTap)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 14, top: 12, bottom: 12 })
  }

  build() {
    Column() {
      if (!this.permGranted) {
        Card() {
          Column({ space: 10 }) {
            Text('需要蓝牙权限').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.hb_text'))
            Text('系统规定通知订阅必须绑定一个已配对的蓝牙设备。授权后可选择设备，App 不会连接或控制其他设备。')
              .fontSize(13).fontColor($r('app.color.hb_text2'))
            Button('授权蓝牙').height(40).backgroundColor($r('app.color.hb_accent')).onClick(() => this.grant())
          }
          .alignItems(HorizontalAlign.Start)
          .padding(16)
        }
      } else if (!this.btOn) {
        Card() {
          Column({ space: 10 }) {
            Text('蓝牙未打开').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.hb_text'))
            Text('请从屏幕右上角下拉控制中心打开蓝牙，然后点“刷新”。').fontSize(13).fontColor($r('app.color.hb_text2'))
            Button('刷新').height(40).backgroundColor($r('app.color.hb_accent')).onClick(() => this.refresh())
          }
          .alignItems(HorizontalAlign.Start)
          .padding(16)
        }
      } else {
        SectionTitle({ title: '已配对的设备' })
        Card() {
          Column() {
            if (this.paired.length === 0) {
              Text('还没有已配对的设备，可在下方扫描附近设备').fontSize(13).fontColor($r('app.color.hb_text2')).padding(16)
            }
            ForEach(this.paired, (d: PairedDevice, i: number) => {
              this.DeviceRow(d.name, d.bonded ? '已配对' : '配对状态异常', this.sameAddr(d.addr, this.subscribed), '设为订阅',
                this.busyAddr === d.addr, () => {
                  this.choose(d.addr);
                })
              if (i < this.paired.length - 1) {
                Divider().color($r('app.color.hb_divider')).margin({ left: 62 })
              }
            }, (d: PairedDevice) => d.addr + '|' + this.subscribed + '|' + this.busyAddr)
          }
        }

        Row() {
          SectionTitle({ title: '附近的设备' }).layoutWeight(1)
          if (this.scanning) {
            LoadingProgress().width(20).height(20).color($r('app.color.hb_accent')).margin({ top: 12, right: 8 })
          }
          Text(this.scanning ? '扫描中' : '扫描')
            .fontSize(14)
            .fontColor($r('app.color.hb_accent'))
            .margin({ top: 12, right: 16 })
            .onClick(() => {
              if (!this.scanning) {
                this.scan();
              }
            })
        }.width('100%')

        Card() {
          Column() {
            if (this.nearby.length === 0) {
              Text(this.scanning ? '正在搜索…' : '点右上角“扫描”查找附近设备。\n要让 Mac 被搜到：在 Mac 上打开“系统设置 > 蓝牙”并保持该页面开着。')
                .fontSize(13)
                .fontColor($r('app.color.hb_text2'))
                .padding(16)
            }
            ForEach(this.nearby, (d: NearbyDevice, i: number) => {
              this.DeviceRow(d.name, `信号 ${d.rssi} dBm`, false, '配对', this.busyAddr === d.addr, () => {
                this.pair(d);
              })
              if (i < this.nearby.length - 1) {
                Divider().color($r('app.color.hb_divider')).margin({ left: 62 })
              }
            }, (d: NearbyDevice) => d.addr + '|' + this.busyAddr)
          }
        }

        if (this.subscribed.length > 0) {
          Text('取消通知订阅')
            .fontSize(14)
            .fontColor($r('app.color.hb_danger'))
            .margin({ top: 16 })
            .onClick(() => this.cancelSubscription())
        }
      }
    }
    .width('100%')
  }
}

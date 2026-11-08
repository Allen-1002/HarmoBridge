import { common } from '@kit.AbilityKit';
import { describeError } from '../common/ErrorDescriber';
import { Logger, maskAddr } from '../common/Logger';
import { clearRecords, EventRecord, readRecords } from '../common/NotificationStore';
import { loadSettings, saveSettings, SyncSettings } from '../common/PhoneFilter';
import {
  getGrantedBundles,
  getSubscribeInfo,
  isBluetoothOn,
  isPermissionGranted,
  isUserGranted,
  listPairedDevices,
  openGrantSettings,
  PairedDevice,
  PERM_BLUETOOTH,
  PERM_SUBSCRIBE,
  requestBluetoothPermission,
  subscribe,
  supportsSettingsWithResult,
  supportsSubscription,
  SystemInfo,
  unsubscribe,
} from '../common/SubscriptionService';

interface OpLog {
  time: string;
  ok: boolean;
  msg: string;
}

@Entry
@Component
struct DebugPage {
  @State sysInfo: SystemInfo = new SystemInfo();
  @State subscribePermGranted: boolean = false;
  @State bluetoothPermGranted: boolean = false;
  @State bluetoothOn: boolean = false;
  @State userGranted: string = '未检查';
  @State grantedApps: string = '';
  @State pairedDevices: Array<PairedDevice> = [];
  @State selectedAddr: string = '';
  @State subscribeState: string = '未检查';
  @State records: Array<EventRecord> = [];
  @State showContent: boolean = false;
  @State logs: Array<OpLog> = [];
  @State syncOn: boolean = true;
  @State blockSensitive: boolean = true;

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.refreshPermissions();
    this.refreshRecords();
    const st = loadSettings(this.ctx());
    this.syncOn = !st.paused;
    this.blockSensitive = st.blockSensitive;
  }

  private saveSync(): void {
    const st: SyncSettings = loadSettings(this.ctx());
    st.paused = !this.syncOn;
    st.blockSensitive = this.blockSensitive;
    saveSettings(this.ctx(), st);
    this.log(true, `同步到 Mac：${this.syncOn ? '开' : '暂停'}，拦截敏感通知：${this.blockSensitive ? '开' : '关'}`);
  }

  private log(ok: boolean, msg: string): void {
    const d = new Date();
    const time = `${d.getHours()}:${d.getMinutes().toString().padStart(2, '0')}:${d.getSeconds().toString().padStart(2, '0')}`;
    this.logs = [{ time: time, ok: ok, msg: msg } as OpLog].concat(this.logs).slice(0, 50);
    if (ok) {
      Logger.info(msg);
    } else {
      Logger.error(msg);
    }
  }

  private refreshPermissions(): void {
    try {
      this.subscribePermGranted = isPermissionGranted(PERM_SUBSCRIBE);
      this.bluetoothPermGranted = isPermissionGranted(PERM_BLUETOOTH);
      this.log(true, `权限检查：SUBSCRIBE_NOTIFICATION=${this.subscribePermGranted}，ACCESS_BLUETOOTH=${this.bluetoothPermGranted}`);
    } catch (e) {
      this.log(false, `权限检查失败 ${describeError(e)}`);
    }
  }

  private refreshRecords(): void {
    this.records = readRecords(this.ctx().filesDir);
  }

  private async onRequestBluetooth(): Promise<void> {
    try {
      const ok = await requestBluetoothPermission(this.ctx());
      this.bluetoothPermGranted = ok;
      this.log(ok, ok ? '蓝牙权限已授权' : '用户拒绝蓝牙权限（可到 设置 > 应用 > HarmoBridge 中手动开启）');
    } catch (e) {
      this.log(false, `申请蓝牙权限失败 ${describeError(e)}`);
    }
  }

  private onLoadPaired(): void {
    try {
      this.bluetoothOn = isBluetoothOn();
      if (!this.bluetoothOn) {
        this.log(false, '蓝牙未打开，请先在控制中心打开蓝牙');
        return;
      }
      this.pairedDevices = listPairedDevices();
      this.log(true, `已配对设备 ${this.pairedDevices.length} 个`);
      if (this.pairedDevices.length === 0) {
        this.log(false, '没有已配对设备：请先在 设置 > 蓝牙 中与真实设备（如 ESP32）完成配对');
      }
    } catch (e) {
      this.log(false, `读取已配对设备失败 ${describeError(e)}`);
    }
  }

  private async onOpenSettings(): Promise<void> {
    try {
      const msg = await openGrantSettings(this.ctx());
      this.log(true, msg);
      await this.onRefreshGrant();
    } catch (e) {
      this.log(false, `打开通知授权页失败 ${describeError(e)}`);
    }
  }

  private async onRefreshGrant(): Promise<void> {
    try {
      const granted = await isUserGranted();
      this.userGranted = granted ? '已开启' : '未开启';
      const bundles = await getGrantedBundles();
      this.grantedApps = bundles.map((b) => (b.appName === undefined ? '' : b.appName) + '(' + b.bundleName + ')').join('，');
      this.log(true, `“允许获取本机通知”=${granted}，已授权应用 ${bundles.length} 个`);
    } catch (e) {
      this.userGranted = '查询失败';
      this.log(false, `查询授权状态失败 ${describeError(e)}`);
    }
  }

  private async onSubscribe(): Promise<void> {
    if (this.selectedAddr.length === 0) {
      this.log(false, '请先选择一个已配对的真实蓝牙设备');
      return;
    }
    try {
      await subscribe(this.selectedAddr);
      this.log(true, `subscribe 成功，设备 ${maskAddr(this.selectedAddr)}`);
      await this.onQuerySubscribe();
    } catch (e) {
      this.log(false, `subscribe 失败 ${describeError(e)}`);
    }
  }

  private async onUnsubscribe(): Promise<void> {
    try {
      await unsubscribe();
      this.log(true, 'unsubscribe 成功');
      await this.onQuerySubscribe();
    } catch (e) {
      this.log(false, `unsubscribe 失败 ${describeError(e)}`);
    }
  }

  private async onQuerySubscribe(): Promise<void> {
    try {
      const infos = await getSubscribeInfo();
      this.subscribeState = infos.length === 0 ? '未订阅' :
        infos.map((i) => `type=${i.type} addr=${maskAddr(i.addr)}`).join('；');
      this.log(true, `getSubscribeInfo 返回 ${infos.length} 条`);
    } catch (e) {
      this.subscribeState = '查询失败';
      this.log(false, `getSubscribeInfo 失败 ${describeError(e)}`);
    }
  }

  @Builder
  Section(title: string) {
    Text(title).fontSize(17).fontWeight(FontWeight.Bold).margin({ top: 16, bottom: 6 })
  }

  @Builder
  Line(label: string, value: string) {
    Row() {
      Text(label).fontSize(14).fontColor('#666666').width('45%')
      Text(value).fontSize(14).layoutWeight(1)
    }.width('100%').margin({ top: 2 })
  }

  @Builder
  Btn(label: string, action: () => void) {
    Button(label).fontSize(14).height(36).margin({ right: 8, top: 6 }).onClick(action)
  }

  private recordSummary(r: EventRecord): string {
    if (r.kind === 'publish') {
      const rawTitle: string = r.title === undefined ? '' : r.title;
      const rawText: string = r.text === undefined ? '' : r.text;
      const appName: string = r.appName === undefined ? '' : r.appName;
      const bundle: string = r.bundleName === undefined ? '' : r.bundleName;
      const title = this.showContent ? rawTitle : `[标题已隐藏 ${rawTitle.length} 字]`;
      const text = this.showContent ? rawText : `[正文已隐藏 ${rawText.length} 字]`;
      return `收到 ${appName}(${bundle}) slot=${r.slotType}\nhash=${r.hashCode}\n${title}\n${text}`;
    }
    if (r.kind === 'cancel') {
      return `撤销 ${JSON.stringify(r.cancelHashCodes)}`;
    }
    return '扩展被系统销毁 (onDestroy)';
  }

  build() {
    Scroll() {
      Column() {
        Text('调试与诊断').fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 12 })
        this.Btn('← 返回', () => this.getUIContext().getRouter().back())

        this.Section('1. 系统与 API')
        this.Line('设备', `${this.sysInfo.marketName} (${this.sysInfo.productModel})`)
        this.Line('系统', this.sysInfo.displayVersion)
        this.Line('osFullName', this.sysInfo.osFullName)
        this.Line('sdkApiVersion', `${this.sysInfo.sdkApiVersion}`)
        this.Line('订阅接口(≥22)', supportsSubscription() ? '支持' : '不支持')
        this.Line('WithResult(≥26)', supportsSettingsWithResult() ? '支持' : '不支持，将使用旧接口')

        this.Section('2. 权限')
        this.Line('SUBSCRIBE_NOTIFICATION', this.subscribePermGranted ? '已授予' : '未授予（签名 Profile 缺 ACL）')
        this.Line('ACCESS_BLUETOOTH', this.bluetoothPermGranted ? '已授予' : '未授予')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.Btn('重新检查权限', () => this.refreshPermissions())
          this.Btn('申请蓝牙权限', () => { this.onRequestBluetooth(); })
        }

        this.Section('3. 通知授权（系统半模态页）')
        this.Line('允许获取本机通知', this.userGranted)
        this.Line('已授权应用', this.grantedApps.length > 0 ? this.grantedApps : '-')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.Btn('打开授权页', () => { this.onOpenSettings(); })
          this.Btn('刷新授权状态', () => { this.onRefreshGrant(); })
        }

        this.Section('4. 已配对蓝牙设备')
        this.Btn('读取已配对设备', () => this.onLoadPaired())
        ForEach(this.pairedDevices, (d: PairedDevice) => {
          Row() {
            Radio({ value: d.addr, group: 'bt' })
              .checked(this.selectedAddr === d.addr)
              .onChange((checked: boolean) => {
                if (checked) {
                  this.selectedAddr = d.addr;
                }
              })
            Text(`${d.name}  ${maskAddr(d.addr)}  ${d.bonded ? '已配对' : '配对状态异常'}`).fontSize(14)
          }.width('100%')
        }, (d: PairedDevice) => d.addr)

        this.Section('5. 订阅')
        this.Line('当前订阅', this.subscribeState)
        Flex({ wrap: FlexWrap.Wrap }) {
          this.Btn('开始订阅', () => { this.onSubscribe(); })
          this.Btn('停止订阅', () => { this.onUnsubscribe(); })
          this.Btn('查询订阅', () => { this.onQuerySubscribe(); })
        }

        this.Section('转发到 Mac')
        Row() {
          Text('同步通知到 Mac').fontSize(14).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.syncOn })
            .onChange((on: boolean) => {
              this.syncOn = on;
              this.saveSync();
            })
        }.width('100%')
        Row() {
          Text('不转发验证码、银行、支付类通知').fontSize(14).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.blockSensitive })
            .onChange((on: boolean) => {
              this.blockSensitive = on;
              this.saveSync();
            })
        }.width('100%')

        this.Section(`6. 收到的系统通知（${this.records.length}）`)
        Text('仅显示 NotificationSubscriberExtAbility 真实回调写入的记录，无模拟数据')
          .fontSize(12).fontColor('#888888')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.Btn('刷新', () => this.refreshRecords())
          this.Btn(this.showContent ? '隐藏内容' : '显示内容', () => { this.showContent = !this.showContent; })
          this.Btn('清空', () => { clearRecords(this.ctx().filesDir); this.refreshRecords(); })
        }
        ForEach(this.records, (r: EventRecord) => {
          Column() {
            Text(new Date(r.recordTime).toLocaleString()).fontSize(12).fontColor('#888888')
            Text(this.recordSummary(r)).fontSize(13)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(8)
          .margin({ top: 6 })
          .backgroundColor('#F2F3F5')
          .borderRadius(8)
        }, (r: EventRecord) => r.recordTime + '-' + r.kind + '-' + (r.hashCode === undefined ? '' : r.hashCode) + '-' + this.showContent)

        this.Section('7. 操作日志')
        ForEach(this.logs, (l: OpLog) => {
          Text(`${l.time} ${l.ok ? '✓' : '✗'} ${l.msg}`)
            .fontSize(12)
            .fontColor(l.ok ? '#333333' : '#D0021B')
            .width('100%')
            .margin({ top: 2 })
        }, (l: OpLog, i: number) => `${i}-${l.time}-${l.msg}`)
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, bottom: 40 })
      .width('100%')
    }
    .height('100%')
    .width('100%')
  }
}

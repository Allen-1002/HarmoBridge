import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { AppStatus, getUseMode, isOnboarded, loadStatus, setUseMode } from '../common/AppStatus';
import { describeError } from '../common/ErrorDescriber';
import { resetAllData } from '../common/DataReset';
import { Logger } from '../common/Logger';
import { clearRecords, EventRecord, readRecords } from '../common/NotificationStore';
import { loadSettings, saveSettings, SyncSettings } from '../common/PhoneFilter';
import { openGrantSettings } from '../common/SubscriptionService';
import { SettingsSync } from '../common/SettingsSync';
import { takeUnpairNotices } from '../common/PairingStore';
import { PendingUnpair } from '../common/PendingUnpair';
import { cachedUpdate, checkUpdate, currentVersion, openReleasePage, UpdateInfo } from '../common/UpdateCheck';
import { AuroraBackground, Card, Chip, GLASS, GLASS_THIN, NavRow, SectionTitle, StatTile, SwitchRow } from '../components/UI';

const AVATAR_COLORS: Array<string> = ['#3B82F6', '#10B981', '#F59E0B', '#EF4444', '#8B5CF6', '#06B6D4', '#EC4899'];

function avatarColor(key: string): string {
  let h = 0;
  for (let i = 0; i < key.length; i++) {
    h = (h * 31 + key.charCodeAt(i)) % 997;
  }
  return AVATAR_COLORS[h % AVATAR_COLORS.length];
}

function relativeTime(ms: number): string {
  const diff = Date.now() - ms;
  if (diff < 60000) {
    return '刚刚';
  }
  if (diff < 3600000) {
    return `${Math.floor(diff / 60000)} 分钟前`;
  }
  const d = new Date(ms);
  const today = new Date();
  const hm = `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
  if (d.toDateString() === today.toDateString()) {
    return hm;
  }
  return `${d.getMonth() + 1}月${d.getDate()}日 ${hm}`;
}

function appLabel(r: EventRecord): string {
  if (r.appName !== undefined && r.appName.length > 0) {
    return r.appName;
  }
  return r.bundleName === undefined ? '' : r.bundleName;
}

interface LinkParams {
  platform: string;
}

@Entry
@Component
struct Index {
  @State tab: number = 0;
  @State status: AppStatus = new AppStatus();
  @State settings: SyncSettings = {
    paused: false, blockSensitive: true, blockedBundles: [], copyOtp: true, updatedAt: 0
  };
  @State records: Array<EventRecord> = [];
  @State cancelled: Array<string> = [];
  @State showContent: boolean = false;
  @State useEsp32: boolean = false;
  @State loaded: boolean = false;
  @State appVersion: string = currentVersion();
  @State update: UpdateInfo | undefined = undefined;
  @State updateStatus: string = '';

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    if (!isOnboarded(this.ctx())) {
      setTimeout(() => this.getUIContext().getRouter().replaceUrl({ url: 'pages/OnboardingPage' }), 0);
      return;
    }
    this.reload();
  }

  onPageShow(): void {
    this.useEsp32 = getUseMode(this.ctx()) === 'esp32';
    if (this.loaded) {
      this.reload();
    }
    // 拉取电脑上改过的开关
    SettingsSync.run(this.ctx(), (changed: boolean) => {
      if (changed) {
        this.settings = loadSettings(this.ctx());
        this.status.syncOn = !this.settings.paused;
      }
      // 连接时发现某台电脑已在电脑端取消配对：手机已自动删除，这里提示一次
      this.showUnpairNotices();
    });
    // 在手机上删除过、当时不在线的电脑：再试着通知它取消配对
    PendingUnpair.flush(this.ctx());
    // 检查新版本（最多每 6 小时联网一次）
    this.update = cachedUpdate(this.ctx());
    this.runUpdateCheck(false);
  }

  private runUpdateCheck(force: boolean): void {
    if (force) {
      this.updateStatus = '正在检查…';
    }
    checkUpdate(this.ctx(), force).then((info: UpdateInfo | undefined) => {
      this.update = info;
      this.updateStatus = info === undefined ? '' : (info.hasUpdate ? '' : '已是最新版本');
    }).catch((e: Error) => {
      Logger.warn(`检查更新失败：${e.message}`);
      this.updateStatus = force ? `检查失败：${e.message}` : '';
    });
  }

  private updateSubtitle(): string {
    if (this.updateStatus.length > 0) {
      return `当前 ${this.appVersion} · ${this.updateStatus}`;
    }
    if (this.update === undefined) {
      return `当前 ${this.appVersion}`;
    }
    if (this.update.hasUpdate) {
      return `当前 ${this.appVersion} · 最新 ${this.update.latest}，需要在电脑上用 DevEco 重新签名安装`;
    }
    return `当前 ${this.appVersion} · 已是最新版本`;
  }

  private showUnpairNotices(): void {
    const names: Array<string> = takeUnpairNotices(this.ctx());
    if (names.length === 0) {
      return;
    }
    this.reload();
    const list = names.map((n: string) => `“${n}”`).join('、');
    this.getUIContext().showAlertDialog({
      title: '电脑已取消配对',
      message: `${list} 已在电脑上取消了与这台手机的配对，已从电脑列表中移除。需要继续使用时，请在“电脑连接”里重新配对。`,
      confirm: { value: '知道了', action: () => {
      } },
    });
  }

  private async reload(): Promise<void> {
    this.settings = loadSettings(this.ctx());
    this.loadRecords();
    this.status = await loadStatus(this.ctx());
    this.loaded = true;
  }

  private loadRecords(): void {
    const all = readRecords(this.ctx().filesDir);
    const cancelled: Array<string> = [];
    all.filter((r: EventRecord) => r.kind === 'cancel').forEach((r: EventRecord) => {
      const hs: Array<string> = r.cancelHashCodes === undefined ? [] : r.cancelHashCodes;
      hs.forEach((h: string) => cancelled.push(h));
    });
    this.cancelled = cancelled;
    this.records = all.filter((r: EventRecord) => r.kind === 'publish');
  }

  private updateSettings(fn: (s: SyncSettings) => void): void {
    const s = loadSettings(this.ctx());
    fn(s);
    saveSettings(this.ctx(), s);
    this.settings = s;
    this.status.syncOn = !s.paused;
    SettingsSync.run(this.ctx()); // 推送到所有已配对的电脑
  }

  private async openGrant(): Promise<void> {
    try {
      await openGrantSettings(this.ctx());
      this.status = await loadStatus(this.ctx());
    } catch (e) {
      promptAction.showToast({ message: describeError(e), duration: 3000 });
    }
  }

  private goLink(platform: string): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/MacLinkPage', params: { platform: platform } as LinkParams });
  }

  private go(url: string): void {
    this.getUIContext().getRouter().pushUrl({ url: url });
  }

  private missingSteps(): number {
    let n = 0;
    if (!this.status.notificationReady) {
      n++;
    }
    if (!this.status.bluetoothReady) {
      n++;
    }
    if (!this.status.macReady) {
      n++;
    }
    return n;
  }

  // ---------------- 首页 ----------------

  @Builder
  HeroCard() {
    Column() {
      if (!this.loaded) {
        Text('正在检查状态…').fontSize(16).fontColor(Color.White)
      } else if (!this.status.allReady) {
        Text('还差 ' + this.missingSteps() + ' 步完成设置').fontSize(22).fontWeight(FontWeight.Bold).fontColor(Color.White)
        Text('完成后，手机通知会自动同步到你的电脑').fontSize(14).fontColor('#E6FFFFFF').margin({ top: 6 })
        Button('继续设置')
          .height(38)
          .fontSize(14)
          .fontColor('#1E3A8A')
          .backgroundColor(Color.White)
          .margin({ top: 16 })
          .onClick(() => this.go('pages/OnboardingPage'))
      } else {
        Row() {
          Column() {
            Text(this.status.syncOn ? '通知同步中' : '同步已暂停')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
            Text(this.status.syncOn ? '正在同步到 ' + this.status.macName : '打开开关恢复同步')
              .fontSize(14)
              .fontColor('#E6FFFFFF')
              .margin({ top: 6 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.status.syncOn })
            .selectedColor('#33FFFFFF')
            .switchPointColor(Color.White)
            .onChange((on: boolean) => this.updateSettings((s: SyncSettings) => {
              s.paused = !on;
            }))
        }
        .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(20)
    .borderRadius(20)
    .linearGradient({
      angle: 120,
      colors: [[$r('app.color.hb_hero_start'), 0], [$r('app.color.hb_hero_end'), 1]],
    })
    .shadow({ radius: 16, color: '#331E88E5', offsetY: 6 })
  }

  @Builder
  HomeTab() {
    Scroll() {
      Column() {
        Text('NotiBridge')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.hb_text'))
          .width('100%')
          .margin({ top: 12, bottom: 16 })

        this.HeroCard()

        Row({ space: 12 }) {
          StatTile({ value: `${this.status.todayCount}`, label: '今日收到通知' }).layoutWeight(1)
          StatTile({ value: `${this.status.grantedApps}`, label: '已授权应用' }).layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 12 })

        SectionTitle({ title: '连接状态' })
        Card() {
          Column() {
            NavRow({
              symbol: $r('sys.symbol.checkmark_shield'),
              tone: this.status.notificationReady ? 'success' : 'warning',
              title: '通知读取',
              subtitle: !this.status.permGranted ? '安装包缺少通知订阅权限' :
                this.status.userGranted ? `已授权 ${this.status.grantedApps} 个应用` : '尚未允许读取通知',
              chip: this.status.notificationReady ? '正常' : '待处理',
              chipTone: this.status.notificationReady ? 'success' : 'warning',
              onTap: () => {
                this.openGrant();
              },
            })
            NavRow({
              symbol: $r('sys.symbol.bluetooth'),
              tone: this.status.bluetoothReady ? 'success' : 'warning',
              title: '蓝牙设备',
              subtitle: this.status.bluetoothReady ? this.status.subscribedName : '未选择订阅设备',
              chip: this.status.bluetoothReady ? '已订阅' : '待处理',
              chipTone: this.status.bluetoothReady ? 'success' : 'warning',
              onTap: () => this.go('pages/BluetoothPage'),
            })
            NavRow({
              symbol: $r('sys.symbol.desktop'),
              tone: this.status.macReady ? 'success' : 'warning',
              title: '电脑',
              subtitle: this.status.macReady ? this.status.macName + ' · ' + this.status.macHost : '尚未配对 Mac 或 Windows 电脑',
              chip: this.status.macReady ? '已配对' : '待处理',
              chipTone: this.status.macReady ? 'success' : 'warning',
              showDivider: false,
              onTap: () => this.go('pages/MacLinkPage'),
            })
          }
        }

        Text('通知由系统在后台按需转发，熄屏或清理后台后依然有效。')
          .fontSize(12)
          .fontColor($r('app.color.hb_text3'))
          .margin({ top: 16 })
      }
      .padding({ left: 16, right: 16, bottom: 120 })
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .height('100%')
  }

  // ---------------- 通知 ----------------

  @Builder
  NotificationItem(r: EventRecord) {
    Row() {
      Stack() {
        Text((appLabel(r) + '?').substring(0, 1))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
      }
      .width(40)
      .height(40)
      .borderRadius(12)
      .backgroundColor(avatarColor(r.bundleName === undefined ? '' : r.bundleName))

      Column() {
        Row() {
          Text(appLabel(r))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.hb_text'))
            .layoutWeight(1)
            .maxLines(1)
          if (this.cancelled.indexOf(r.hashCode === undefined ? '' : r.hashCode) >= 0) {
            Chip({ text: '已撤销', tone: 'neutral' }).margin({ right: 6 })
          }
          Text(relativeTime(r.recordTime)).fontSize(12).fontColor($r('app.color.hb_text3'))
        }
        .width('100%')

        if (this.showContent) {
          Text(r.title === undefined ? '' : r.title)
            .fontSize(14)
            .fontColor($r('app.color.hb_text'))
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(r.text === undefined ? '' : r.text)
            .fontSize(13)
            .fontColor($r('app.color.hb_text2'))
            .margin({ top: 2 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Text('内容已隐藏').fontSize(13).fontColor($r('app.color.hb_text3')).margin({ top: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(14)
    .backgroundColor($r('app.color.hb_card'))
    .borderRadius(20)
    .systemMaterial(GLASS)
  }

  @Builder
  NotificationsTab() {
    Column() {
      Row() {
        Text('通知').fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.hb_text')).layoutWeight(1)
        SymbolGlyph(this.showContent ? $r('sys.symbol.eye') : $r('sys.symbol.eye_slash'))
          .fontSize(22)
          .fontColor([$r('app.color.hb_text2')])
          .margin({ right: 18 })
          .onClick(() => {
            this.showContent = !this.showContent;
          })
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(22)
          .fontColor([$r('app.color.hb_text2')])
          .margin({ right: 18 })
          .onClick(() => this.loadRecords())
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(22)
          .fontColor([$r('app.color.hb_text2')])
          .onClick(() => {
            clearRecords(this.ctx().filesDir);
            this.loadRecords();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 20, top: 12, bottom: 12 })

      if (this.records.length === 0) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.bell')).fontSize(48).fontColor([$r('app.color.hb_text3')])
          Text('还没有收到通知').fontSize(15).fontColor($r('app.color.hb_text2'))
          Text('完成设置后，这里会显示最近同步的通知（仅保存在本机）').fontSize(12).fontColor($r('app.color.hb_text3'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.records, (r: EventRecord) => {
            ListItem() {
              this.NotificationItem(r)
            }
          }, (r: EventRecord) => r.recordTime + '-' + (r.hashCode === undefined ? '' : r.hashCode) + '-' + this.showContent)
        }
        .layoutWeight(1)
        .padding({ left: 16, right: 16 })
        .scrollBar(BarState.Off)
        .contentEndOffset(120)
      }
    }
    .height('100%')
  }

  // ---------------- 清除所有数据 ----------------

  private async confirmReset(): Promise<void> {
    const pa = this.getUIContext().getPromptAction();
    let choice = -1;
    try {
      const r = await pa.showDialog({
      title: '清除所有数据？',
      message: '将停止通知订阅，删除所有电脑的配对密钥、本机设备 ID、同步与过滤设置、使用方式和本机通知记录，然后回到首次使用引导。\n\n' +
        '所有电脑都需要重新配对；电脑上的配对记录请在电脑端删除。系统“允许获取本机通知”的授权和蓝牙配对由系统管理，不会被清除。',
      buttons: [
        { text: '取消', color: '#8A8A8E' },
        { text: '清除', color: '#E84026' },
      ],
      });
      choice = r.index;
    } catch (e) {
      return; // 点对话框外部关闭 = 取消
    }
    if (choice !== 1) {
      return;
    }
    let message = '';
    try {
      const res = await resetAllData(this.ctx());
      message = `已删除 ${res.assets} 个配对密钥和 ${res.prefs} 个设置文件。`;
    } catch (e) {
      pa.showToast({ message: `清除失败：${describeError(e)}`, duration: 3000 });
      return;
    }
    try {
      await pa.showDialog({
        title: '已清除所有数据',
        message: message + '\n\n如需卸载，请在桌面长按 NotiBridge 图标选择卸载。',
        buttons: [{ text: '知道了', color: '#0A59F7' }],
      });
    } catch (e) {
      // 关闭对话框即可
    }
    try {
      this.getUIContext().getRouter().clear();
      this.getUIContext().getRouter().replaceUrl({ url: 'pages/OnboardingPage' });
    } catch (e) {
      Logger.warn('reset: route to onboarding failed');
    }
  }

  // ---------------- 设置 ----------------

  @Builder
  SettingsTab() {
    Scroll() {
      Column() {
        Text('设置')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.hb_text'))
          .width('100%')
          .margin({ top: 12 })

        SectionTitle({ title: '同步' })
        Card() {
          Column() {
            SwitchRow({
              title: '同步通知到电脑',
              isOn: !this.settings.paused,
              onToggle: (on: boolean) => this.updateSettings((s: SyncSettings) => {
                s.paused = !on;
              }),
            })
            SwitchRow({
              title: '验证码复制到电脑剪贴板',
              subtitle: '只发送验证码数字，不发送短信全文',
              isOn: this.settings.copyOtp,
              onToggle: (on: boolean) => this.updateSettings((s: SyncSettings) => {
                s.copyOtp = on;
              }),
            })
            SwitchRow({
              title: '不转发银行、支付类通知',
              subtitle: '含余额、转账、付款等字样的通知留在手机上',
              isOn: this.settings.blockSensitive,
              showDivider: false,
              onToggle: (on: boolean) => this.updateSettings((s: SyncSettings) => {
                s.blockSensitive = on;
              }),
            })
          }
        }

        SectionTitle({ title: '设备与权限' })
        Card() {
          Column() {
            NavRow({
              symbol: $r('sys.symbol.checkmark_shield'),
              title: '选择要读取通知的应用',
              subtitle: '系统授权页面',
              onTap: () => {
                this.openGrant();
              },
            })
            NavRow({
              symbol: $r('sys.symbol.bluetooth'),
              title: '蓝牙设备',
              subtitle: this.status.bluetoothReady ? this.status.subscribedName : '未选择',
              onTap: () => this.go('pages/BluetoothPage'),
            })
            NavRow({
              symbol: $r('sys.symbol.desktop'),
              title: 'Mac 连接',
              subtitle: this.status.macNames.length > 0 ? this.status.macNames : '未配对',
              onTap: () => this.goLink('mac'),
            })
            SwitchRow({
              title: '使用 ESP32 通话模块',
              subtitle: this.useEsp32 ? '在电脑端 NotiBridge 中检测和刷写 ESP32（固件开发中）' : '纯软件：同步通知和验证码，不能接打电话',
              isOn: this.useEsp32,
              onToggle: (on: boolean) => {
                this.useEsp32 = on;
                setUseMode(this.ctx(), on ? 'esp32' : 'software');
              },
            })
            NavRow({
              symbol: $r('sys.symbol.desktop'),
              title: 'Windows 连接',
              subtitle: this.status.windowsNames.length > 0 ? this.status.windowsNames : '未配对',
              showDivider: false,
              onTap: () => this.goLink('windows'),
            })
          }
        }

        SectionTitle({ title: '过滤' })
        Card() {
          NavRow({
            symbol: $r('sys.symbol.square_grid_2x2'),
            title: '按应用屏蔽',
            subtitle: this.settings.blockedBundles.length > 0 ?
              `已屏蔽 ${this.settings.blockedBundles.length} 个应用` : '所有已授权应用都会同步',
            showDivider: false,
            onTap: () => this.go('pages/AppFilterPage'),
          })
        }

        SectionTitle({ title: '软件更新' })
        Card() {
          Column() {
            NavRow({
              symbol: $r('sys.symbol.arrow_down_circle'),
              tone: this.update !== undefined && this.update.hasUpdate ? 'accent' : 'neutral',
              title: this.update !== undefined && this.update.hasUpdate ? `有新版本 ${this.update.latest}` : '软件更新',
              subtitle: this.updateSubtitle(),
              chip: this.update !== undefined && this.update.hasUpdate ? '新' : '',
              onTap: () => {
                if (this.update !== undefined && this.update.hasUpdate) {
                  openReleasePage(this.ctx(), this.update.pageUrl);
                } else {
                  this.runUpdateCheck(true);
                }
              },
            })
            NavRow({
              symbol: $r('sys.symbol.arrow_clockwise'),
              tone: 'neutral',
              title: this.update !== undefined && this.update.hasUpdate ? '查看新版本' : '检查更新',
              subtitle: this.update !== undefined && this.update.hasUpdate ? '在浏览器中打开 GitHub 发布页' : '手机端只提醒，不会自动安装',
              showDivider: false,
              onTap: () => {
                if (this.update !== undefined && this.update.hasUpdate) {
                  openReleasePage(this.ctx(), this.update.pageUrl);
                } else {
                  this.runUpdateCheck(true);
                }
              },
            })
          }
        }

        SectionTitle({ title: '其他' })
        Card() {
          Column() {
            NavRow({
              symbol: $r('sys.symbol.arrow_clockwise'),
              tone: 'neutral',
              title: '重新运行设置向导',
              onTap: () => this.go('pages/OnboardingPage'),
            })
            NavRow({
              symbol: $r('sys.symbol.info_circle'),
              tone: 'neutral',
              title: '调试与诊断',
              subtitle: '权限、订阅、错误码等详细信息',
              onTap: () => this.go('pages/DebugPage'),
            })
            NavRow({
              symbol: $r('sys.symbol.trash'),
              tone: 'danger',
              title: '清除所有数据',
              subtitle: '删除配对密钥、设置和通知记录，回到首次使用',
              showDivider: false,
              onTap: () => {
                this.confirmReset();
              },
            })
          }
        }

        Text(`NotiBridge ${this.appVersion} · 通知仅在你的设备之间加密传输`)
          .fontSize(12)
          .fontColor($r('app.color.hb_text3'))
          .margin({ top: 20 })
      }
      .padding({ left: 16, right: 16, bottom: 120 })
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .height('100%')
  }

  @Builder
  TabItem(index: number, symbol: Resource, label: string) {
    Column({ space: 3 }) {
      SymbolGlyph(symbol)
        .fontSize(24)
        .fontColor([this.tab === index ? $r('app.color.hb_accent') : $r('app.color.hb_text3')])
      Text(label)
        .fontSize(11)
        .fontColor(this.tab === index ? $r('app.color.hb_accent') : $r('app.color.hb_text3'))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      AuroraBackground()
      Tabs({ barPosition: BarPosition.End, index: this.tab }) {
        TabContent() {
          this.HomeTab()
        }.tabBar(this.TabItem(0, $r('sys.symbol.house_fill'), '首页'))

        TabContent() {
          this.NotificationsTab()
        }.tabBar(this.TabItem(1, $r('sys.symbol.bell_fill'), '通知'))

        TabContent() {
          this.SettingsTab()
        }.tabBar(this.TabItem(2, $r('sys.symbol.gearshape_fill'), '设置'))
      }
      .onChange((i: number) => {
        this.tab = i;
        if (i === 1) {
          this.loadRecords();
        }
      })
      // 悬浮玻璃底栏（沉浸式系统材质，带交互形变）
      .barFloatingStyle({
        systemMaterial: GLASS_THIN,
        maskColor: Color.Transparent,
      })
      .barOverlap(true)
      .barHeight(64)
      .scrollable(false)
      .animationDuration(0)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}

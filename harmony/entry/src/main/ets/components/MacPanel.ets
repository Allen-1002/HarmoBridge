import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { displayName, FoundMac, MacDiscovery } from '../common/MacDiscovery';
import { LinkState, MacLink } from '../common/MacLink';
import {
  forgetComputer, MacInfo, matchesPlatform, pairedComputers, pendingUnpairs, platformLabel, takeUnpairNotices,
  updateComputerAddress, updatePendingAddress
} from '../common/PairingStore';
import { PendingUnpair, UnpairOutcome } from '../common/PendingUnpair';
import { Card, Chip, IconBadge, PrimaryButton, SectionTitle, Tone } from './UI';

function unpairOutcomeText(name: string, r: UnpairOutcome): string {
  switch (r) {
    case 'delivered':
      return `已删除，“${name}”上的配对也已同步取消`;
    case 'notPaired':
      return `已删除（“${name}”上本来就没有这台手机的配对）`;
    case 'oldVersion':
      return `已删除。“${name}”上的 NotiBridge 版本较旧，请在电脑上手动取消配对`;
    default:
      return `已删除。“${name}”现在不在线，等它上线后会自动取消电脑上的配对`;
  }
}

/**
 * 一台已配对的电脑：状态、测试连接、删除配对。每张卡片有自己独立的加密连接。
 */
@Component
struct ComputerCard {
  mac: MacInfo = { host: '', port: 47800, macId: '', macName: '' };
  // byUser：用户在手机上点了删除；false 表示电脑那边已取消配对、手机自动删除
  onRemoved: (byUser: boolean) => void = () => {
  };
  @State state: LinkState = 'idle';
  @State lastAck: string = '';
  private link: MacLink | undefined = undefined;

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.link = new MacLink(this.ctx(), {
      onState: (s: LinkState) => {
        this.state = s;
      },
      onLog: (ok: boolean, msg: string) => {
        if (!ok) {
          promptAction.showToast({ message: `${this.mac.macName}：${msg}`, duration: 3000 });
        }
      },
      onSas: () => {
      },
      onAck: (seq: number, result: string) => {
        if (result !== 'pong') {
          this.lastAck = result === 'shown' ? '电脑已显示测试通知' : `电脑回执：${result}`;
        }
      },
      onUnpairedByComputer: () => {
        takeUnpairNotices(this.ctx()); // 这里直接提示，不再留到首页
        promptAction.showToast({
          message: `“${this.mac.macName}”已在电脑上取消配对，已从列表中移除。需要时请重新配对。`,
          duration: 3500,
        });
        this.onRemoved(false);
      },
    }, true, this.mac);
  }

  aboutToDisappear(): void {
    this.link?.stop();
  }

  private sendTest(): void {
    const now = Date.now();
    this.link?.sendNotification({
      id: `test-${now}`,
      bundleName: 'com.xsh.notibridge',
      appName: 'NotiBridge',
      title: '连接测试',
      text: '这是一条从手机发出的测试消息',
      time: now,
      test: true,
    });
  }

  private stateChip(): string {
    switch (this.state) {
      case 'online':
        return '已连接';
      case 'connecting':
      case 'authenticating':
        return '连接中';
      case 'error':
        return '出错';
      default:
        return '待命';
    }
  }

  private stateTone(): Tone {
    return this.state === 'online' ? 'success' : this.state === 'error' ? 'danger' : 'neutral';
  }

  build() {
    Column() {
      Card() {
        Column() {
          Row() {
            IconBadge({ symbol: $r('sys.symbol.desktop'), tone: 'accent', boxSize: 44 })
            Column() {
              Text(this.mac.macName).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.hb_text'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${platformLabel(this.mac)} · ${this.mac.host}:${this.mac.port}`)
                .fontSize(13).fontColor($r('app.color.hb_text2')).margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 12 })

            Chip({ text: this.stateChip(), tone: this.stateTone() })
          }
          .width('100%')

          Row({ space: 10 }) {
            Button(this.state === 'online' ? '发送测试通知' : '测试连接')
              .layoutWeight(1)
              .height(38)
              .fontSize(14)
              .backgroundColor($r('app.color.hb_accent'))
              .onClick(() => {
                if (this.state === 'online') {
                  this.sendTest();
                } else {
                  this.lastAck = '';
                  this.link?.connect();
                }
              })
            if (this.state === 'online') {
              Button('断开')
                .height(38)
                .fontSize(14)
                .fontColor($r('app.color.hb_text'))
                .backgroundColor($r('app.color.hb_bg'))
                .onClick(() => this.link?.stop())
            }
            Button('删除')
              .height(38)
              .fontSize(14)
              .fontColor($r('app.color.hb_danger'))
              .backgroundColor($r('app.color.hb_danger_soft'))
              .onClick(() => {
                this.getUIContext().showAlertDialog({
                  title: `删除“${this.mac.macName}”？`,
                  message: '删除后这台电脑不再收到通知，需要重新配对才能恢复。电脑在线时会同步取消电脑上的配对；不在线时，等它下次上线（和手机在同一 Wi-Fi）会自动取消。',
                  primaryButton: { value: '取消', action: () => {
                  } },
                  secondaryButton: {
                    value: '删除',
                    fontColor: $r('app.color.hb_danger'),
                    action: () => {
                      this.link?.stop();
                      const ctx = this.ctx();
                      const name = this.mac.macName;
                      forgetComputer(ctx, this.mac.macId, true);
                      this.onRemoved(true);
                      // 立即尝试通知电脑；连不上时保留在待通知列表，之后自动重试
                      PendingUnpair.flush(ctx, this.mac.macId, true, (m: MacInfo, r: UnpairOutcome) => {
                        promptAction.showToast({ message: unpairOutcomeText(name, r), duration: 3000 });
                      });
                    },
                  },
                });
              })
          }
          .width('100%')
          .margin({ top: 12 })

          if (this.lastAck.length > 0) {
            Text(this.lastAck).fontSize(13).fontColor($r('app.color.hb_success')).margin({ top: 8 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding(16)
      }
    }
    .width('100%')
    .margin({ bottom: 12 })
  }
}

/**
 * 电脑（Mac / Windows）配对与连接：自动发现 → 输入电脑上的配对码 → 核对校验码 → 完成。
 * 可以配对多台电脑，通知会同时转发给每一台。引导页和“电脑连接”页共用。
 */
@Component
export struct MacPanel {
  @State host: string = '';
  @State port: string = '47800';
  @State pin: string = '';
  @State state: LinkState = 'idle';
  @State detail: string = '';
  @State sasCode: string = '';
  @State computers: Array<MacInfo> = [];
  @State adding: boolean = false;
  @State found: Array<FoundMac> = [];
  @State searching: boolean = false;
  @State manual: boolean = false;
  // 'mac' / 'windows'：只显示和配对该平台的电脑（设置里的“Mac 连接”“Windows 连接”）；为空时显示全部（引导页）
  platform: string = '';
  onPaired: () => void = () => {
  };
  private link: MacLink | undefined = undefined;
  private discovery: MacDiscovery = new MacDiscovery();

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    // 只用于配对新电脑；已配对电脑的连接由各自的卡片管理
    this.link = this.newPairingLink();
    this.reload();
    if (this.computers.length > 0) {
      this.onPaired();
    }
    // 已配对时也搜索一次：电脑换了 IP 时自动更新地址
    this.search();
  }

  /** 配对用的链路。配对成功后这条链路就属于那台电脑了，下一台电脑换一条新的。 */
  private newPairingLink(): MacLink {
    const old = this.link;
    const l = new MacLink(this.ctx(), {
      onState: (s: LinkState, d: string) => {
        const wasPairing = this.state === 'pairing' || this.state === 'awaitingSasConfirm';
        this.state = s;
        this.detail = d;
        if (s !== 'awaitingSasConfirm') {
          this.sasCode = '';
        }
        const newMac = this.link?.pairedMac();
        if (wasPairing && s === 'idle' && newMac !== undefined) {
          this.pin = '';
          this.adding = false;
          if (!matchesPlatform(newMac, this.platform)) {
            promptAction.showToast({
              message: `${newMac.macName} 是 ${platformLabel(newMac)} 电脑，已放到“${platformLabel(newMac)} 连接”里`,
              duration: 3000,
            });
          }
          this.reload();
          this.onPaired();
          this.link = this.newPairingLink();
        }
      },
      onLog: (ok: boolean, msg: string) => {
        promptAction.showToast({ message: msg, duration: ok ? 2000 : 3000 });
      },
      onSas: (code: string) => {
        this.sasCode = code;
      },
      onAck: () => {
      },
    });
    old?.stop();
    return l;
  }

  aboutToDisappear(): void {
    this.discovery.stop();
    this.link?.stop();
  }

  private reload(): void {
    this.computers = pairedComputers(this.ctx()).filter((m: MacInfo) => matchesPlatform(m, this.platform));
  }

  private platformName(): string {
    return this.platform === 'windows' ? 'Windows 电脑' : this.platform === 'mac' ? 'Mac' : '电脑';
  }

  /** 发现到的服务平台未知（TXT 读不到）时两个页面都显示。 */
  private foundMatches(m: FoundMac): boolean {
    if (this.platform.length === 0 || m.platform.length === 0) {
      return true;
    }
    return m.platform === this.platform;
  }

  private pairingHint(): string {
    if (this.platform === 'windows') {
      return '在 Windows 电脑上打开 NotiBridge，右键任务栏托盘图标 →“配对新手机”（或主窗口“设备与配对”→“生成配对码”），屏幕上会出现 6 位配对码。';
    }
    if (this.platform === 'mac') {
      return '在 Mac 菜单栏点 NotiBridge 图标 →“配对新手机”，屏幕上会出现 6 位配对码。';
    }
    return 'Mac：点菜单栏 NotiBridge 图标 →“配对新手机”。Windows：右键任务栏托盘图标 →“配对新手机”。屏幕上会出现 6 位配对码。';
  }

  private isPaired(m: FoundMac): boolean {
    return this.matchPaired(m) !== undefined;
  }

  private matchPaired(m: FoundMac): MacInfo | undefined {
    // 地址更新对所有已配对电脑生效，不只当前页面的平台
    const all: Array<MacInfo> = pairedComputers(this.ctx());
    if (m.id.length > 0) {
      const byId = all.find((c: MacInfo) => c.macId === m.id);
      if (byId !== undefined) {
        return byId;
      }
    }
    return all.find((c: MacInfo) => c.macName === displayName(m.name));
  }

  private search(): void {
    this.found = [];
    this.searching = true;
    this.discovery.start(this.ctx(), (m: FoundMac) => {
      const paired = this.matchPaired(m);
      if (paired !== undefined && updateComputerAddress(this.ctx(), paired.macId, m.host, m.port)) {
        this.reload();
      }
      // 在手机上删除过、但当时不在线的电脑出现了：更新地址并通知它取消配对
      if (m.id.length > 0 && pendingUnpairs(this.ctx()).find((x: MacInfo) => x.macId === m.id) !== undefined) {
        updatePendingAddress(this.ctx(), m.id, m.host, m.port);
        PendingUnpair.flush(this.ctx(), m.id, true);
      }
      if (!this.foundMatches(m)) {
        return;
      }
      if (this.found.find((f: FoundMac) => f.host === m.host && f.port === m.port) === undefined) {
        this.found = this.found.concat([m]);
        if (this.host.length === 0 && paired === undefined) {
          this.host = m.host;
          this.port = `${m.port}`;
        }
      }
    }, () => {
      this.searching = false;
    });
  }

  private startPairing(): void {
    const p = Number.parseInt(this.port);
    this.link?.startPairing(this.host.trim(), Number.isNaN(p) ? 47800 : p, this.pin.trim());
  }

  private foundLabel(m: FoundMac): string {
    const plat = m.platform === 'windows' ? 'Windows' : m.platform === 'mac' ? 'Mac' : '';
    const prefix = plat.length > 0 ? `${plat} · ` : '';
    return `${prefix}${m.host}:${m.port}${this.isPaired(m) ? ' · 已配对' : ''}`;
  }

  @Builder
  PairedList() {
    ForEach(this.computers, (m: MacInfo) => {
      ComputerCard({
        mac: m,
        onRemoved: () => {
          this.reload();
        },
      })
    }, (m: MacInfo) => `${m.macId}|${m.host}|${m.port}`)

    Text('通知会同时转发给每台已配对的电脑（Mac 和 Windows 都算），由系统在后台按需连接，不需要保持这个页面打开。上面的按钮只用来测试连接。')
      .fontSize(12)
      .fontColor($r('app.color.hb_text2'))
      .margin({ bottom: 12 })

    if (!this.adding) {
      Button(`添加${this.platformName()}`)
        .width('100%')
        .height(44)
        .fontColor($r('app.color.hb_accent'))
        .backgroundColor($r('app.color.hb_bg'))
        .onClick(() => {
          this.adding = true;
          this.search();
        })
    }
  }

  @Builder
  PairingView() {
    SectionTitle({ title: `1. 选择${this.platformName()}` })
    Card() {
      Column() {
        if (this.found.length === 0 && !this.manual) {
          Row() {
            if (this.searching) {
              LoadingProgress().width(22).height(22).color($r('app.color.hb_accent'))
            }
            Text(this.searching ? `正在局域网中查找${this.platformName()}…` :
              (this.platform === 'windows' ?
                '没有找到。确认 Windows 上 NotiBridge 已运行、和手机在同一 Wi-Fi，并在防火墙中允许“专用网络”；也可以手动输入电脑 IP' :
                `没有找到。确认${this.platformName()}上 NotiBridge 已运行、和手机在同一 Wi-Fi`))
              .fontSize(13)
              .fontColor($r('app.color.hb_text2'))
              .margin({ left: this.searching ? 10 : 0 })
              .layoutWeight(1)
          }
          .padding(16)
        }
        ForEach(this.found, (m: FoundMac) => {
          Row() {
            IconBadge({ symbol: $r('sys.symbol.desktop'), tone: 'accent', boxSize: 34 })
            Column() {
              Text(displayName(m.name)).fontSize(15).fontColor($r('app.color.hb_text'))
              Text(this.foundLabel(m)).fontSize(12).fontColor($r('app.color.hb_text2'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 12 })

            if (this.host === m.host) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20).fontColor([$r('app.color.hb_accent')])
            }
          }
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .onClick(() => {
            this.host = m.host;
            this.port = `${m.port}`;
          })
        }, (m: FoundMac) => `${m.host}:${m.port}`)

        if (this.manual) {
          Row({ space: 8 }) {
            TextInput({ placeholder: `${this.platformName()} IP 地址`, text: $$this.host }).layoutWeight(3)
            TextInput({ placeholder: '端口', text: $$this.port }).layoutWeight(1).type(InputType.Number)
          }
          .padding(12)
        }
        Row() {
          Text(this.manual ? '收起手动输入' : '手动输入地址')
            .fontSize(13)
            .fontColor($r('app.color.hb_accent'))
            .onClick(() => {
              this.manual = !this.manual;
            })
          Blank()
          Text('重新搜索')
            .fontSize(13)
            .fontColor($r('app.color.hb_accent'))
            .onClick(() => this.search())
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 12, top: 4 })
      }
    }

    SectionTitle({ title: `2. 输入${this.platformName()}上显示的配对码` })
    Card() {
      Column({ space: 12 }) {
        Text(this.pairingHint())
          .fontSize(13)
          .fontColor($r('app.color.hb_text2'))
        TextInput({ placeholder: '6 位配对码', text: $$this.pin })
          .type(InputType.Number)
          .maxLength(6)
          .fontSize(24)
          .letterSpacing(8)
          .textAlign(TextAlign.Center)
          .height(56)
        PrimaryButton({
          label: this.state === 'pairing' || this.state === 'connecting' ? '配对中…' : '开始配对',
          enabledState: this.host.length > 0 && this.pin.length === 6 && this.state !== 'pairing',
          onTap: () => this.startPairing(),
        })
      }
      .alignItems(HorizontalAlign.Start)
      .padding(16)
    }

    if (this.sasCode.length > 0) {
      SectionTitle({ title: '3. 核对校验码' })
      Card() {
        Column({ space: 10 }) {
          Text(this.sasCode)
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(6)
            .fontColor($r('app.color.hb_text'))
            .width('100%')
            .textAlign(TextAlign.Center)
          Text('确认电脑上显示的校验码与上面完全一致。不一致说明连接可能被冒充，请取消。')
            .fontSize(13)
            .fontColor($r('app.color.hb_text2'))
          Row({ space: 10 }) {
            Button('不一致，取消')
              .layoutWeight(1)
              .height(44)
              .fontColor($r('app.color.hb_danger'))
              .backgroundColor($r('app.color.hb_danger_soft'))
              .onClick(() => this.link?.stop())
            Button('一致，确认')
              .layoutWeight(1)
              .height(44)
              .backgroundColor($r('app.color.hb_success'))
              .onClick(() => this.link?.confirmSas())
          }
          .width('100%')
        }
        .padding(16)
      }
    }

    if (this.computers.length > 0) {
      Text('取消添加')
        .fontSize(14)
        .fontColor($r('app.color.hb_text2'))
        .margin({ top: 16 })
        .onClick(() => {
          this.link?.stop();
          this.adding = false;
        })
    }
  }

  build() {
    Column() {
      if (this.computers.length > 0) {
        this.PairedList()
      }
      if (this.computers.length === 0 || this.adding) {
        this.PairingView()
      }
    }
    .width('100%')
  }
}

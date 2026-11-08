import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { FoundMac, MacDiscovery } from '../common/MacDiscovery';
import { LinkState, MacLink } from '../common/MacLink';
import { forgetMac, MacInfo } from '../common/PairingStore';
import { Card, Chip, IconBadge, PrimaryButton, SectionTitle, Tone } from './UI';

/**
 * Mac 配对与连接：自动发现 → 输入 Mac 上的配对码 → 核对校验码 → 完成。
 * 已配对时显示 Mac 信息和测试入口。引导页和“Mac 连接”页共用。
 */
@Component
export struct MacPanel {
  @State host: string = '';
  @State port: string = '47800';
  @State pin: string = '';
  @State state: LinkState = 'idle';
  @State detail: string = '';
  @State sasCode: string = '';
  @State paired: MacInfo | undefined = undefined;
  @State found: Array<FoundMac> = [];
  @State searching: boolean = false;
  @State manual: boolean = false;
  @State lastAck: string = '';
  onPaired: () => void = () => {
  };
  private link: MacLink | undefined = undefined;
  private discovery: MacDiscovery = new MacDiscovery();

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.link = new MacLink(this.ctx(), {
      onState: (s: LinkState, d: string) => {
        const wasPairing = this.state === 'pairing' || this.state === 'awaitingSasConfirm';
        this.state = s;
        this.detail = d;
        if (s !== 'awaitingSasConfirm') {
          this.sasCode = '';
        }
        this.paired = this.link?.pairedMac();
        if (wasPairing && s === 'idle' && this.paired !== undefined) {
          this.pin = '';
          this.onPaired();
        }
      },
      onLog: (ok: boolean, msg: string) => {
        if (!ok) {
          promptAction.showToast({ message: msg, duration: 3000 });
        }
      },
      onSas: (code: string) => {
        this.sasCode = code;
      },
      onAck: (seq: number, result: string) => {
        if (result !== 'pong') {
          this.lastAck = result === 'shown' ? 'Mac 已显示测试通知' : `Mac 回执：${result}`;
        }
      },
    });
    this.paired = this.link.pairedMac();
    if (this.paired === undefined) {
      this.search();
    } else {
      this.onPaired();
    }
  }

  aboutToDisappear(): void {
    this.discovery.stop();
    this.link?.stop();
  }

  private search(): void {
    this.found = [];
    this.searching = true;
    this.discovery.start(this.ctx(), (m: FoundMac) => {
      if (this.found.find((f: FoundMac) => f.host === m.host && f.port === m.port) === undefined) {
        this.found = this.found.concat([m]);
        if (this.host.length === 0) {
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

  private sendTest(): void {
    const now = Date.now();
    this.link?.sendNotification({
      id: `test-${now}`,
      bundleName: 'com.xsh.harmobridge',
      appName: 'HarmoBridge',
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

  @Builder
  PairedView() {
    Card() {
      Column() {
        Row() {
          IconBadge({ symbol: $r('sys.symbol.desktop'), tone: 'accent', boxSize: 44 })
          Column() {
            Text(this.paired?.macName ?? 'Mac').fontSize(17).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.hb_text'))
            Text(`${this.paired?.host}:${this.paired?.port}`).fontSize(13).fontColor($r('app.color.hb_text2'))
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 12 })

          Chip({ text: this.stateChip(), tone: this.stateTone() })
        }
        .width('100%')

        Text('通知由系统在后台按需转发，不需要保持这个页面打开。下面的按钮只用来测试连接。')
          .fontSize(12)
          .fontColor($r('app.color.hb_text2'))
          .margin({ top: 12 })

        Row({ space: 10 }) {
          Button(this.state === 'online' ? '发送测试通知' : '测试连接')
            .layoutWeight(1)
            .height(40)
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
              .height(40)
              .fontSize(14)
              .fontColor($r('app.color.hb_text'))
              .backgroundColor($r('app.color.hb_bg'))
              .onClick(() => this.link?.stop())
          }
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

    Text('删除配对')
      .fontSize(14)
      .fontColor($r('app.color.hb_danger'))
      .margin({ top: 20 })
      .onClick(() => {
        this.link?.stop();
        forgetMac(this.ctx());
        this.paired = undefined;
        this.search();
        promptAction.showToast({ message: '已删除配对，Mac 端也请取消配对' });
      })
  }

  @Builder
  PairingView() {
    SectionTitle({ title: '1. 选择 Mac' })
    Card() {
      Column() {
        if (this.found.length === 0 && !this.manual) {
          Row() {
            if (this.searching) {
              LoadingProgress().width(22).height(22).color($r('app.color.hb_accent'))
            }
            Text(this.searching ? '正在局域网中查找 Mac…' : '没有找到。确认 Mac 上 HarmoBridge 已运行、和手机在同一 Wi-Fi')
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
              Text(m.name.replace('HarmoBridge-', '')).fontSize(15).fontColor($r('app.color.hb_text'))
              Text(`${m.host}:${m.port}`).fontSize(12).fontColor($r('app.color.hb_text2'))
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
            TextInput({ placeholder: 'Mac IP 地址', text: $$this.host }).layoutWeight(3)
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

    SectionTitle({ title: '2. 输入 Mac 上显示的配对码' })
    Card() {
      Column({ space: 12 }) {
        Text('在 Mac 菜单栏点 HarmoBridge 图标 →“配对新手机”，屏幕上会出现 6 位配对码。')
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
          Text('确认 Mac 上显示的校验码与上面完全一致。不一致说明连接可能被冒充，请取消。')
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
  }

  build() {
    Column() {
      if (this.paired !== undefined) {
        this.PairedView()
      } else {
        this.PairingView()
      }
    }
    .width('100%')
  }
}

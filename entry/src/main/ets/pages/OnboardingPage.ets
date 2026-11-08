import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { setOnboarded } from '../common/AppStatus';
import { describeError } from '../common/ErrorDescriber';
import { getGrantedBundles, isPermissionGranted, isUserGranted, openGrantSettings, PERM_SUBSCRIBE }
  from '../common/SubscriptionService';
import { BluetoothPanel } from '../components/BluetoothPanel';
import { MacPanel } from '../components/MacPanel';
import { Card, Chip, IconBadge, PrimaryButton, auroraBackground } from '../components/UI';

interface StepInfo {
  title: string;
  desc: string;
}

const STEPS: Array<StepInfo> = [
  { title: '欢迎使用 HarmoBridge', desc: '把手机通知安全地同步到你的 Mac。数据只在你自己的设备之间加密传输，不经过任何服务器。' },
  { title: '允许读取通知', desc: '在系统弹出的页面中打开“允许获取本机通知”，并勾选要同步到 Mac 的应用。' },
  { title: '选择蓝牙设备', desc: '系统要求通知订阅绑定一台已配对的蓝牙设备。推荐直接选择你的 Mac。' },
  { title: '连接 Mac', desc: '在 Mac 上打开 HarmoBridge，点菜单栏图标 →“配对新手机”。' },
  { title: '设置完成', desc: '之后不需要保持 App 打开，熄屏或清理后台后，通知也会自动同步到 Mac。' },
];

@Entry
@Component
struct OnboardingPage {
  @State step: number = 0;
  @State permGranted: boolean = false;
  @State userGranted: boolean = false;
  @State grantedApps: number = 0;
  @State btDone: boolean = false;
  @State macDone: boolean = false;
  private scroller: Scroller = new Scroller();

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.checkGrant();
  }

  private async checkGrant(): Promise<void> {
    try {
      this.permGranted = isPermissionGranted(PERM_SUBSCRIBE);
      if (this.permGranted) {
        this.userGranted = await isUserGranted();
        this.grantedApps = (await getGrantedBundles()).length;
      }
    } catch (e) {
      this.userGranted = false;
    }
  }

  private async openGrant(): Promise<void> {
    try {
      await openGrantSettings(this.ctx());
    } catch (e) {
      promptAction.showToast({ message: describeError(e), duration: 3000 });
    }
    await this.checkGrant();
  }

  private canNext(): boolean {
    switch (this.step) {
      case 1:
        return this.userGranted;
      case 2:
        return this.btDone;
      case 3:
        return this.macDone;
      default:
        return true;
    }
  }

  private next(): void {
    if (this.step >= STEPS.length - 1) {
      setOnboarded(this.ctx(), true);
      this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' });
      return;
    }
    this.step++;
    this.scroller.scrollEdge(Edge.Top);
  }

  @Builder
  Dots() {
    Row({ space: 6 }) {
      ForEach([0, 1, 2, 3, 4], (i: number) => {
        Row()
          .width(i === this.step ? 22 : 8)
          .height(8)
          .borderRadius(4)
          .backgroundColor(i <= this.step ? $r('app.color.hb_accent') : $r('app.color.hb_divider'))
          .animation({ duration: 250 })
      }, (i: number) => `${i}`)
    }
  }

  @Builder
  Hero(symbol: Resource) {
    Stack() {
      SymbolGlyph(symbol).fontSize(56).fontColor([Color.White])
    }
    .width(112)
    .height(112)
    .borderRadius(32)
    .linearGradient({
      angle: 135,
      colors: [[$r('app.color.hb_hero_start'), 0], [$r('app.color.hb_hero_end'), 1]],
    })
    .margin({ top: 24, bottom: 8 })
  }

  @Builder
  StepBody() {
    if (this.step === 0) {
      Column({ space: 12 }) {
        this.Hero($r('sys.symbol.bell_fill'))
        Card() {
          Column({ space: 14 }) {
            this.Feature($r('sys.symbol.bell_fill'), '通知同步', '微信、短信、邮件等通知实时出现在 Mac 通知中心')
            this.Feature($r('sys.symbol.text_clipboard'), '验证码自动复制', '收到验证码短信，Mac 上直接粘贴')
            this.Feature($r('sys.symbol.lock_shield'), '本地加密', '只在你的手机和 Mac 之间传输，配对后加密')
          }
          .padding(16)
        }
        Card() {
          Column({ space: 10 }) {
            Text('需要的权限').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.hb_text'))
            this.PermLine('读取本机通知', '必需', '把你选择的应用的通知转发到 Mac；在系统授权页中可逐个选择应用')
            this.PermLine('蓝牙', '必需', '系统规定读取通知必须绑定一台已配对的蓝牙设备（例如你的 Mac）')
            this.PermLine('本地网络', '自动', '在同一 Wi-Fi 下把通知加密发送到 Mac，不经过任何服务器')
          }
          .alignItems(HorizontalAlign.Start)
          .padding(16)
        }
      }
    } else if (this.step === 1) {
      Column({ space: 12 }) {
        this.Hero($r('sys.symbol.checkmark_shield'))
        Card() {
          Column({ space: 12 }) {
            Row() {
              Text('系统通知权限').fontSize(15).fontColor($r('app.color.hb_text')).layoutWeight(1)
              Chip({ text: this.permGranted ? '已获得' : '缺失', tone: this.permGranted ? 'success' : 'danger' })
            }
            Row() {
              Text('允许获取本机通知').fontSize(15).fontColor($r('app.color.hb_text')).layoutWeight(1)
              Chip({
                text: this.userGranted ? `已开启 · ${this.grantedApps} 个应用` : '未开启',
                tone: this.userGranted ? 'success' : 'warning'
              })
            }
            if (!this.permGranted) {
              Text('当前安装包的签名不包含通知订阅权限，请在 DevEco Studio 中重新自动签名后安装。')
                .fontSize(13).fontColor($r('app.color.hb_danger'))
            }
            Button(this.userGranted ? '修改授权的应用' : '打开授权页面')
              .width('100%')
              .height(44)
              .backgroundColor($r('app.color.hb_accent'))
              .enabled(this.permGranted)
              .onClick(() => this.openGrant())
          }
          .padding(16)
        }
      }
    } else if (this.step === 2) {
      BluetoothPanel({
        onChanged: (addr: string) => {
          this.btDone = addr.length > 0;
        }
      })
    } else if (this.step === 3) {
      MacPanel({
        onPaired: () => {
          this.macDone = true;
        }
      })
    } else {
      Column({ space: 12 }) {
        this.Hero($r('sys.symbol.checkmark'))
        Text('可以试试让朋友给你发一条消息，Mac 上会立即弹出通知。')
          .fontSize(14)
          .fontColor($r('app.color.hb_text2'))
          .textAlign(TextAlign.Center)
      }
      .width('100%')
    }
  }

  @Builder
  PermLine(name: string, tag: string, reason: string) {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        Text(name).fontSize(14).fontColor($r('app.color.hb_text'))
        Text(tag)
          .fontSize(11)
          .fontColor(tag === '必需' ? $r('app.color.hb_danger') : $r('app.color.hb_text2'))
          .backgroundColor(tag === '必需' ? $r('app.color.hb_danger_soft') : $r('app.color.hb_divider'))
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .borderRadius(8)
      }
      Text(reason).fontSize(12).fontColor($r('app.color.hb_text2'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  Feature(symbol: Resource, title: string, desc: string) {
    Row() {
      IconBadge({ symbol: symbol, tone: 'accent', boxSize: 40 })
      Column() {
        Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.hb_text'))
        Text(desc).fontSize(13).fontColor($r('app.color.hb_text2')).margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
    }
    .width('100%')
  }

  build() {
    Column() {
      Row() {
        this.Dots()
        Blank()
        if (this.step > 0 && this.step < STEPS.length - 1) {
          Text('稍后设置')
            .fontSize(14)
            .fontColor($r('app.color.hb_text2'))
            .onClick(() => {
              setOnboarded(this.ctx(), true);
              this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' });
            })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16 })

      Scroll(this.scroller) {
        Column() {
          Text(STEPS[this.step].title)
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.hb_text'))
            .width('100%')
            .margin({ top: 20 })
          Text(STEPS[this.step].desc)
            .fontSize(14)
            .fontColor($r('app.color.hb_text2'))
            .width('100%')
            .margin({ top: 8, bottom: 8 })
          this.StepBody()
        }
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      Column({ space: 8 }) {
        PrimaryButton({
          label: this.step === 0 ? '开始设置' : this.step === STEPS.length - 1 ? '进入 HarmoBridge' : '下一步',
          enabledState: this.canNext(),
          onTap: () => this.next(),
        })
        if (this.step > 0 && this.step < STEPS.length - 1) {
          Text('上一步')
            .fontSize(14)
            .fontColor($r('app.color.hb_text2'))
            .padding(6)
            .onClick(() => {
              this.step--;
              this.scroller.scrollEdge(Edge.Top);
            })
        }
      }
      .padding({ left: 20, right: 20, bottom: 16, top: 8 })
    }
    .width('100%')
    .height('100%')
    .background(auroraBackground)
  }
}

import { MacPanel } from '../components/MacPanel';
import { PageHeader, auroraBackground } from '../components/UI';

interface LinkPageParams {
  platform?: string;
}

/** 设置里的“Mac 连接”“Windows 连接”共用这个页面，用路由参数 platform 区分。 */
@Entry
@Component
struct MacLinkPage {
  private platform: string = '';

  aboutToAppear(): void {
    const p = this.getUIContext().getRouter().getParams() as LinkPageParams | undefined;
    this.platform = p?.platform ?? '';
  }

  private title(): string {
    return this.platform === 'windows' ? 'Windows 连接' : this.platform === 'mac' ? 'Mac 连接' : '电脑连接';
  }

  build() {
    Column() {
      PageHeader({ title: this.title() })
      Scroll() {
        Column() {
          MacPanel({ platform: this.platform })
        }
        .padding({ left: 16, right: 16, bottom: 40 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .background(auroraBackground)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}

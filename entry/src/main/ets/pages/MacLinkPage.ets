import { MacPanel } from '../components/MacPanel';
import { PageHeader, auroraBackground } from '../components/UI';

@Entry
@Component
struct MacLinkPage {
  build() {
    Column() {
      PageHeader({ title: '电脑连接' })
      Scroll() {
        Column() {
          MacPanel()
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

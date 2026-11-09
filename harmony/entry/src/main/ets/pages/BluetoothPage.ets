import { BluetoothPanel } from '../components/BluetoothPanel';
import { PageHeader, auroraBackground } from '../components/UI';

@Entry
@Component
struct BluetoothPage {
  build() {
    Column() {
      PageHeader({ title: '蓝牙设备' })
      Scroll() {
        Column() {
          Text('系统要求通知订阅绑定一台已配对的蓝牙设备（可以是你的 Mac 或 ESP32）。订阅后只需保持配对，不需要一直连接。')
            .fontSize(13)
            .fontColor($r('app.color.hb_text2'))
            .margin({ left: 4, right: 4 })
          BluetoothPanel()
        }
        .padding({ left: 16, right: 16, bottom: 40 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .background(auroraBackground)
  }
}

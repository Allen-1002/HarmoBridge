import { common } from '@kit.AbilityKit';
import { EventRecord, readRecords } from '../common/NotificationStore';
import { loadSettings, saveSettings, SyncSettings } from '../common/PhoneFilter';
import { getGrantedBundles } from '../common/SubscriptionService';
import { Card, PageHeader, SwitchRow, auroraBackground } from '../components/UI';

interface AppItem {
  bundle: string;
  name: string;
}

/** 按应用屏蔽：已授权的应用和最近出现过通知的应用，关掉开关即不再转发到 Mac。 */
@Entry
@Component
struct AppFilterPage {
  @State apps: Array<AppItem> = [];
  @State blocked: Array<string> = [];

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  async aboutToAppear(): Promise<void> {
    this.blocked = loadSettings(this.ctx()).blockedBundles;
    const map: Map<string, string> = new Map<string, string>();
    try {
      const granted = await getGrantedBundles();
      granted.forEach((g) => map.set(g.bundleName, g.appName ?? g.bundleName));
    } catch (e) {
      // 未授权时只显示最近出现过的应用
    }
    readRecords(this.ctx().filesDir).forEach((r: EventRecord) => {
      if (r.kind === 'publish' && r.bundleName !== undefined && !map.has(r.bundleName)) {
        map.set(r.bundleName, r.appName ?? r.bundleName);
      }
    });
    this.blocked.forEach((b: string) => {
      if (!map.has(b)) {
        map.set(b, b);
      }
    });
    const list: Array<AppItem> = [];
    map.forEach((name: string, bundle: string) => list.push({ bundle: bundle, name: name }));
    this.apps = list.sort((a: AppItem, b: AppItem) => a.name.localeCompare(b.name));
  }

  private toggle(bundle: string, on: boolean): void {
    const s: SyncSettings = loadSettings(this.ctx());
    const set = s.blockedBundles.filter((b: string) => b !== bundle);
    if (!on) {
      set.push(bundle);
    }
    s.blockedBundles = set;
    saveSettings(this.ctx(), s);
    this.blocked = set;
  }

  build() {
    Column() {
      PageHeader({ title: '按应用屏蔽' })
      Scroll() {
        Column() {
          Text('关闭开关的应用，其通知只留在手机上，不会转发到 Mac。要增加可读取的应用，请在“设置 > 选择要读取通知的应用”中授权。')
            .fontSize(13)
            .fontColor($r('app.color.hb_text2'))
            .margin({ bottom: 12, left: 4, right: 4 })
          Card() {
            Column() {
              if (this.apps.length === 0) {
                Text('暂无应用').fontSize(14).fontColor($r('app.color.hb_text2')).padding(16)
              }
              ForEach(this.apps, (a: AppItem, i: number) => {
                SwitchRow({
                  title: a.name,
                  subtitle: a.bundle,
                  isOn: this.blocked.indexOf(a.bundle) < 0,
                  showDivider: i < this.apps.length - 1,
                  onToggle: (on: boolean) => this.toggle(a.bundle, on),
                })
              }, (a: AppItem) => `${a.bundle}-${this.blocked.indexOf(a.bundle) < 0}`)
            }
          }
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

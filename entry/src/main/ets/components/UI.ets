import { uiMaterial } from '@kit.ArkUI';

/**
 * HarmoBridge 通用界面组件：卡片、分组标题、设置行、状态行、标签。
 * 颜色全部来自 resources 中的 hb_* 颜色，自动适配深色模式。
 */

/** 沉浸式玻璃材质（系统不支持时无效果，回退到卡片背景色）。 */
export const GLASS: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.REGULAR,
});
export const GLASS_THIN: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN,
  interactive: true,
});

export type Tone = 'accent' | 'success' | 'warning' | 'danger' | 'neutral';

export function toneColor(t: Tone): Resource {
  switch (t) {
    case 'success':
      return $r('app.color.hb_success');
    case 'warning':
      return $r('app.color.hb_warning');
    case 'danger':
      return $r('app.color.hb_danger');
    case 'neutral':
      return $r('app.color.hb_text3');
    default:
      return $r('app.color.hb_accent');
  }
}

export function toneSoft(t: Tone): Resource {
  switch (t) {
    case 'success':
      return $r('app.color.hb_success_soft');
    case 'warning':
      return $r('app.color.hb_warning_soft');
    case 'danger':
      return $r('app.color.hb_danger_soft');
    case 'neutral':
      return $r('app.color.hb_divider');
    default:
      return $r('app.color.hb_accent_soft');
  }
}

/** 分组标题 */
@Component
export struct SectionTitle {
  title: string = '';

  build() {
    Text(this.title)
      .fontSize(13)
      .fontColor($r('app.color.hb_text2'))
      .margin({ left: 16, top: 20, bottom: 8 })
      .width('100%')
  }
}

/** 白色圆角卡片容器 */
@Component
export struct Card {
  @BuilderParam content: () => void;

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .backgroundColor($r('app.color.hb_card'))
    .borderRadius(20)
    .systemMaterial(GLASS)
  }
}

/** 页面背景：底色 + 两团柔和的彩色光晕，让玻璃材质有可折射的内容。 */
@Component
export struct AuroraBackground {
  @Builder
  Glow(size: number, x: number, y: number, color: string) {
    Column()
      .width(size)
      .height(size)
      .position({ x: x, y: y })
      .radialGradient({
        center: [size / 2, size / 2],
        radius: size / 2,
        colors: [[color, 0], ['#00' + color.substring(3), 1]],
      })
  }

  build() {
    Stack() {
      // 颜色带透明度（#AARRGGBB），边缘渐隐到全透明，形成柔和光晕
      this.Glow(460, -160, -120, '#663949AB')
      this.Glow(420, 140, 60, '#5500BFA5')
      this.Glow(380, -40, 460, '#331E88E5')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.hb_bg'))
    .clip(true)
  }
}

/** 小标签 */
@Component
export struct Chip {
  @Prop text: string = '';
  @Prop tone: Tone = 'accent';

  build() {
    Text(this.text)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(toneColor(this.tone))
      .backgroundColor(toneSoft(this.tone))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(10)
  }
}

/** 圆形图标底座 */
@Component
export struct IconBadge {
  symbol: Resource = $r('sys.symbol.bell_fill');
  @Prop tone: Tone = 'accent';
  boxSize: number = 36;

  build() {
    Stack() {
      SymbolGlyph(this.symbol)
        .fontSize(this.boxSize * 0.5)
        .fontColor([toneColor(this.tone)])
    }
    .width(this.boxSize)
    .height(this.boxSize)
    .borderRadius(this.boxSize / 2.8)
    .backgroundColor(toneSoft(this.tone))
  }
}

/** 列表行：图标 + 标题/副标题 + 右侧标签 + 箭头，可点击 */
@Component
export struct NavRow {
  symbol: Resource = $r('sys.symbol.bell_fill');
  @Prop tone: Tone = 'accent';
  title: string = '';
  @Prop subtitle: string = '';
  @Prop chip: string = '';
  @Prop chipTone: Tone = 'accent';
  showArrow: boolean = true;
  showDivider: boolean = true;
  onTap: () => void = () => {
  };

  build() {
    Column() {
      Row() {
        IconBadge({ symbol: this.symbol, tone: this.tone })
        Column() {
          Text(this.title).fontSize(16).fontColor($r('app.color.hb_text')).fontWeight(FontWeight.Medium)
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(13)
              .fontColor($r('app.color.hb_text2'))
              .margin({ top: 2 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12, right: 8 })

        if (this.chip.length > 0) {
          Chip({ text: this.chip, tone: this.chipTone })
        }
        if (this.showArrow) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([$r('app.color.hb_text3')])
            .margin({ left: 6 })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: 14, bottom: 14 })

      if (this.showDivider) {
        Divider().color($r('app.color.hb_divider')).margin({ left: 64 })
      }
    }
    .onClick(() => this.onTap())
  }
}

/** 开关行 */
@Component
export struct SwitchRow {
  title: string = '';
  @Prop subtitle: string = '';
  @Prop isOn: boolean = false;
  showDivider: boolean = true;
  onToggle: (on: boolean) => void = () => {
  };

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.title).fontSize(16).fontColor($r('app.color.hb_text'))
          if (this.subtitle.length > 0) {
            Text(this.subtitle).fontSize(13).fontColor($r('app.color.hb_text2')).margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.isOn })
          .selectedColor($r('app.color.hb_accent'))
          .onChange((on: boolean) => this.onToggle(on))
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 12, bottom: 12 })

      if (this.showDivider) {
        Divider().color($r('app.color.hb_divider')).margin({ left: 16 })
      }
    }
  }
}

/** 页面顶部的返回栏 */
@Component
export struct PageHeader {
  title: string = '';
  showBack: boolean = true;

  build() {
    Row() {
      if (this.showBack) {
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([$r('app.color.hb_text')])
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor($r('app.color.hb_card'))
        .systemMaterial(GLASS_THIN)
        .onClick(() => this.getUIContext().getRouter().back())
      }
      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.hb_text'))
        .margin({ left: this.showBack ? 12 : 4 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }
}

/** 主按钮 */
@Component
export struct PrimaryButton {
  @Prop label: string = '';
  @Prop enabledState: boolean = true;
  onTap: () => void = () => {
  };

  build() {
    Button(this.label)
      .width('100%')
      .height(48)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .backgroundColor(this.enabledState ? $r('app.color.hb_accent') : $r('app.color.hb_text3'))
      .enabled(this.enabledState)
      .onClick(() => this.onTap())
  }
}

/** 次按钮 */
@Component
export struct SecondaryButton {
  @Prop label: string = '';
  onTap: () => void = () => {
  };

  build() {
    Button(this.label)
      .width('100%')
      .height(44)
      .fontSize(15)
      .fontColor($r('app.color.hb_accent'))
      .backgroundColor($r('app.color.hb_accent_soft'))
      .onClick(() => this.onTap())
  }
}

/** 数字统计卡片 */
@Component
export struct StatTile {
  @Prop value: string = '';
  label: string = '';

  build() {
    Column() {
      Text(this.value).fontSize(26).fontWeight(FontWeight.Bold).fontColor($r('app.color.hb_text'))
      Text(this.label).fontSize(13).fontColor($r('app.color.hb_text2')).margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.hb_card'))
    .borderRadius(20)
    .systemMaterial(GLASS)
  }
}

/** 用于页面根节点：.background(auroraBackground) */
@Builder
export function auroraBackground() {
  AuroraBackground()
}

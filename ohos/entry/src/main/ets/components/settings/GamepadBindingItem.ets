import { uiMaterial } from '@kit.ArkUI';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { ThemeManager } from '../../utils/ThemeManager';
import { immersiveMaterial } from '../common/AzaharControls';
import {
  BUTTON_BG_SECONDARY, BUTTON_ICON_SM, FONT_SIZE_SETTING_DESC, FONT_SIZE_SETTING_TITLE,
  ICON_SIZE_ROW, SETTING_ITEM_PADDING, TEXT_PRIMARY, TEXT_SECONDARY
} from '../../types/UIConstants';

/**
 * 手柄绑定行：标题 + 当前绑定键名（icon 非空时带来源图标）+ 行尾删除键（deletable 时显示）。
 * 点击行进入捕获态，点删除键清除绑定——与映射 tab 绑定条目的交互一致。
 */
@Component
export struct GamepadBindingItem {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop value: string = '';
  @Prop icon: Resource | null = null;
  @Prop listening: boolean = false;
  @Prop listeningText: string = '';
  @Prop deletable: boolean = false;
  onSelect: () => void = () => {};
  onClear: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Column() {
        Text(this.title)
          .fontSize(FONT_SIZE_SETTING_TITLE)
          .fontColor(TEXT_PRIMARY)
          .fontWeight(FontWeight.Medium)
        if (this.description.length > 0) {
          Text(this.description)
            .fontSize(FONT_SIZE_SETTING_DESC)
            .fontColor(TEXT_SECONDARY)
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 绑定来源图标（手柄/键盘），与映射 tab 绑定条目同款规格
      if (this.icon !== null && !this.listening) {
        SymbolGlyph(this.icon)
          .fontSize(ICON_SIZE_ROW)
          .fontColor([TEXT_SECONDARY])
      }

      // 绑定值是用户配置 → 正文色；"未绑定"是占位提示 → 次级色（与映射行一致）
      Text(this.listening ? this.listeningText : this.value)
        .fontSize(FONT_SIZE_SETTING_DESC)
        .fontColor(this.listening ? ThemeManager.getInstance().getControlAccent() :
          this.deletable ? TEXT_PRIMARY : TEXT_SECONDARY)

      if (this.deletable) {
        // 与映射 tab 绑定条目同款：圆形次级底按钮 + 警示色图标
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(BUTTON_ICON_SM)
            .fontColor([TEXT_SECONDARY])
        }
        .width(32)
        .height(32)
        .buttonStyle(ButtonStyleMode.NORMAL)
        .backgroundColor(BUTTON_BG_SECONDARY)
        .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
          this.onClear();
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 与卡片内其他设置项同一行高标准（SETTING_ITEM_PADDING = ComposeListItem 规格）
    .padding(SETTING_ITEM_PADDING)
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
      this.onSelect();
    })
  }
}

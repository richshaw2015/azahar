import {
  FONT_SIZE_MIN,
  FONT_SIZE_SETTING_DESC,
  FONT_SIZE_SETTING_TITLE,
  INPUT_BORDER_RADIUS,
  INPUT_FONT_SIZE,
  INPUT_HEIGHT,
  INPUT_PADDING_H,
  OPACITY_DISABLED,
  SETTING_ITEM_PADDING,
  TEXT_DISABLED,
  TEXT_PRIMARY,
  TEXT_SECONDARY,
  TEXT_WARNING
} from '../../types/UIConstants';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { inputBgOf } from '../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../utils/ThemeManager';
import { AzaharThemeColors } from '../../types/ThemeTypes';

@Component
export struct TextInputSettingItem {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop value: string = '';
  @Prop placeholder: string = '';
  @Prop maxLength: number = 100;
  @Prop disabled: boolean = false;
  @Prop requiresRestart: boolean = false;
  @Prop showCounter: boolean = true;
  onChange: (value: string) => void = () => {};

  build() {
    Column() {
      // 无标题时整行不渲染（含右侧字数计数器），弹窗场景可用纯输入框
      if (this.title.length > 0) {
        Row() {
          Text(this.title)
            .fontSize(FONT_SIZE_SETTING_TITLE)
            .fontColor(this.disabled ? TEXT_DISABLED : TEXT_PRIMARY)
            .fontWeight(FontWeight.Medium)

          if (this.requiresRestart) {
            Text('*')
              .fontSize(FONT_SIZE_SETTING_DESC)
              .fontColor(TEXT_WARNING)
              .margin({ left: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
          }

          Blank()

          if (this.showCounter) {
            Text(`${this.value.length}/${this.maxLength}`)
              .fontSize(FONT_SIZE_MIN)
              .fontColor(TEXT_SECONDARY)
          }
        }
        .width('100%')
      }

      if (this.description.length > 0) {
        Text(this.description)
          .fontSize(FONT_SIZE_SETTING_DESC)
          .fontColor(TEXT_SECONDARY)
          .margin({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
          .width('100%')
      }

      TextInput({ text: this.value, placeholder: this.placeholder })
        .fontSize(INPUT_FONT_SIZE)
        .fontColor(TEXT_PRIMARY)
        .placeholderColor(TEXT_DISABLED)
        .placeholderFont({ size: INPUT_FONT_SIZE })
        .maxLength(this.maxLength)
        .enabled(!this.disabled)
        .margin({ top: this.title.length > 0 || this.description.length > 0
          ? $r('sys.float.ohos_id_elements_margin_vertical_m') : 0 })
        .width('100%')
        .height(INPUT_HEIGHT)
        .backgroundColor(inputBgOf(this.themeColors))
        .borderRadius(INPUT_BORDER_RADIUS)
        .padding({ left: INPUT_PADDING_H, right: INPUT_PADDING_H })
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onChange((value: string) => {
          this.onChange(value);
        })
    }
    .width('100%')
    .padding(SETTING_ITEM_PADDING)
    .alignItems(HorizontalAlign.Start)
    .opacity(this.disabled ? OPACITY_DISABLED : 1.0)
  }
}

import {
  FONT_SIZE_SETTING_DESC,
  FONT_SIZE_SETTING_TITLE,
  OPACITY_DISABLED,
  SETTING_ITEM_PADDING,
  SURFACE_TRACK,
  TEXT_DISABLED,
  TEXT_PRIMARY,
  TEXT_SECONDARY,
  TEXT_WARNING
} from '../../types/UIConstants';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { controlAccentOf, immersiveMaterial } from '../common/AzaharControls';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { THEME_COLORS_STORAGE_KEY, ThemeManager } from '../../utils/ThemeManager';
import { AzaharThemeColors } from '../../types/ThemeTypes';

@Component
export struct SliderSettingItem {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop @Watch('onValuePropChange') value: number = 0;
  @Prop min: number = 0;
  @Prop max: number = 100;
  @Prop step: number = 1;
  @Prop disabled: boolean = false;
  @Prop continuous: boolean = true;
  @Prop requiresRestart: boolean = false;
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  formatValue: (value: number) => string = (value: number) => value.toString();
  onChange: (value: number) => void = () => {};

  @State private sliderValue: number = 0;

  aboutToAppear(): void {
    this.sliderValue = this.value;
  }

  private onValuePropChange(): void {
    this.sliderValue = this.value;
  }

  build() {
    Column() {
      Row() {
        Column() {
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
          }
          .width('100%')

          if (this.description.length > 0) {
            Text(this.description)
              .fontSize(FONT_SIZE_SETTING_DESC)
              .fontColor(TEXT_SECONDARY)
              .margin({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.formatValue(this.sliderValue))
          .fontSize(FONT_SIZE_SETTING_DESC)
          .fontColor(TEXT_SECONDARY)
          .fontWeight(FontWeight.Medium)
          .margin({ left: $r('sys.float.ohos_id_card_margin_middle') })
      }
      .width('100%')

      Slider({
        value: this.sliderValue,
        min: this.min,
        max: this.max,
        step: this.step,
        style: SliderStyle.InSet
      })
        .trackColor(SURFACE_TRACK)
        .selectedColor(controlAccentOf(this.themeColors))
        .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
        .showSteps(false)
        .showTips(false)
        .enabled(!this.disabled)
        .margin({ top: $r('sys.float.ohos_id_elements_margin_vertical_m') })
        .onChange((value: number, mode: SliderChangeMode) => {
          const rounded = Number((Math.round(value / this.step) * this.step).toFixed(6));
          this.sliderValue = rounded;
          if (mode === SliderChangeMode.End) {
            SoundEffectManager.getInstance().play(SoundEffect.SELECT);
          }
          if (mode === SliderChangeMode.End || (this.continuous && mode === SliderChangeMode.Moving)) {
            this.onChange(rounded);
          }
        })
    }
    .width('100%')
    .padding(SETTING_ITEM_PADDING)
    .alignItems(HorizontalAlign.Start)
    .opacity(this.disabled ? OPACITY_DISABLED : 1.0)
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
  }
}

import { ComposeListItem } from '@kit.ArkUI';
import { AzaharThemeColors } from '../../types/ThemeTypes';
import { OPACITY_DISABLED } from '../../types/UIConstants';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { controlThemeOf } from '../common/AzaharControls';
import { THEME_COLORS_STORAGE_KEY, ThemeManager } from '../../utils/ThemeManager';

@Component
export struct ToggleSettingItem {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop isOn: boolean = false;
  @Prop disabled: boolean = false;
  @Prop requiresRestart: boolean = false;
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  onToggle: (value: boolean) => void = () => {};

  build() {
    WithTheme({ theme: controlThemeOf(this.themeColors) }) {
      ComposeListItem({
      contentItem: {
        primaryText: this.requiresRestart ? `${this.title} *` : this.title,
        secondaryText: this.description.length > 0 ? this.description : undefined
      },
      operateItem: {
        switch: {
          isCheck: this.isOn,
          onChange: (isOn: boolean) => {
            SoundEffectManager.getInstance().play(isOn ? SoundEffect.TOGGLE_ON : SoundEffect.TOGGLE_OFF);
            this.onToggle(isOn);
          }
        }
      }
      })
        .enabled(!this.disabled)
        .opacity(this.disabled ? OPACITY_DISABLED : 1.0)
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
    }
  }
}

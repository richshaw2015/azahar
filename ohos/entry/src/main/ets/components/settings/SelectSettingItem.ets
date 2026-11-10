import { ComposeListItem, SymbolGlyphModifier } from '@kit.ArkUI';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { controlAccentOf, immersiveMaterial } from '../common/AzaharControls';
import { SettingOption } from '../../types/SettingsTypes';
import { AzaharThemeColors } from '../../types/ThemeTypes';
import { OPACITY_DISABLED, MENU_ITEM_DIVIDER } from '../../types/UIConstants';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { THEME_COLORS_STORAGE_KEY, ThemeManager } from '../../utils/ThemeManager';

/**
 * 单选设置行：系统设置同款「值 + 箭头」行 + bindMenu 对号下拉。
 * 不使用 SelectDialog——其勾选项颜色不可着色（组件私有资源），
 * MenuItem.selectIcon 才能跟随主题强调色。
 */
@Component
export struct SelectSettingItem {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop options: SettingOption[] = [];
  @Prop selectedIndex: number = 0;
  @Prop disabled: boolean = false;
  @Prop requiresRestart: boolean = false;
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  onSelect: (index: number, value: string | number) => void = () => {};

  private getSelectedLabel(): string {
    if (this.selectedIndex >= 0 && this.selectedIndex < this.options.length) {
      return this.options[this.selectedIndex].label;
    }
    return '';
  }

  @Builder
  OptionMenu() {
    Menu() {
      ForEach(this.options, (option: SettingOption, index: number) => {
        MenuItemGroup() {
          MenuItem({ content: option.label })
            .selected(index === this.selectedIndex)
            .selectIcon(new SymbolGlyphModifier($r('sys.symbol.checkmark'))
              .fontColor([controlAccentOf(this.themeColors)]))
            .onClick(() => {
              SoundEffectManager.getInstance().play(SoundEffect.SELECT);
              this.onSelect(index, option.value);
            })
        }
      })
    }
    .menuItemDivider(MENU_ITEM_DIVIDER)
    .menuItemGroupDivider(MENU_ITEM_DIVIDER)
  }

  build() {
    ComposeListItem({
      contentItem: {
        primaryText: this.requiresRestart ? `${this.title} *` : this.title,
        secondaryText: this.description.length > 0 ? this.description : undefined
      },
      operateItem: {
        text: this.getSelectedLabel(),
        arrow: {
          value: $r('sys.symbol.arrowtriangle_down_fill')
        }
      }
    })
    .enabled(!this.disabled)
    .opacity(this.disabled ? OPACITY_DISABLED : 1.0)
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      if (!this.disabled && this.options.length > 0) {
        SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
      }
    })
    .bindMenu(this.OptionMenu(), {
      placement: Placement.BottomRight,
      systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
    })
  }
}

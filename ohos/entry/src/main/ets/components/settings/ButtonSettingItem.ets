import { ComposeListItem } from '@kit.ArkUI';
import { OPACITY_DISABLED, TITLE_BAR_ICON_COLOR } from '../../types/UIConstants';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';

@Component
export struct ButtonSettingItem {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop buttonText: string = '';
  @Prop disabled: boolean = false;
  @Prop showArrow: boolean = true;
  @Prop leadingIcon: string = '';
  @Prop leadingIconColor: ResourceColor = TITLE_BAR_ICON_COLOR;
  onItemClick: () => void = () => {};

  build() {
    ComposeListItem({
      contentItem: {
        primaryText: this.title,
        secondaryText: this.description.length > 0 ? this.description : undefined
      },
      operateItem: {
        text: this.buttonText.length > 0 ? this.buttonText : undefined,
        arrow: this.showArrow ? {
          value: $r('sys.symbol.chevron_right'),
          action: () => {
            this.handleClick();
          }
        } : undefined
      }
    })
    .enabled(!this.disabled)
    .opacity(this.disabled ? OPACITY_DISABLED : 1.0)
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      this.handleClick();
    })
  }

  private handleClick(): void {
    if (!this.disabled) {
      SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
      this.onItemClick();
    }
  }
}

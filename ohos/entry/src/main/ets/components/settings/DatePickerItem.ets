import { ComposeListItem } from '@kit.ArkUI';
import { OPACITY_DISABLED } from '../../types/UIConstants';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { ThemeManager } from '../../utils/ThemeManager';

/**
 * 生日月/日设置行：点击弹出系统 DatePickerDialog 的 MONTH_AND_DAY 双列滚轮。
 * 年份固定为闰年（2000），保证 2 月 29 日可选。
 */
@Component
export struct DatePickerItem {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop month: number = 1;
  @Prop day: number = 1;
  @Prop disabled: boolean = false;
  @Prop requiresRestart: boolean = false;

  onSelect: (month: number, day: number) => void = () => {};

  private formatDate(month: number, day: number): string {
    return I18n.tf2('date_month_day_fmt', 'month', month, 'day', day);
  }

  private openPicker(): void {
    const accent: string = ThemeManager.getInstance().getControlAccent();
    this.getUIContext().showDatePickerDialog({
      mode: DatePickerMode.MONTH_AND_DAY,
      selected: new Date(2000, this.month - 1, this.day),
      selectedTextStyle: { color: accent },
      acceptButtonStyle: { fontColor: accent },
      onDateAccept: (value: Date) => {
        this.onSelect(value.getMonth() + 1, value.getDate());
      }
    });
  }

  build() {
    ComposeListItem({
      contentItem: {
        primaryText: this.requiresRestart ? `${this.title} *` : this.title,
        secondaryText: this.description.length > 0 ? this.description : undefined
      },
      operateItem: {
        text: this.formatDate(this.month, this.day),
        arrow: {
          value: $r('sys.symbol.chevron_right')
        }
      }
    })
    .opacity(this.disabled ? OPACITY_DISABLED : 1.0)
    .enabled(!this.disabled)
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      if (this.disabled) {
        return;
      }
      SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
      this.openPicker();
    })
  }
}

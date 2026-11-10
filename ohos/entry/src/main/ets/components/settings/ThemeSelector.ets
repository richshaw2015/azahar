import { AzaharTheme, AzaharThemeColors } from '../../types/ThemeTypes';
import {
  CARD_BORDER_COLOR,
  FONT_SIZE_SETTING_DESC,
  TEXT_ON_ACCENT,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { ThemeManager } from '../../utils/ThemeManager';

const SWATCH_SIZE: number = 32;
const SWATCH_RING_SIZE: number = 40;
const SWATCH_RING_WIDTH: number = 3;
const ITEM_WIDTH: number = 48;

function normalizeHex(hex: string): string {
  const raw = hex.startsWith('#') ? hex.slice(1) : hex;
  if (raw.length === 3) {
    return raw.split('').map((ch: string) => `${ch}${ch}`).join('');
  }
  return raw.padEnd(6, '0').slice(0, 6);
}

@Component
export struct ThemeSelector {
  @Prop selectedThemeId: string = '';
  onThemeChange: (themeId: string) => void = () => {};

  private themes: AzaharTheme[] = ThemeManager.getInstance().getAllThemes();

  private isSwatchDark(colors: AzaharThemeColors): boolean {
    const normalized = normalizeHex(colors.primary);
    const r = parseInt(normalized.slice(0, 2), 16);
    const g = parseInt(normalized.slice(2, 4), 16);
    const b = parseInt(normalized.slice(4, 6), 16);
    return (r * 0.299 + g * 0.587 + b * 0.114) < 110;
  }

  build() {
    Column() {
      Scroll() {
        Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_l') }) {
          ForEach(this.themes, (theme: AzaharTheme) => {
            this.ThemeSwatch(theme)
          }, (theme: AzaharTheme) => theme.id)
        }
        .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end') })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .width('100%')
      // 底部间距对齐行内边距档位：色卡名与下方卡片分隔线之间留出呼吸间距
      .padding({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs'), bottom: $r('sys.float.ohos_id_elements_margin_vertical_l') })
    }
    .width('100%')
  }

  @Builder
  private ThemeSwatch(theme: AzaharTheme) {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
      Stack() {
        // 主题色圆
        Column()
          .width(SWATCH_SIZE)
          .height(SWATCH_SIZE)
          .backgroundColor(theme.colors.primary)
          .borderRadius(SWATCH_SIZE / 2)
          .border({ width: '1px', color: CARD_BORDER_COLOR })

        // 选中：主题色描边环
        if (this.selectedThemeId === theme.id) {
          Column()
            .width(SWATCH_RING_SIZE)
            .height(SWATCH_RING_SIZE)
            .borderRadius(SWATCH_RING_SIZE / 2)
            .border({ width: SWATCH_RING_WIDTH, color: theme.colors.primary })

          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(SWATCH_SIZE * 0.5)
            .fontColor(this.isSwatchDark(theme.colors) ? [TEXT_ON_ACCENT] : [TEXT_PRIMARY])
        }
      }
      .width(SWATCH_RING_SIZE)
      .height(SWATCH_RING_SIZE)
      .animation({ duration: 220, curve: Curve.EaseOut })

      Text(I18n.t(theme.nameKey))
        .fontSize(FONT_SIZE_SETTING_DESC)
        .fontColor(this.selectedThemeId === theme.id ? TEXT_PRIMARY : TEXT_SECONDARY)
        .fontWeight(this.selectedThemeId === theme.id ? FontWeight.Medium : FontWeight.Normal)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(ITEM_WIDTH)
    .focusable(true)
    .focusOnTouch(true)
    .useEffect(true)
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      if (this.selectedThemeId !== theme.id) {
        SoundEffectManager.getInstance().play(SoundEffect.SELECT);
        this.selectedThemeId = theme.id;
        this.onThemeChange(theme.id);
      }
    })
  }
}

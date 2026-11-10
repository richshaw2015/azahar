import uiMaterial from '@ohos.arkui.uiMaterial';
import { SCREEN_FILTER_NONE_VALUE, ScreenFilterItem, persistScreenFilter } from '../../types/ScreenFilterDefs';
import { SHEET_CARD_BG } from '../../types/UIConstants';
import { AzaharThemeColors } from '../../types/ThemeTypes';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { listCardBgOf, selectedCardBgOf } from '../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../utils/ThemeManager';
import { immersiveMaterial } from './AzaharControls';

// 预览图统一为源资源 8:7 画幅（rawfile/filter_previews 内置素材）
export const PREVIEW_ASPECT: number = 8 / 7;
/** 卡片在预览图之外的固定高度（图名间距8 + 名称行24 + 上下 padding 16），用于滚动定位估算 */
export const CARD_EXTRA_H: number = 48;
const FILTER_LABEL_ROW_HEIGHT: number = 24;

// 卡片必须做成 @Component 而非按值传参的 @Builder —— @Builder 的参数与内部
// 状态读取在二次进入/状态变化时不保证刷新（见 ohos AGENTS 规范）。
// 图形设置页滤镜网格与游戏内暂停菜单"屏幕滤镜"段共用。
@Component
export struct ScreenFilterCard {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  @StorageLink('screen_filter_selection') screenFilter: string = SCREEN_FILTER_NONE_VALUE;
  @Prop item: ScreenFilterItem;
  /** 面板内模式（暂停菜单等弹层面）：中性底 SHEET_CARD_BG + ULTRA_THIN 材质，
   *  不做主题着色（AGENTS 弹层面规范），选中态仅靠描边+对号区分 */
  @Prop neutral: boolean = false;

  private isSelected(): boolean {
    return this.item.value === this.screenFilter;
  }

  private cardBg(): ResourceColor {
    if (this.neutral) {
      return SHEET_CARD_BG;
    }
    return this.isSelected() ? selectedCardBgOf(this.themeColors) : listCardBgOf(this.themeColors);
  }

  private selectionColor(): string {
    return ThemeManager.getInstance().getControlAccent();
  }

  private select(): void {
    SoundEffectManager.getInstance().play(SoundEffect.SELECT);
    if (this.screenFilter === this.item.value) {
      return;
    }
    this.screenFilter = this.item.value;
    persistScreenFilter(this.item.value);
  }

  build() {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
      Image($rawfile(`filter_previews/${this.item.preview}.webp`))
        .width('100%')
        .aspectRatio(PREVIEW_ASPECT)
        .objectFit(ImageFit.Contain)
        .borderRadius($r('sys.float.ohos_id_corner_radius_default_xs'))
        .draggable(false)

      Row() {
        Text(this.item.label)
          .fontSize($r('sys.float.ohos_id_text_size_body2'))
          .fontColor(this.isSelected()
            ? $r('sys.color.ohos_id_color_text_primary')
            : $r('sys.color.ohos_id_color_text_secondary'))
          .fontWeight(this.isSelected() ? FontWeight.Medium : FontWeight.Regular)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Start)
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(20)
          .fontColor([this.selectionColor()])
          .opacity(this.isSelected() ? 1 : 0)
      }
        .width('100%')
        .height(FILTER_LABEL_ROW_HEIGHT)
        .alignItems(VerticalAlign.Center)
        .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_s'), right: $r('sys.float.ohos_id_elements_margin_horizontal_s') })
    }
    .alignItems(HorizontalAlign.Center)
    .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_m'), right: $r('sys.float.ohos_id_elements_margin_horizontal_m'), top: $r('sys.float.ohos_id_elements_margin_vertical_m'), bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })
    .backgroundColor(this.cardBg())
    .systemMaterial(this.neutral ? immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN) : undefined)
    .outline({
      width: this.isSelected() ? 2 : 0,
      color: this.selectionColor(),
      radius: $r('sys.float.ohos_id_corner_radius_card')
    })
    .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
    .useEffect(true)
    .onClick(() => {
      this.select();
    })
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
  }
}

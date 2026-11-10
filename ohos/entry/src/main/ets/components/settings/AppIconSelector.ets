/**
 * AppIconSelector - 应用图标样式选择器
 *
 * 展示全部可选的桌面图标样式（同一背景 + 不同前景图），点击切换。
 * - 仅在系统支持 alternateIcons（API 26+）时由父组件渲染。
 * - 选中态为主题强调色描边，与 ThemeSelector 的选中表现一致。
 */

import { controlAccentOf } from '../common/AzaharControls';
import { AzaharThemeColors } from '../../types/ThemeTypes';
import {
  FONT_SIZE_SETTING_DESC,
  FONT_SIZE_SETTING_TITLE,
  SETTING_ITEM_PADDING,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';
import { AppIconView } from '../AppIconView';
import { AppIconManager, APP_ICON_STYLES, AppIconStyle } from '../../utils/AppIconManager';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { THEME_COLORS_STORAGE_KEY, ThemeManager } from '../../utils/ThemeManager';
import { showErrorToast } from '../../utils/ToastHelper';

const TAG = 'Azahar_AppIconSelector';

/** 图标预览尺寸（vp） */
const ICON_PREVIEW_SIZE: number = 80;
/** 选中描边宽度，与 ThemeSelector 的 SWATCH_RING_WIDTH 一致 */
const SELECTED_RING_WIDTH: number = 2;
/** 预览项宽度 */
const ITEM_WIDTH: number = 88;
/** 选中描边谷底不透明度：仍保持常显，只是暗一些 */
const BORDER_MIN_OPACITY: number = 0.7;
/** 呼吸半周期时长 */
const BORDER_HALF_CYCLE_MS: number = 1200;

/**
 * 选中态描边：位置、宽度、圆角与原静态描边完全一致，仅透明度在
 * BORDER_MIN_OPACITY~1 之间缓慢起伏，视觉上仍是那一圈边框、只是轻微明暗变化。
 * 独立成组件：onDidBuild 翻转一次 lit，配合 iterations:-1 + Alternate 无限呼吸；
 * 取消选中时节点随 if 分支销毁，动画自动停止。
 */
@Component
struct SelectedIconBorder {
  @Prop diameter: number = 0;
  @Prop ringColor: string = '';
  @State private lit: boolean = false;

  onDidBuild(): void {
    this.lit = true;
  }

  build() {
    Column()
      .width(this.diameter)
      .aspectRatio(1)
      .borderRadius(Math.round(this.diameter * 0.24))
      .border({ width: SELECTED_RING_WIDTH, color: this.ringColor })
      .opacity(this.lit ? 1 : BORDER_MIN_OPACITY)
      .animation({
        duration: BORDER_HALF_CYCLE_MS,
        curve: Curve.EaseInOut,
        iterations: -1,
        playMode: PlayMode.Alternate
      })
  }
}

@Component
export struct AppIconSelector {
  @State private selectedAlternate: string = '';
  @State private applying: boolean = false;
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();

  private appIconManager: AppIconManager = AppIconManager.getInstance();

  aboutToAppear(): void {
    this.appIconManager.getCurrentStyle().then((name: string) => {
      this.selectedAlternate = name;
    }).catch((err: Error) => {
      console.warn(`[${TAG}] Failed to load current icon style: ${err.message}`);
    });
  }

  private isSelected(style: AppIconStyle): boolean {
    return this.selectedAlternate === style.alternateName;
  }

  private async onStyleTap(style: AppIconStyle): Promise<void> {
    if (this.applying || this.isSelected(style)) {
      return;
    }
    SoundEffectManager.getInstance().play(SoundEffect.SELECT);
    this.applying = true;
    const prev = this.selectedAlternate;
    this.selectedAlternate = style.alternateName;
    const ok = await this.appIconManager.applyStyle(style.alternateName);
    this.applying = false;
    if (!ok) {
      this.selectedAlternate = prev;
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('app_icon_change_failed'));
    }
  }

  @Builder
  IconPreview(style: AppIconStyle) {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
      Stack() {
        AppIconView({ iconSize: ICON_PREVIEW_SIZE, pinnedStyle: style })
          // 0.24 是系统应用图标遮罩的圆角比例
          .borderRadius(Math.round(ICON_PREVIEW_SIZE * 0.24))
          .shadow({
            radius: this.isSelected(style) ? 8 : 0,
            color: this.isSelected(style) ? controlAccentOf(this.themeColors) : Color.Transparent,
            offsetX: 0,
            offsetY: 2
          })
          .animation({ duration: 250, curve: Curve.EaseOut })

        if (this.isSelected(style)) {
          SelectedIconBorder({
            diameter: ICON_PREVIEW_SIZE,
            ringColor: controlAccentOf(this.themeColors)
          })
        }
      }

      Text(I18n.t(style.nameKey))
        .fontSize(FONT_SIZE_SETTING_DESC)
        .fontColor(this.isSelected(style) ? TEXT_PRIMARY : TEXT_SECONDARY)
        .fontWeight(this.isSelected(style) ? FontWeight.Medium : FontWeight.Normal)
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
      this.onStyleTap(style);
    })
  }

  build() {
    Column() {
      // 标题行
      Row() {
        Text(I18n.t('app_icon'))
          .fontSize(FONT_SIZE_SETTING_TITLE)
          .fontColor(TEXT_PRIMARY)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({
        left: SETTING_ITEM_PADDING.left,
        right: SETTING_ITEM_PADDING.right,
        top: SETTING_ITEM_PADDING.top
      })

      // 样式预览：四个图标横向排列，超出时可左右滑动
      Scroll() {
        Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
          ForEach(APP_ICON_STYLES, (style: AppIconStyle) => {
            this.IconPreview(style)
          }, (style: AppIconStyle) => style.alternateName || 'default')
        }
        .justifyContent(FlexAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      // 预览项超出时边缘自然截断，已能提示可滑动，不再显示滚动条
      .scrollBar(BarState.Off)
      .width('100%')
      .padding({ top: $r('sys.float.ohos_id_default_padding_top'), bottom: SETTING_ITEM_PADDING.bottom })
    }
    .width('100%')
  }
}

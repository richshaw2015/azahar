import { ColorMetrics, TabSegmentButtonV2, SegmentButtonV2Items, router } from '@kit.ArkUI';
import { showErrorToast } from '../../utils/ToastHelper';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { controlAccentOf, immersiveMaterial } from '../common/AzaharControls';
import { AppIconView } from '../AppIconView';
import { AzaharThemeColors } from '../../types/ThemeTypes';
import { normalizeHomeTab } from '../../types/HomeTab';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { FONT_SIZE_PAGE_TITLE, INPUT_PADDING_H, RADIUS_FULL, SEGMENT_BUTTON_MIN_HEIGHT, SEGMENT_ITEM_MIN_HEIGHT, SEGMENT_ITEM_PADDING, SEGMENT_SYMBOL_FONT_SIZE, TEXT_DISABLED, TEXT_PRIMARY, TITLE_BAR_ICON_COLOR, titleBarButtonAvoidVp, titleBarEdgeInsetVp } from '../../types/UIConstants';
import { inputBgOf, secondaryButtonBgOf } from '../../utils/ThemeSurfaces';

/** 首页标题区控件：标题栏单元格 / 主标题 / 搜索框 / 分段栏 */
@Component
export struct HomeTitleControls {
  @Prop themeColors: AzaharThemeColors;
  @Prop searchQuery: string = '';
  @Link currentTabIndex: number;
  @Prop allVisibleCount: number = 0;
  @Prop recentVisibleCount: number = 0;
  @Prop favoritesVisibleCount: number = 0;
  soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  setSearchQuery: (value: string) => void = () => {};
  @Prop part: 'title' | 'search' | 'segment' = 'title';
  // 页面宽度（vp）：搜索态避让返回键需按 HDS 标题栏内间距分档计算
  @Prop titleBarWidthVp: number = 0;

  @Builder
  TitleBarCell(icon: Resource, color: ResourceColor, marginRight: number, onClick: () => void) {
    Button() {
      SymbolGlyph(icon)
        .fontSize($r('sys.float.ohos_id_search_close_icon_size'))
        .fontColor([color])
    }
    .type(ButtonType.Circle)
    .width($r('sys.float.sheet_close_icon_button_width'))
    .height($r('sys.float.sheet_close_icon_button_width'))
    .backgroundColor(secondaryButtonBgOf(this.themeColors))
    .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN, true))
    .margin({ right: marginRight })
    .onClick(onClick)
  }

  @Builder
  HomeTitleBuilder() {
    Row() {
      // 热区只覆盖 logo + 应用名，不把整条标题栏空白都变成可点
      Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
        AppIconView({ iconSize: 48, withBackground: false })
        Text($r('app.string.app_name'))
          .fontSize(FONT_SIZE_PAGE_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .useEffect(true)
      .onClick(() => {
        this.soundEffectManager.play(SoundEffect.DECIDE);
        router.pushUrl({ url: 'pages/settings/AboutSettings' }).catch((error: Error) => {
          showErrorToast(I18n.tf1('open_failed_fmt', 'error', error.message));
        });
      })
    }
    .width('100%')
    .height('100%')
    .padding({
      left: titleBarEdgeInsetVp(this.titleBarWidthVp, 'start'),
      right: titleBarEdgeInsetVp(this.titleBarWidthVp, 'end')
    })
  }

  @Builder
  SearchFieldBuilder() {
    Row() {
      TextInput({ placeholder: I18n.t('search_games_files_categories'), text: this.searchQuery })
        .height($r('sys.float.ohos_id_textfield_height'))
        .layoutWeight(1)
        .fontSize($r('sys.float.ohos_id_text_size_body2'))
        .fontColor(TEXT_PRIMARY)
        .placeholderColor(TEXT_DISABLED)
        .caretColor(controlAccentOf(this.themeColors))
        .backgroundColor(inputBgOf(this.themeColors))
        .borderRadius(RADIUS_FULL)
        .padding({ left: INPUT_PADDING_H, right: INPUT_PADDING_H })
        .margin({ right: this.searchQuery.length > 0 ? $r('sys.float.ohos_id_elements_margin_horizontal_m') : 0 })
        .onFocus(() => {
          this.soundEffectManager.play(SoundEffect.FOCUS);
        })
        .onChange((value: string) => {
          this.setSearchQuery(value);
        })
        .defaultFocus(true)
        .id('searchInput')
        .onAppear(() => {
          focusControl.requestFocus('searchInput');
        })

      if (this.searchQuery.length > 0) {
        this.TitleBarCell($r('sys.symbol.xmark'), TITLE_BAR_ICON_COLOR, 0, () => {
          this.soundEffectManager.play(SoundEffect.BACK);
          this.setSearchQuery('');
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({
      left: titleBarButtonAvoidVp(this.titleBarWidthVp, 'start'),
      right: titleBarEdgeInsetVp(this.titleBarWidthVp, 'end')
    })
  }

  @Builder
  HomeSegmentBar() {
    Row() {
      TabSegmentButtonV2({
        items: new SegmentButtonV2Items([
          { text: `${I18n.t('recent')} ${this.recentVisibleCount}`, symbol: $r('sys.symbol.clock') },
          { text: `${I18n.t('favorites')} ${this.favoritesVisibleCount}`, symbol: $r('sys.symbol.star_fill') },
          { text: `${I18n.t('all')} ${this.allVisibleCount}`, symbol: $r('sys.symbol.gamecontroller') }
        ]),
        selectedIndex: this.currentTabIndex,
        itemMinHeight: SEGMENT_ITEM_MIN_HEIGHT,
        itemPadding: SEGMENT_ITEM_PADDING,
        buttonMinHeight: SEGMENT_BUTTON_MIN_HEIGHT,
        itemSymbolFontSize: SEGMENT_SYMBOL_FONT_SIZE,
        backgroundSystemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true),
        itemSelectedFontColor: ColorMetrics.resourceColor(controlAccentOf(this.themeColors)),
        itemSelectedSymbolFontColor: ColorMetrics.resourceColor(controlAccentOf(this.themeColors)),
        itemSelectedBackgroundColor: ColorMetrics.resourceColor($r('sys.color.ohos_id_color_button_normal')),
        enableStateAnimation: true,
        onItemClicked: (index: number) => {
          if (index !== this.currentTabIndex) {
            this.soundEffectManager.play(SoundEffect.SELECT);
          }
          this.currentTabIndex = normalizeHomeTab(index);
        }
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end') })
  }

  build() {
    if (this.part === 'search') {
      this.SearchFieldBuilder()
    } else if (this.part === 'segment') {
      this.HomeSegmentBar()
    } else {
      this.HomeTitleBuilder()
    }
  }
}

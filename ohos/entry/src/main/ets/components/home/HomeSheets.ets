
import uiMaterial from '@ohos.arkui.uiMaterial';
import { controlThemeOf, immersiveMaterial } from '../common/AzaharControls';
import { AzaharWebUploadPanel } from '../web/AzaharWebUploadPanel';
import { AzaharHowToGetGamesPanel } from '../help/AzaharHowToGetGamesPanel';
import { SegmentOptionRow } from '../common/OptionMenuControls';
import { ThemeSelector } from '../settings/ThemeSelector';
import { AzaharThemeColors } from '../../types/ThemeTypes';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import {
  BUTTON_BG_SECONDARY,
  COVER_RADIUS_MAX,
  FONT_SIZE_SETTING_DESC,
  FONT_SIZE_SETTING_TITLE,
  GRID_COVER_BASE,
  GRID_COVER_SIZE_MAX,
  GRID_COVER_SIZE_MIN,
  LIST_COVER_BASE,
  LIST_COVER_SIZE_MAX,
  LIST_COVER_SIZE_MIN,
  RADIUS_SHEET,
  SHEET_BG_GROUPED,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';

/** 首页底部面板组：显示选项 / 网页上传 / 如何获取游戏 */
@Component
export struct HomeSheets {
  @Prop themeColors: AzaharThemeColors;
  @Prop appearanceMode: string = '';
  @Prop layoutType: string = 'grid';
  @Prop coverCornerRadius: number = 0;
  @Prop currentThemeId: string = '';
  @Prop downloadDirPath: string = '';
  @Link showViewOptionsSheet: boolean;
  @Link showHowToGetGamesPanel: boolean;
  @Link showWebUploadPanel: boolean;
  soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  // 直接观察 AppStorage：滑块拖动时显示值随存储更新（闭包读父级不会建立依赖）
  @StorageLink('gridSize') gridSize: number = GRID_COVER_BASE;
  @StorageLink('listSize') listSize: number = LIST_COVER_BASE;
  applyTheme: (id: string) => void = () => {};
  applyAppearanceMode: (index: number) => void = () => {};
  applyHomeLayout: (layout: LayoutType) => void = () => {};
  applyCoverSize: (size: number, persist: boolean) => void = () => {};

  private currentCoverSize(): number {
    return this.layoutType === 'grid' ? this.gridSize : this.listSize;
  }
  applyCoverCornerRadius: (radius: number, persist: boolean) => void = () => {};
  getWebUploadTargetPath: () => string = () => '';
  closeWebUploadPanel: () => void = () => {};
  scanAllGames: () => void = () => {};

  @Builder
  ViewOptionsSheet() {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_l') }) {
      Row() {
        Text(I18n.t('view_options'))
          .fontSize($r('sys.float.ohos_id_text_size_headline8'))
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_PRIMARY)
          .layoutWeight(1)

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize($r('sys.float.window_close_icon_width'))
            .fontColor([TEXT_SECONDARY])
        }
        .width($r('sys.float.sheet_close_icon_button_width'))
        .height($r('sys.float.sheet_close_icon_button_width'))
        .backgroundColor(BUTTON_BG_SECONDARY)
        .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
        .onFocus(() => {
          this.soundEffectManager.play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          this.soundEffectManager.play(SoundEffect.BACK);
          this.showViewOptionsSheet = false;
        })
      }
      .width('100%')

      Column() {
        SegmentOptionRow({ title: I18n.t('settings_appearance_mode'), options: [
          I18n.t('appearance_mode_auto'),
          I18n.t('appearance_mode_light'),
          I18n.t('appearance_mode_dark')
        ], selectedIndex: this.appearanceMode === 'light' ? 1 : (this.appearanceMode === 'dark' ? 2 : 0), onPick: (index: number) => { this.applyAppearanceMode(index); } })

        ThemeSelector({
          selectedThemeId: this.currentThemeId,
          onThemeChange: (themeId: string) => { this.applyTheme(themeId); }
        })

        Divider()
          .color($r('sys.color.ohos_id_color_list_separator'))
          .strokeWidth('1px')
          .margin({ left: $r('sys.float.ohos_id_card_margin_middle'), right: $r('sys.float.ohos_id_card_margin_middle') })

        SegmentOptionRow({ title: I18n.t('layout'), options: [
          I18n.t('grid'),
          I18n.t('list')
        ], selectedIndex: this.layoutType === 'grid' ? 0 : 1, onPick: (index: number) => { this.applyHomeLayout(index === 0 ? 'grid' : 'list'); } })

        Divider()
          .color($r('sys.color.ohos_id_color_list_separator'))
          .strokeWidth('1px')
          .margin({ left: $r('sys.float.ohos_id_card_margin_middle'), right: $r('sys.float.ohos_id_card_margin_middle') })

        WithTheme({ theme: controlThemeOf(this.themeColors) }) {
          Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
            Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
              Row() {
                Text(I18n.t('cover_size'))
                  .fontSize(FONT_SIZE_SETTING_TITLE)
                  .fontColor(TEXT_PRIMARY)
                  .fontWeight(FontWeight.Medium)
                  .layoutWeight(1)

                Text(`${this.currentCoverSize()}`)
                  .fontSize(FONT_SIZE_SETTING_DESC)
                  .fontColor(TEXT_SECONDARY)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')

              Slider({
                value: this.currentCoverSize(),
                min: this.layoutType === 'grid' ? GRID_COVER_SIZE_MIN : LIST_COVER_SIZE_MIN,
                max: this.layoutType === 'grid' ? GRID_COVER_SIZE_MAX : LIST_COVER_SIZE_MAX,
                step: 1,
                style: SliderStyle.InSet
              })
                .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
                .showSteps(false)
                .showTips(false)
                .onChange((value: number, mode: SliderChangeMode) => {
                  const rounded = Math.round(value);
                  if (mode === SliderChangeMode.End) {
                    this.soundEffectManager.play(SoundEffect.SELECT);
                    this.applyCoverSize(rounded, true);
                  } else {
                    this.applyCoverSize(rounded, false);
                  }
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
              Row() {
                Text(I18n.t('cover_corner_radius'))
                  .fontSize(FONT_SIZE_SETTING_TITLE)
                  .fontColor(TEXT_PRIMARY)
                  .fontWeight(FontWeight.Medium)
                  .layoutWeight(1)

                Text(`${this.coverCornerRadius.toFixed(0)}%`)
                  .fontSize(FONT_SIZE_SETTING_DESC)
                  .fontColor(TEXT_SECONDARY)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')

              Slider({
                value: this.coverCornerRadius,
                min: 0,
                max: COVER_RADIUS_MAX,
                step: 1,
                style: SliderStyle.InSet
              })
                .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
                .showSteps(false)
                .showTips(false)
                .onChange((value: number, mode: SliderChangeMode) => {
                  const rounded = Math.round(value);
                  if (mode === SliderChangeMode.End) {
                    this.soundEffectManager.play(SoundEffect.SELECT);
                    this.applyCoverCornerRadius(rounded, true);
                  } else {
                    this.applyCoverCornerRadius(rounded, false);
                  }
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end'), top: $r('sys.float.ohos_id_elements_margin_vertical_l'), bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })
        }
      }
      .width('100%')
      .backgroundColor(SHEET_CARD_BG)
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN, true))
      .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
      .padding($r('sys.float.ohos_id_text_paragraph_margin_xs'))
    }
    .width('100%')
    .padding(SHEET_CONTENT_PADDING)
    .backgroundColor(SHEET_BG_GROUPED)
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  @Builder
  WebUploadSheet() {
    AzaharWebUploadPanel({
      uploadPath: this.getWebUploadTargetPath(),
      themeColors: this.themeColors,
      onDismiss: () => {
        this.closeWebUploadPanel();
      },
      onUploadComplete: () => {
        this.scanAllGames();
      }
    })
  }

  @Builder
  HowToGetGamesSheet() {
    AzaharHowToGetGamesPanel({
      downloadDirPath: this.downloadDirPath,
      onDismiss: () => {
        this.showHowToGetGamesPanel = false;
      }
    })
  }

  build() {
    Stack() {
    Column() {
    }
    .bindSheet($$this.showWebUploadPanel, this.WebUploadSheet(), {
      height: SheetSize.FIT_CONTENT,
      showClose: false,
      backgroundColor: Color.Transparent,
      blurStyle: BlurStyle.COMPONENT_ULTRA_THICK,
      // 会话型面板：只允许右上角自定义关闭按钮（直接置状态），拦截遮罩点击/下滑/返回的关闭
      onWillDismiss: (_action: DismissSheetAction) => {}
    })

    Column() {
    }
    .bindSheet($$this.showHowToGetGamesPanel, this.HowToGetGamesSheet(), {
      height: SheetSize.FIT_CONTENT,
      showClose: false,
      backgroundColor: Color.Transparent,
      blurStyle: BlurStyle.COMPONENT_ULTRA_THICK
    })

    Column() {
    }
    .bindSheet($$this.showViewOptionsSheet, this.ViewOptionsSheet(), {
      height: SheetSize.FIT_CONTENT,
      showClose: false,
      systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK),
      onDisappear: () => {
        this.showViewOptionsSheet = false;
      }
    })
    }
  }
}

type LayoutType = 'grid' | 'list';
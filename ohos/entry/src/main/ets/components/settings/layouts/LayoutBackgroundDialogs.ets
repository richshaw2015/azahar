import { ComposeListItem } from '@kit.ArkUI';

import { OptionMenuRow } from '../../common/OptionMenuControls';

import { FloatTilesBackground } from '../../theme/FloatTilesBackground';
import { ThemeManager } from '../../../utils/ThemeManager';

import { AzaharThemeColors } from '../../../types/ThemeTypes';
import { LayoutConfigManager } from '../../../utils/LayoutConfigManager';
import { LayoutConfiguration, BackgroundMode, getBackgroundModeLabel, ALL_BACKGROUND_MODES, LayoutBackground, THEME_COLOR_BG_URI, isRawfileBgUri, rawfileBgPath, BUILTIN_BACKGROUNDS, BuiltinLayoutBackground } from '../../../types/LayoutTypes';
import { SoundEffectManager, SoundEffect } from '../../../utils/SoundEffectManager';
import { I18n } from '../../../utils/I18nManager';

import { setScrollSourceActive } from '../../../utils/ScrollAnimationState';
import { getOverlayThemeNameKey } from '../../../utils/OverlayThemeHelper';
import uiMaterial from '@ohos.arkui.uiMaterial';

import { immersiveMaterial } from '../../common/AzaharControls';

import {
  BUTTON_BG_SECONDARY,
  INPUT_HEIGHT,
  MENU_ITEM_DIVIDER,
  RADIUS_SHEET,
  SHEET_BG_GROUPED,
  SHEET_BUTTON_HEIGHT,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING,
  TEXT_ON_ACCENT,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../../types/UIConstants';

const BACKGROUND_LIST_KEY: string = 'background_list';
const DOMAIN = 0xFF00;
const TAG = 'Azahar_LayoutsSettings';

/** 背景管理弹窗域：背景选择/管理/预览/命名四个弹窗 + 两个菜单构建器 */
@Component
export struct LayoutBackgroundDialogs {
  @Link backgroundList: LayoutBackground[];
  @Link backgroundNameInputText: string;
  @Link dialogBackgroundMode: BackgroundMode;
  @Link dialogBackgroundUri: string;
  @Link pendingBackgroundUri: string;
  @Link previewBackground: LayoutBackground | null;
  @Link selectedBackgroundId: string;
  @Link showBackgroundDialog: boolean;
  @Link showBackgroundManager: boolean;
  @Link showBackgroundNameInput: boolean;
  @Link showBackgroundPreview: boolean;
  @Prop dialogScrollSourceId: number = 0;
  @Link editingLayout: LayoutConfiguration | null;
  @Prop isWaveAnimationPlaying: boolean = false;
  @Link refreshKey: number;
  @Prop safeAreaBottomVp: number = 0;
  @Prop safeAreaTopVp: number = 0;
  @Prop themeColors: AzaharThemeColors;
  deleteBackground: (bg: LayoutBackground) => void = () => {};
  getNoiseOpacity: () => number = () => 0;
  getSelectedBackgroundName: () => string = () => '';
  getThemedItemBg: () => ResourceColor = () => '';
  hexToNumber: (hex: string) => number = () => 0;
  isEditorLandscape: () => boolean = () => false;
  loadBackgroundList: () => void = () => {};
  pickNewBackground: () => void = () => {};
  saveBackgroundList: () => void = () => {};
  layoutManager: LayoutConfigManager = LayoutConfigManager.getInstance();
  themeManager: ThemeManager = ThemeManager.getInstance();

  @Builder
  BackgroundDialog() {
      Column() {
        // 标题栏
        Row() {          Text(I18n.t('background'))
            .fontSize($r("sys.float.ohos_id_text_size_headline8")).fontWeight(FontWeight.Bold).fontColor($r("sys.color.ohos_id_color_text_primary"))
            .layoutWeight(1)
          this.DialogCloseButton(() => { this.showBackgroundDialog = false; })
        }
        .width('100%')
                .margin({ bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })

        Column() {
          // 背景图片 (点击打开背景选择器)
          ComposeListItem({
            contentItem: {
              primaryText: I18n.t('bg_image'),
              secondaryText: this.getSelectedBackgroundName()
            },
            operateItem: {
              arrow: {
                value: $r('sys.symbol.chevron_right')
              }
            }
          })
          .onClick(() => {
            SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
            this.loadBackgroundList();
            this.selectedBackgroundId = this.dialogBackgroundUri;
            this.showBackgroundDialog = false;
            this.showBackgroundManager = true;
          })

          Divider()
            .color($r('sys.color.ohos_id_color_list_separator'))
            .strokeWidth('1px')
            .margin({ left: $r('sys.float.ohos_id_card_margin_middle'), right: $r('sys.float.ohos_id_card_margin_middle') })

          // 显示模式 — bindMenu 对号流派 (对齐 Android SingleChoiceItem: 6 种模式)
          OptionMenuRow({
            title: I18n.t('display_mode'),
            options: ALL_BACKGROUND_MODES.map((mode: BackgroundMode) => {
              return { value: getBackgroundModeLabel(mode) } as SelectOption;
            }),
            selectedIndex: Math.max(0, ALL_BACKGROUND_MODES.indexOf(this.dialogBackgroundMode)),
            accent: this.themeManager.getControlAccent(),
            onPick: (index: number) => {
              SoundEffectManager.getInstance().play(SoundEffect.SELECT);
              this.dialogBackgroundMode = ALL_BACKGROUND_MODES[index];
            }
          })
        }
        .width('100%')
        .backgroundColor(SHEET_CARD_BG)
        .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
        .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
        .clip(true)
      }
      .width('100%')
      .padding(SHEET_CONTENT_PADDING)
      .backgroundColor(SHEET_BG_GROUPED)
      .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  /** 获取当前选中背景的名称 */

  /**
   * 背景管理页面 - 对齐 Android BackgroundsActivity
   * 网格列表: "无" + 已添加背景，每项有缩略图、名称、选中标记、菜单(预览/删除)
   * 右下角 FAB: 添加新背景
   */

  @Builder
  BackgroundManagerDialog() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 波浪背景动画层 (对齐其他设置页面)
      FloatTilesBackground({ themeColors: this.themeColors, isPlaying: this.isWaveAnimationPlaying })

      Column() {
        // 标题栏 (对齐 Android TopAppBar)
        Row() {
          Text(I18n.t('bg_manager'))
            .fontSize($r("sys.float.ohos_id_text_size_headline8")).fontWeight(FontWeight.Bold).fontColor($r("sys.color.ohos_id_color_text_primary"))
            .layoutWeight(1)
          this.DialogCloseButton(() => { this.showBackgroundManager = false; })
        }
        .width('100%')
        .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l'), right: $r('sys.float.ohos_id_elements_margin_horizontal_l'), top: this.safeAreaTopVp, bottom: $r('sys.float.ohos_id_card_margin_middle') })

        // 背景网格列表 (对齐 Android LazyVerticalGrid)
        Scroll() {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            // "无" 选项 (对齐 Android NoneBackgroundItem + ic_block)
            Column() {
              Stack() {
                Column() {
                  SymbolGlyph($r("sys.symbol.nosign"))
                    .fontSize(48)
                    .fontColor([$r("sys.color.ohos_id_color_text_secondary")])
                }
                .width('100%')
                .aspectRatio(1)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(this.getThemedItemBg())
                .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))

                // 选中状态: 蓝色边框 + 勾选标记 (对齐 ThemeSelector)
                if (this.selectedBackgroundId === '') {
                  Column()
                    .width('100%')
                    .aspectRatio(1)
                    .border({ width: 3, color: ThemeManager.getInstance().getControlAccent() })
                    .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))

                  Row() {
                    SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                      .fontSize(20)
                      .fontColor([ThemeManager.getInstance().getControlAccent()])
                  }
                  .position({ x: '100%', y: 0 })
                  .translate({ x: -24, y: 4 })
                }
              }
              .width('100%')
              .border(this.selectedBackgroundId !== '' ? {
                width: 1, color: $r('sys.color.ohos_id_color_component_normal')
              } : { width: 0 })
              .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))

              Text(I18n.t('bg_none'))
                .fontSize($r("sys.float.ohos_id_text_size_body1"))
                .fontColor(this.selectedBackgroundId === '' ? ThemeManager.getInstance().getControlAccent() : $r("sys.color.ohos_id_color_text_primary"))
                .fontWeight(this.selectedBackgroundId === '' ? FontWeight.Medium : FontWeight.Normal)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
            }
            .width(this.isEditorLandscape() ? '23%' : '30%')
            .margin({ left: '1%', right: '1%', bottom: $r('sys.float.ohos_id_elements_margin_vertical_l') })
            .useEffect(true)
            .onClick(() => {
              SoundEffectManager.getInstance().play(SoundEffect.SELECT);
              this.selectedBackgroundId = '';
              this.dialogBackgroundUri = '';
              if (this.editingLayout) {
                this.editingLayout.backgroundUri = this.dialogBackgroundUri || undefined;
              }
              this.refreshKey++;
              this.showBackgroundManager = false;
            })

            // "系统主题色" 选项 - 参考 iPod 项目的颗粒感纹理效果
            Column() {
              Stack() {
                // 主题色渐变预览 + 颗粒感纹理
                Column()
                  .width('100%')
                  .aspectRatio(1)
                  .linearGradient({
                    angle: 180,
                    colors: [
                      [this.hexToNumber(this.themeColors.gradientStart), 0.0],
                      [this.hexToNumber(this.themeColors.gradientEnd), 0.6],
                      [this.hexToNumber(this.themeColors.accent), 1.0]
                    ]
                  })
                  .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))
                Image($rawfile('noise_texture.webp'))
                  .width('100%')
                  .aspectRatio(1)
                  .objectFit(ImageFit.Cover)
                  .opacity(this.getNoiseOpacity())
                  .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))

                // 选中状态: 蓝色边框 + 勾选标记 (对齐 ThemeSelector)
                if (this.selectedBackgroundId === THEME_COLOR_BG_URI) {
                  Column()
                    .width('100%')
                    .aspectRatio(1)
                    .border({ width: 3, color: ThemeManager.getInstance().getControlAccent() })
                    .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))

                  Row() {
                    SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                      .fontSize(20)
                      .fontColor([ThemeManager.getInstance().getControlAccent()])
                  }
                  .position({ x: '100%', y: 0 })
                  .translate({ x: -24, y: 4 })
                }
              }
              .width('100%')
              .border(this.selectedBackgroundId !== THEME_COLOR_BG_URI ? {
                width: 1, color: $r('sys.color.ohos_id_color_component_normal')
              } : { width: 0 })
              .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))

              Text(I18n.t('bg_theme_color'))
                .fontSize($r("sys.float.ohos_id_text_size_body1"))
                .fontColor(this.selectedBackgroundId === THEME_COLOR_BG_URI ? ThemeManager.getInstance().getControlAccent() : $r("sys.color.ohos_id_color_text_primary"))
                .fontWeight(this.selectedBackgroundId === THEME_COLOR_BG_URI ? FontWeight.Medium : FontWeight.Normal)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
            }
            .width(this.isEditorLandscape() ? '23%' : '30%')
            .margin({ left: '1%', right: '1%', bottom: $r('sys.float.ohos_id_elements_margin_vertical_l') })
            .useEffect(true)
            .onClick(() => {
              SoundEffectManager.getInstance().play(SoundEffect.SELECT);
              this.selectedBackgroundId = THEME_COLOR_BG_URI;
              this.dialogBackgroundUri = THEME_COLOR_BG_URI;
              if (this.editingLayout) {
                this.editingLayout.backgroundUri = this.dialogBackgroundUri || undefined;
              }
              this.refreshKey++;
              this.showBackgroundManager = false;
            })

            // 内置皮肤背景 (随素材包打包，显示名复用主题名，仅可预览不可删除)
            ForEach(BUILTIN_BACKGROUNDS, (bg: BuiltinLayoutBackground) => {
              Column() {
                Stack({ alignContent: Alignment.BottomEnd }) {
                  Image($rawfile(rawfileBgPath(bg.uri)))
                    .width('100%')
                    .aspectRatio(1)
                    .objectFit(ImageFit.Cover)
                    .backgroundColor(this.getThemedItemBg())
                    .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))

                  if (this.selectedBackgroundId === bg.uri) {
                    Column()
                      .width('100%')
                      .aspectRatio(1)
                      .border({ width: 3, color: ThemeManager.getInstance().getControlAccent() })
                      .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))
                      .position({ x: 0, y: 0 })

                    Row() {
                      SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                        .fontSize(20)
                        .fontColor([ThemeManager.getInstance().getControlAccent()])
                    }
                    .position({ x: '100%', y: 0 })
                    .translate({ x: -24, y: 4 })
                    .zIndex(1)
                  }

                  // 更多操作按钮 — 内置背景仅提供预览
                  Button({ type: ButtonType.Circle }) {
                    SymbolGlyph($r("sys.symbol.dot_grid_2x2"))
                      .fontSize(24)
                      .fontColor([$r('app.color.text_on_accent')])
                  }
                  .width(28).height(28)
                  .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
                  .margin({ bottom: $r('sys.float.ohos_id_text_paragraph_margin_xs'), right: $r('sys.float.ohos_id_elements_margin_horizontal_s') })
                  .onClick(() => { SoundEffectManager.getInstance().play(SoundEffect.DECIDE); })
                  .bindMenu(this.BuiltinBackgroundMenuBuilder(bg), {
                    placement: Placement.TopRight,
                    systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
                  })
                }
                .width('100%')
                .border(this.selectedBackgroundId !== bg.uri ? {
                  width: 1, color: $r('sys.color.ohos_id_color_component_normal')
                } : { width: 0 })
                .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))
                .useEffect(true)
                .onClick(() => {
                  SoundEffectManager.getInstance().play(SoundEffect.SELECT);
                  this.selectedBackgroundId = bg.uri;
                  this.dialogBackgroundUri = bg.uri;
                  if (this.editingLayout) {
                    this.editingLayout.backgroundUri = this.dialogBackgroundUri || undefined;
                  }
                  this.refreshKey++;
                  this.showBackgroundManager = false;
                })

                Text(I18n.t(getOverlayThemeNameKey(bg.themeId)))
                  .fontSize($r("sys.float.ohos_id_text_size_body1"))
                  .fontColor(this.selectedBackgroundId === bg.uri ? ThemeManager.getInstance().getControlAccent() : $r("sys.color.ohos_id_color_text_primary"))
                  .fontWeight(this.selectedBackgroundId === bg.uri ? FontWeight.Medium : FontWeight.Normal)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
              }
              .width(this.isEditorLandscape() ? '23%' : '30%')
              .margin({ left: '1%', right: '1%', bottom: $r('sys.float.ohos_id_elements_margin_vertical_l') })
            }, (bg: BuiltinLayoutBackground) => bg.id)

            // 已添加的背景 (对齐 Android BackgroundItem)
            ForEach(this.backgroundList, (bg: LayoutBackground) => {
              Column() {
                Stack({ alignContent: Alignment.BottomEnd }) {
                  Image(bg.uri)
                    .width('100%')
                    .aspectRatio(1)
                    .objectFit(ImageFit.Cover)
                    .backgroundColor(this.getThemedItemBg())
                    .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))

                  // 选中状态: 蓝色边框 + 勾选标记 (对齐 ThemeSelector)
                  if (this.selectedBackgroundId === bg.uri) {
                    Column()
                      .width('100%')
                      .aspectRatio(1)
                      .border({ width: 3, color: ThemeManager.getInstance().getControlAccent() })
                      .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))
                      .position({ x: 0, y: 0 })

                    Row() {
                      SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                        .fontSize(20)
                        .fontColor([ThemeManager.getInstance().getControlAccent()])
                    }
                    .position({ x: '100%', y: 0 })
                    .translate({ x: -24, y: 4 })
                    .zIndex(1)
                  }

                  // 更多操作按钮 (右下角) - 使用 bindMenu 对齐首页"启动固件"交互
                  Button({ type: ButtonType.Circle }) {
                    SymbolGlyph($r("sys.symbol.dot_grid_2x2"))
                      .fontSize(24)
                      .fontColor([$r('app.color.text_on_accent')])
                  }
                  .width(28).height(28)
                  .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
                  .margin({ bottom: $r('sys.float.ohos_id_text_paragraph_margin_xs'), right: $r('sys.float.ohos_id_elements_margin_horizontal_s') })
                  .onClick(() => { SoundEffectManager.getInstance().play(SoundEffect.DECIDE); })
                  .bindMenu(this.BackgroundItemMenuBuilder(bg), {
                    placement: Placement.TopRight,
                    systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
                  })
                }
                .width('100%')
                .border(this.selectedBackgroundId !== bg.uri ? {
                  width: 1, color: $r('sys.color.ohos_id_color_component_normal')
                } : { width: 0 })
                .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))
                .useEffect(true)
                .onClick(() => {
                  SoundEffectManager.getInstance().play(SoundEffect.SELECT);
                  this.selectedBackgroundId = bg.uri;
                  this.dialogBackgroundUri = bg.uri;
                  if (this.editingLayout) {
                    this.editingLayout.backgroundUri = this.dialogBackgroundUri || undefined;
                  }
                  this.refreshKey++;
                  this.showBackgroundManager = false;
                })

                Text(bg.name)
                  .fontSize($r("sys.float.ohos_id_text_size_body1"))
                  .fontColor(this.selectedBackgroundId === bg.uri ? ThemeManager.getInstance().getControlAccent() : $r("sys.color.ohos_id_color_text_primary"))
                  .fontWeight(this.selectedBackgroundId === bg.uri ? FontWeight.Medium : FontWeight.Normal)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
              }
              .width(this.isEditorLandscape() ? '23%' : '30%')
              .margin({ left: '1%', right: '1%', bottom: $r('sys.float.ohos_id_elements_margin_vertical_l') })
            }, (bg: LayoutBackground) => bg.id)
          }
          .width('100%')
          .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end'), top: $r('sys.float.ohos_id_default_padding_top'), bottom: 80 })
        }
        .layoutWeight(1)
        .onScrollStart(() => setScrollSourceActive(this.dialogScrollSourceId, true))
        .onScrollStop(() => setScrollSourceActive(this.dialogScrollSourceId, false))
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.safeAreaBottomVp })

      // FAB: 添加背景 (对齐 Android FloatingActionButton)
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r("sys.symbol.plus"))
          .fontSize(24)
          .fontColor([$r('app.color.text_on_accent')])
      }
      .width(56).height(56)
      .backgroundColor(this.themeColors.accent)
      .buttonStyle(ButtonStyleMode.EMPHASIZED)
      .margin({ right: $r('sys.float.ohos_id_max_padding_end'), bottom: 24 + this.safeAreaBottomVp })
      .shadow({ radius: 8, color: $r('app.color.fab_shadow'), offsetX: 0, offsetY: 4 })
      .onFocus(() => { SoundEffectManager.getInstance().play(SoundEffect.FOCUS); })
      .onClick(() => {
        SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
        this.pickNewBackground();
      })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 构建背景项的操作菜单项 - 使用 bindMenu 对齐首页"启动固件"交互
   */

  @Builder
  BackgroundItemMenuBuilder(bg: LayoutBackground) {
    Menu() {
      MenuItem({ content: I18n.t('layout_preview') })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.previewBackground = bg;
          this.showBackgroundPreview = true;
        })
      MenuItem({ content: I18n.t('delete') })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
          this.deleteBackground(bg);
        })
    }
    .fontColor($r("sys.color.ohos_id_color_text_primary"))
    .menuItemDivider(MENU_ITEM_DIVIDER)
  }

  /** 内置皮肤背景的操作菜单 — 仅预览 (随素材打包，不可删除) */

  @Builder
  BuiltinBackgroundMenuBuilder(bg: BuiltinLayoutBackground) {
    Menu() {
      MenuItem({ content: I18n.t('layout_preview') })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.previewBackground = { id: bg.id, name: I18n.t(getOverlayThemeNameKey(bg.themeId)), uri: bg.uri };
          this.showBackgroundPreview = true;
        })
    }
    .fontColor($r("sys.color.ohos_id_color_text_primary"))
    .menuItemDivider(MENU_ITEM_DIVIDER)
  }

  /**
   * 背景全屏预览 - 对齐 Android BackgroundPreviewScreen
   */

  @Builder
  BackgroundPreviewDialog() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 黑色背景
      Column()
        .width('100%').height('100%')
        .backgroundColor(Color.Black)
        .onClick(() => { SoundEffectManager.getInstance().play(SoundEffect.BACK); this.showBackgroundPreview = false; })

      // 背景图片
      if (this.previewBackground) {
        if (isRawfileBgUri(this.previewBackground.uri)) {
          Image($rawfile(rawfileBgPath(this.previewBackground.uri)))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        } else {
          Image(this.previewBackground.uri)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        }
      }

      // 返回按钮 — Circle + ULTRA_THIN 材质，与其他页面一致
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize($r('sys.float.window_close_icon_width'))
          .fontColor([TEXT_PRIMARY])
      }
      .width($r('sys.float.sheet_close_icon_button_width'))
      .height($r('sys.float.sheet_close_icon_button_width'))
      .backgroundColor(BUTTON_BG_SECONDARY)
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
      .margin({ left: $r('sys.float.ohos_id_default_padding_start'), top: this.safeAreaTopVp })
      .onFocus(() => { SoundEffectManager.getInstance().play(SoundEffect.FOCUS); })
      .onClick(() => {
        SoundEffectManager.getInstance().play(SoundEffect.BACK);
        this.showBackgroundPreview = false;
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .padding({ bottom: this.safeAreaBottomVp })
  }

  /**
   * 背景名称输入对话框 - 对齐 Android TextInputDialog
   */

  @Builder
  BackgroundNameInputDialog() {
      Column() {
        Row() {          Text(I18n.t('bg_name'))
            .fontSize($r("sys.float.ohos_id_text_size_headline8")).fontWeight(FontWeight.Bold).fontColor($r("sys.color.ohos_id_color_text_primary"))
            .layoutWeight(1)
          this.DialogCloseButton(() => { this.showBackgroundNameInput = false; })
        }
        .width('100%')
                .margin({ bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })

        Column() {
          TextInput({ text: this.backgroundNameInputText })
            .fontSize($r("sys.float.ohos_id_text_size_body1")).fontColor($r("sys.color.ohos_id_color_text_primary"))
            .placeholderColor($r("sys.color.ohos_id_color_text_secondary"))
            .backgroundColor(Color.Transparent)
            .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end') })
            .height(INPUT_HEIGHT)
            .onChange((value: string) => { this.backgroundNameInputText = value; })
        }
        .width('100%')
        .backgroundColor(SHEET_CARD_BG)
        .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
        .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
        .clip(true)

        Button(I18n.t('confirm'))
          .type(ButtonType.Capsule)
          .fontSize($r("sys.float.ohos_id_text_size_body1")).fontColor(TEXT_ON_ACCENT)
          .backgroundColor(this.themeManager.getControlAccent())
          .buttonStyle(ButtonStyleMode.EMPHASIZED)
          .width('100%').height(SHEET_BUTTON_HEIGHT).margin({ top: $r('sys.float.ohos_id_elements_margin_vertical_l') })
          .onClick(() => {
            SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
            if (this.backgroundNameInputText.trim().length > 0 && this.pendingBackgroundUri) {
              const newBg: LayoutBackground = {
                id: Date.now().toString() + '_' + Math.random().toString(36).substring(2, 8),
                name: this.backgroundNameInputText.trim(),
                uri: this.pendingBackgroundUri,
              };
              this.backgroundList.push(newBg);
              this.saveBackgroundList();
              this.backgroundList = this.backgroundList.slice(); // trigger refresh
            }
            this.showBackgroundNameInput = false;
            this.pendingBackgroundUri = '';
          })
      }
      .width('100%')
      .padding(SHEET_CONTENT_PADDING)
      .backgroundColor(SHEET_BG_GROUPED)
      .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  /**
   * 选择新背景图片 (对齐 Android addBackgroundLauncher)
   */

  /** 删除背景 (对齐 Android BackgroundsViewModel.deleteBackground) */

  /** 加载背景列表 */

  /** 保存背景列表 */

  /**
   * 布局名称输入对话框 — 游戏化风格
   */

  @Builder
  DialogCloseButton(onClose: () => void) {
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
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      SoundEffectManager.getInstance().play(SoundEffect.BACK);
      onClose();
    })
  }

  build() {
    Stack() {
    Column()
      .bindSheet($$this.showBackgroundDialog, this.BackgroundDialog(), {
        height: SheetSize.FIT_CONTENT,
        showClose: false,
        systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK),
        onDisappear: () => {
          if (this.editingLayout) {
            this.editingLayout.backgroundUri = this.dialogBackgroundUri || undefined;
            this.editingLayout.backgroundMode = this.dialogBackgroundMode;
          }
          this.showBackgroundDialog = false;
          this.refreshKey++;
        }
      })
    Column()
      .bindSheet($$this.showBackgroundNameInput, this.BackgroundNameInputDialog(), {
        height: SheetSize.FIT_CONTENT,
        showClose: false,
        systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK),
        onDisappear: () => {
          this.showBackgroundNameInput = false;
        }
      })
    if (this.showBackgroundManager) {
      this.BackgroundManagerDialog()
    }
    if (this.showBackgroundPreview) {
      this.BackgroundPreviewDialog()
    }
    }
  }
}

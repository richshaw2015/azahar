import { SliderSettingItem } from '../SliderSettingItem';
import { SheetActionRow, SheetRowDivider } from '../../common/MultiplayerSheets';

import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';

import { LayoutConfiguration, BackgroundMode } from '../../../types/LayoutTypes';
import { SoundEffectManager, SoundEffect } from '../../../utils/SoundEffectManager';
import { I18n } from '../../../utils/I18nManager';

import { SnapGuideSystem } from '../../../utils/SnapGuideSystem';

import uiMaterial from '@ohos.arkui.uiMaterial';

import { immersiveMaterial } from '../../common/AzaharControls';

import {
  BUTTON_BG_SECONDARY,
  INPUT_HEIGHT,
  RADIUS_SHEET,
  SETTING_ITEM_PADDING,
  SHEET_BG_GROUPED,
  SHEET_BUTTON_HEIGHT,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING,
  TEXT_ON_ACCENT,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../../types/UIConstants';

import { AzaharThemeColors } from '../../../types/ThemeTypes';

/** 编辑器属性弹窗组：网格尺寸/属性表/名称输入/透明度控件/菜单面板 */
@Component
export struct LayoutEditorSheets {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  @Link dialogBackgroundMode: BackgroundMode;
  @Link dialogBackgroundUri: string;
  @Link dialogLayoutName: string;
  @Link dialogOpacity: number;
  @Link dialogSecondaryScreenOpacity: number;
  @Link dialogUseCustomOpacity: boolean;
  @Link nameInputText: string;
  @Link showBackgroundDialog: boolean;
  @Link showBottomControls: boolean;
  @Link showGridSizeDialog: boolean;
  @Link showMenuSheet: boolean;
  @Link showNameInputDialog: boolean;
  @Link showPropertiesDialog: boolean;
  @Link editingLayout: LayoutConfiguration | null;
  @Prop editorWidth: number = 0;
  @Prop gridSize: number = 0;
  setGridSize: (size: number) => void = () => {};
  exitWithoutSaving: () => void = () => {};
  menuSaveAndExit: () => void = () => {};
  openBackgroundDialog: () => void = () => {};
  openPropertiesDialog: () => void = () => {};
  resetToDefault: () => void = () => {};
  revertChanges: () => void = () => {};
  storeLayoutChanges: () => void = () => {};
  saveAndExit: () => void = () => {};
  themeManager: ThemeManager = ThemeManager.getInstance();

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

  @Builder
  GridSizeDialog() {
      Column() {
        Row() {          Text(I18n.t('layout_editor_grid_size'))
            .fontSize($r("sys.float.ohos_id_text_size_headline8")).fontWeight(FontWeight.Bold).fontColor($r("sys.color.ohos_id_color_text_primary"))
            .layoutWeight(1)
          this.DialogCloseButton(() => {
            this.showGridSizeDialog = false;
            this.showBottomControls = true;
          })
        }
        .width('100%')
                .margin({ bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })

        Column() {
          SliderSettingItem({
            title: I18n.t('layout_editor_grid_size_desc'),
            value: this.gridSize,
            min: SnapGuideSystem.MIN_GRID_SIZE,
            max: SnapGuideSystem.MAX_GRID_SIZE,
            step: SnapGuideSystem.GRID_SIZE_STEP,
            onChange: (value: number) => {
              this.setGridSize(value);
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

  /** 添加组件对话框 — 游戏化风格 */
  /** 判断编辑器当前是否宽屏模式 (与 PauseMenu/Index 等统一使用 600) */
  private isEditorLandscape(): boolean {
    return this.editorWidth >= 600;
  }

  /**
   * 获取编辑器背景图片的对齐方式 (对齐 Android ViewExtensions.setBackgroundMode)
   * Android 的实现根据图片和视图的宽高比关系动态选择对齐方式
   */
  private getEditorBackgroundAlignment(): Alignment {
    const mode = this.editingLayout?.backgroundMode ?? BackgroundMode.FIT_CENTER;
    switch (mode) {
      case BackgroundMode.STRETCH: return Alignment.Center;
      case BackgroundMode.FIT_CENTER: return Alignment.Center;
      case BackgroundMode.FIT_TOP: return Alignment.Top;
      case BackgroundMode.FIT_LEFT: return Alignment.Start;
      case BackgroundMode.FIT_BOTTOM: return Alignment.Bottom;
      case BackgroundMode.FIT_RIGHT: return Alignment.End;
      default: return Alignment.Center;
    }
  }

    /** 添加组件对话框 */

  @Builder
  EditorMenuRow(icon: Resource, titleKey: string, danger: boolean, action: () => void) {
    SheetActionRow(icon, I18n.t(titleKey), danger, () => {
      this.showMenuSheet = false;
      action();
    })
  }

  /** 编辑器菜单面板 — 与其他 sheet 同套规范 */

  @Builder
  EditorMenuSheet() {
    Column() {
      Row() {
        Text(I18n.t('menu'))
          .fontSize($r('sys.float.ohos_id_text_size_headline8'))
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_PRIMARY)
          .layoutWeight(1)
        this.DialogCloseButton(() => { this.showMenuSheet = false; })
      }
      .width('100%')
      .margin({ bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })

      Column() {
        this.EditorMenuRow($r('sys.symbol.gearshape'), 'properties', false, () => { this.openPropertiesDialog(); })
        SheetRowDivider()
        this.EditorMenuRow($r('sys.symbol.paintpalette'), 'background', false, () => { this.openBackgroundDialog(); })
        SheetRowDivider()
        this.EditorMenuRow($r('sys.symbol.arrow_counterclockwise'), 'undo_changes', false, () => { this.revertChanges(); })
        SheetRowDivider()
        this.EditorMenuRow($r('sys.symbol.arrow_clockwise'), 'reset_default', false, () => { this.resetToDefault(); })
        SheetRowDivider()
        this.EditorMenuRow($r('sys.symbol.checkmark'), 'save_and_exit', false, () => { this.menuSaveAndExit(); })
        SheetRowDivider()
        this.EditorMenuRow($r('sys.symbol.xmark'), 'exit_no_save', true, () => { this.exitWithoutSaving(); })
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

/** 打开属性对话框 */

  /**
   * 显示布局名称输入对话框 (对齐 Android showLayoutNameInputDialog)
   * Android: TextInputDialog, initialText = "Custom layout", onConfirm → setCurrentLayoutName + saveAndExit
   */

  /**
   * 打开背景配置对话框 (对齐 Android openBackgroundsConfigDialog)
   */

  /**
   * 属性设置底部面板 — bindSheet，与首页"显示选项"对齐：
   * SHEET_BG_GROUPED 半透明底 + THICK 材质，改动即时写回 editingLayout
   */

  @Builder
  PropertiesSheet() {
    Column() {
      Row() {
        Text(I18n.t('properties'))
          .fontSize($r('sys.float.ohos_id_text_size_headline8'))
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_PRIMARY)
          .layoutWeight(1)
        this.DialogCloseButton(() => { this.showPropertiesDialog = false; })
      }
      .width('100%')
            .margin({ bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })

      Column() {
        this.LayoutNameField()

        Divider()
          .color($r('sys.color.ohos_id_color_list_separator'))
          .strokeWidth('1px')
          .margin({ left: $r('sys.float.ohos_id_card_margin_middle'), right: $r('sys.float.ohos_id_card_margin_middle'), top: 12, bottom: 4 })

        this.ButtonOpacityControls(8)

        Divider()
          .color($r('sys.color.ohos_id_color_list_separator'))
          .strokeWidth('1px')
          .margin({ left: $r('sys.float.ohos_id_card_margin_middle'), right: $r('sys.float.ohos_id_card_margin_middle'), top: 12, bottom: 4 })

        this.SecondaryScreenOpacityControls(8)
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

  @Builder
  LayoutNameField() {
    Column() {
      Text(I18n.t('layout_name')).fontSize($r("sys.float.ohos_id_text_size_body1")).fontColor($r("sys.color.ohos_id_color_text_primary"))
        .fontWeight(FontWeight.Medium)
      TextInput({ placeholder: I18n.t('layout_name_placeholder'), text: this.dialogLayoutName })
        .fontSize($r("sys.float.ohos_id_text_size_body1")).fontColor($r("sys.color.ohos_id_color_text_primary"))
        .placeholderColor($r("sys.color.ohos_id_color_text_secondary"))
        .backgroundColor(Color.Transparent)
        .padding({ left: 0, right: 0 })
        .height(INPUT_HEIGHT)
        .margin({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
        .onChange((value: string) => {
          this.dialogLayoutName = value;
          if (this.editingLayout) {
            this.editingLayout.name = value.trim();
          }
        })
    }
    .width('100%')
    .padding(SETTING_ITEM_PADDING)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ButtonOpacityControls(topMargin: number) {
    Column() {
      Row() {
        Text(I18n.t('use_default_button_opacity')).fontSize($r("sys.float.ohos_id_text_size_body1")).fontColor($r("sys.color.ohos_id_color_text_primary")).fontWeight(FontWeight.Medium).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: !this.dialogUseCustomOpacity })
          .selectedColor(ThemeManager.getInstance().getControlAccent())
          .onChange((isOn: boolean) => {
            SoundEffectManager.getInstance().play(isOn ? SoundEffect.TOGGLE_ON : SoundEffect.TOGGLE_OFF);
            this.dialogUseCustomOpacity = !isOn;
            if (this.editingLayout) {
              this.editingLayout.useCustomOpacity = this.dialogUseCustomOpacity;
            }
          })
      }
      .width('100%')
      .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end') })

      SliderSettingItem({
        title: I18n.t('button_opacity'),
        value: this.dialogOpacity,
        min: 0,
        max: 100,
        step: 1,
        disabled: !this.dialogUseCustomOpacity,
        onChange: (value: number) => {
          this.dialogOpacity = value;
          if (this.editingLayout) {
            this.editingLayout.opacity = Math.round(value);
          }
        }
      })
      .margin({ top: $r('sys.float.ohos_id_elements_margin_vertical_m') })
      .opacity(this.dialogUseCustomOpacity ? 1.0 : 0.5)
    }
    .width('100%')
    .margin({ top: topMargin })
  }

  @Builder
  SecondaryScreenOpacityControls(topMargin: number) {
    Column() {
      SliderSettingItem({
        title: I18n.t('secondary_screen_opacity'),
        value: this.dialogSecondaryScreenOpacity,
        min: 0,
        max: 100,
        step: 1,
        onChange: (value: number) => {
          this.dialogSecondaryScreenOpacity = value;
          if (this.editingLayout) {
            this.editingLayout.secondaryScreenOpacity = Math.round(value);
          }
        }
      })
    }
    .width('100%')
    .margin({ top: topMargin })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 背景配置对话框 - 对齐 Android LayoutBackgroundDialog
   * 包含: 背景名称(点击打开背景管理器) + 显示模式(6种) + 取消/确定
   */

  @Builder
  NameInputDialog() {
      Column() {
        // 标题栏: icon + 标题 + 关闭按钮
        Row() {          Text(I18n.t('layout_name'))
            .fontSize($r("sys.float.ohos_id_text_size_headline8")).fontWeight(FontWeight.Bold).fontColor($r("sys.color.ohos_id_color_text_primary"))
            .layoutWeight(1)
          this.DialogCloseButton(() => { this.showNameInputDialog = false; })
        }
        .width('100%')
                .margin({ bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })

        Column() {
          TextInput({ text: this.nameInputText })
            .fontSize($r("sys.float.ohos_id_text_size_body1")).fontColor($r("sys.color.ohos_id_color_text_primary"))
            .backgroundColor(Color.Transparent)
            .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end') })
            .width('100%').height(INPUT_HEIGHT)
            .onChange((value: string) => { this.nameInputText = value; })
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
            const name = this.nameInputText.trim();
            if (name.length === 0) return;
            SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
            if (this.editingLayout) {
              this.editingLayout.name = name;
            }
            this.showNameInputDialog = false;
            this.saveAndExit();
          })
      }
      .width('100%')
      .padding(SHEET_CONTENT_PADDING)
      .backgroundColor(SHEET_BG_GROUPED)
      .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  build() {
    Stack() {
    Column()
      .bindSheet($$this.showPropertiesDialog, this.PropertiesSheet(), {
        height: SheetSize.FIT_CONTENT,
        showClose: false,
        systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK),
        onDisappear: () => {
          this.showPropertiesDialog = false;
        }
      })
    Column()
      .bindSheet($$this.showGridSizeDialog, this.GridSizeDialog(), {
        height: SheetSize.FIT_CONTENT,
        showClose: false,
        systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK),
        onDisappear: () => {
          this.showGridSizeDialog = false;
          this.showBottomControls = true;
        }
      })
    Column()
      .bindSheet($$this.showNameInputDialog, this.NameInputDialog(), {
        height: SheetSize.FIT_CONTENT,
        showClose: false,
        systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK),
        onDisappear: () => {
          this.showNameInputDialog = false;
        }
      })
    Column()
      .bindSheet($$this.showMenuSheet, this.EditorMenuSheet(), {
        height: SheetSize.FIT_CONTENT,
        showClose: false,
        systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK),
        onDisappear: () => {
          this.showMenuSheet = false;
        }
      })
    }
  }
}

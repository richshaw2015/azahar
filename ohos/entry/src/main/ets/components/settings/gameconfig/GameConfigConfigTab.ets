import { SettingsList, SettingsSectionHeader, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { GameConfigActionRow, GameConfigSelectRow, GameConfigStringSelectRow } from './GameConfigWidgets';
import { SheetTitleBar } from '../../common/MultiplayerSheets';
import { TextInputSettingItem } from '../TextInputSettingItem';
import { AzaharGameConfig } from '../../../utils/GameConfigManager';
import { SettingOption } from '../../../types/SettingsTypes';
import { ScreenFilterItem, screenFilterItems } from '../../../types/ScreenFilterDefs';
import { AzaharNative } from '../../../types/AzaharNative';
import { I18n } from '../../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../../utils/SoundEffectManager';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { AzaharThemeColors } from '../../../types/ThemeTypes';
import { controlAccentOf, immersiveMaterial } from '../../common/AzaharControls';
import uiMaterial from '@ohos.arkui.uiMaterial';
import {
  BUTTON_ICON_SM,
  RADIUS_SHEET,
  SHEET_BG_GROUPED,
  SHEET_BUTTON_HEIGHT,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING,
  TEXT_ON_ACCENT,
  TEXT_PRIMARY
} from '../../../types/UIConstants';

/** 单游戏配置：仅展示常用的兼容性选项及 3DS 特有设置。 */
@Component
export struct GameConfigConfigTab {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller: Scroller = new Scroller();
  @Prop topSpace: number = 0;
  @Prop titleId: string = '';
  @Prop config: AzaharGameConfig;
  @Prop baseGameName: string;
  // 页面级有效显示名（含自定义名与名称来源偏好），与标题栏展示一致
  @Prop displayName: string = '';
  @Prop layoutDescription: string = '';
  @Link editNameValue: string;
  @State private showRenameSheet: boolean = false;
  @State private renameInput: string = '';
  soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  updateConfig: (updater: (config: AzaharGameConfig) => void) => void = () => {};
  resetGameConfig: () => void = () => {};
  openLayoutPicker: () => void = () => {};

  private rawOptions(values: number[], labels: string[]): SettingOption[] {
    const options: SettingOption[] = [{ value: -1, label: I18n.t('follow_global') }];
    values.forEach((value: number, index: number) => {
      options.push({ value: value, label: labels[index] });
    });
    return options;
  }

  private keyOptions(values: number[], keys: string[]): SettingOption[] {
    return this.rawOptions(values, keys.map((key: string): string => I18n.t(key)));
  }

  private triOptions(): SettingOption[] {
    return this.rawOptions([1, 0], [I18n.t('on'), I18n.t('off')]);
  }

  // 与全局图形设置一致钳到 1~4x，额外带"跟随全局"项表示不覆盖、继承全局值
  private resolutionOptions(): SettingOption[] {
    const labels: string[] = [];
    for (let factor = 1; factor <= 4; factor++) {
      labels.push(factor === 1
        ? I18n.t('internal_resolution_native_fmt')
        : I18n.tf1('internal_resolution_multiple_fmt', 'factor', factor));
    }
    return this.rawOptions([1, 2, 3, 4], labels);
  }

  // 空字符串 = 跟随全局 pp_shader_name
  private screenFilterOptions(): SettingOption[] {
    const options: SettingOption[] = [{ value: '', label: I18n.t('follow_global') }];
    screenFilterItems().forEach((item: ScreenFilterItem) => {
      options.push({ value: item.value, label: item.label });
    });
    return options;
  }

  // hack 数据库存在该游戏的 FORCE 级 perf quirk 时才显示性能补丁项
  private hasPerfHacks(): boolean {
    return this.titleId.length > 0 && AzaharNative.hasGamePerfHacks(this.titleId);
  }

  @Builder
  private SectionHeader(title: string) {
    SettingsSectionHeader({ title: title })
  }

  build() {
    SettingsList({ scroller: this.scroller, topSpace: this.topSpace }) {
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          GameConfigActionRow({
            icon: '',
            title: I18n.t('display_name'),
            description: this.displayName || this.baseGameName,
            onAction: () => {
              this.renameInput = this.displayName || this.baseGameName;
              this.showRenameSheet = true;
            }
          })
        }
        ListItem() {
          GameConfigActionRow({
            icon: '',
            title: I18n.t('touch_button_layout'),
            description: this.layoutDescription || I18n.t('use_global_layout'),
            onAction: () => this.openLayoutPicker()
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())
      .bindSheet($$this.showRenameSheet, this.RenameSheet(), {
        height: SheetSize.FIT_CONTENT,
        showClose: false,
        systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
      })

      ListItem() {
        this.SectionHeader(I18n.t('settings_graphics'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          GameConfigSelectRow({
            title: I18n.t('settings_render_api'),
            description: '',
            options: this.keyOptions([1, 2], ['renderer_opengl_es', 'renderer_vulkan']),
            selected: this.config.graphicsApi,
            onSelect: (value: number) => {
              this.updateConfig((config: AzaharGameConfig) => { config.graphicsApi = value; });
            }
          })
        }
        ListItem() {
          GameConfigSelectRow({
            title: I18n.t('settings_internal_resolution'),
            description: '',
            options: this.resolutionOptions(),
            selected: this.config.resolutionFactor,
            onSelect: (value: number) => {
              this.updateConfig((config: AzaharGameConfig) => { config.resolutionFactor = value; });
            }
          })
        }
        ListItem() {
          GameConfigStringSelectRow({
            title: I18n.t('settings_screen_filter'),
            description: '',
            options: this.screenFilterOptions(),
            selected: this.config.ppShaderName,
            onSelect: (value: string) => {
              this.updateConfig((config: AzaharGameConfig) => { config.ppShaderName = value; });
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('emulation_settings'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          GameConfigSelectRow({
            title: I18n.t('settings_new_3ds_mode'),
            description: I18n.t('settings_new_3ds_mode_desc'),
            options: this.triOptions(),
            selected: this.config.isNew3ds,
            onSelect: (value: number) => {
              this.updateConfig((config: AzaharGameConfig) => { config.isNew3ds = value; });
            }
          })
        }
        if (this.hasPerfHacks()) {
          ListItem() {
            GameConfigSelectRow({
              title: I18n.t('settings_game_perf_hacks'),
              description: I18n.t('settings_game_perf_hacks_desc'),
              options: this.triOptions(),
              selected: this.config.gamePerfHacks,
              onSelect: (value: number) => {
                this.updateConfig((config: AzaharGameConfig) => { config.gamePerfHacks = value; });
              }
            })
          }
        }
        ListItem() {
          GameConfigSelectRow({
            title: I18n.t('mic_source'),
            description: '',
            options: this.keyOptions([1, 7, 6, 2], ['none', 'opt_blow', 'opt_device_mic', 'opt_noise']),
            selected: this.config.inputType,
            onSelect: (value: number) => {
              this.updateConfig((config: AzaharGameConfig) => { config.inputType = value; });
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 页级恢复操作垫底：作用域是整页配置，独立成卡、不挂设置类分组标题
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          GameConfigActionRow({
            icon: $r('sys.symbol.arrow_clockwise'),
            title: I18n.t('restore_global'),
            description: '',
            onAction: () => this.resetGameConfig()
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
    }
  }

  // 重命名底部弹窗：配方同 CheatDetailSheet——标题栏 + 白卡输入框 + 底部胶囊按钮
  @Builder
  private RenameSheet() {
    Column() {
      SheetTitleBar(I18n.t('display_name'), () => {
        this.showRenameSheet = false;
      })

      Column() {
        TextInputSettingItem({
          title: I18n.t('name'),
          value: this.renameInput,
          placeholder: this.baseGameName,
          maxLength: 80,
          onChange: (value: string) => {
            this.renameInput = value;
          }
        })
      }
      .width('100%')
      .backgroundColor(SHEET_CARD_BG)
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
      .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
      .clip(true)

      Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
        Button() {
          Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(BUTTON_ICON_SM)
              .fontColor([TEXT_PRIMARY])
            Text(I18n.t('reset'))
              .fontSize($r('sys.float.ohos_id_text_size_button2'))
              .fontColor(TEXT_PRIMARY)
          }
          .justifyContent(FlexAlign.Center)
        }
        .type(ButtonType.Capsule)
        .height(SHEET_BUTTON_HEIGHT)
        .backgroundColor(listCardBgOf(this.themeColors))
        .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
        .layoutWeight(1)
        .onFocus(() => {
          this.soundEffectManager.play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          this.soundEffectManager.play(SoundEffect.DECIDE);
          this.renameInput = '';
        })
        Button() {
          Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(BUTTON_ICON_SM)
              .fontColor([TEXT_ON_ACCENT])
            Text(I18n.t('confirm'))
              .fontSize($r('sys.float.ohos_id_text_size_button2'))
              .fontColor(TEXT_ON_ACCENT)
          }
          .justifyContent(FlexAlign.Center)
        }
        .type(ButtonType.Capsule)
        .height(SHEET_BUTTON_HEIGHT)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .fontColor(TEXT_ON_ACCENT)
        .backgroundColor(controlAccentOf(this.themeColors))
        .layoutWeight(1)
        .onFocus(() => {
          this.soundEffectManager.play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          this.soundEffectManager.play(SoundEffect.CONFIRM);
          this.editNameValue = this.renameInput.trim();
          this.updateConfig((config: AzaharGameConfig) => { config.customName = this.renameInput.trim(); });
          this.showRenameSheet = false;
        })
      }
      .width('100%')
      .margin({ top: $r('sys.float.ohos_id_elements_margin_vertical_m') })
    }
    .width('100%')
    .padding(SHEET_CONTENT_PADDING)
    .backgroundColor(SHEET_BG_GROUPED)
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }
}

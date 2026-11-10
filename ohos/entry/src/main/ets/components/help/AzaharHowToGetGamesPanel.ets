import { FileManagerHelper } from '../../utils/FileManagerHelper';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';

import {
  BUTTON_BG_SECONDARY,
  RADIUS_SHEET,
  SHEET_BG_GROUPED,
  SHEET_CONTENT_PADDING,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';
import { StaticInfoRow } from '../settings/SettingsList';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { immersiveMaterial } from '../common/AzaharControls';

import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../utils/ThemeManager';
import { AzaharThemeColors } from '../../types/ThemeTypes';

@Component
export struct AzaharHowToGetGamesPanel {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  @Prop downloadDirPath: string = '';

  onDismiss: () => void = () => {};

  private romsPathText(): string {
    if (!this.downloadDirPath) {
      return I18n.t('default_roms_path');
    }
    return FileManagerHelper.getDisplayPath(`${this.downloadDirPath}/roms`);
  }

  build() {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
      this.Header()
      Scroll() {
        Column() {
          // 单卡分组：ComposeListItem 行 + 发丝分隔线
          this.RowItem($r('sys.symbol.doc'), I18n.t('help_supported_files_title'), I18n.t('help_supported_files_desc'))
          this.RowDivider()
          this.RowItem($r('sys.symbol.folder'), I18n.t('help_download_dir_title'),
            I18n.tf1('help_download_dir_desc_fmt', 'path', this.romsPathText()))
          this.RowDivider()
          this.RowItem($r('sys.symbol.doc'), I18n.t('help_select_file_title'), I18n.t('help_select_file_desc'))
          this.RowDivider()
          this.RowItem($r('sys.symbol.upload'), I18n.t('help_web_upload_title'), I18n.t('help_web_upload_desc'))
          this.RowDivider()
          this.RowItem($r('sys.symbol.exclamationmark_triangle'), I18n.t('notice'), I18n.t('legal_import_notice'))
        }
        .width('100%')
      }
      .scrollBar(BarState.Auto)
      .constraintSize({ maxHeight: 420 })
    }
    .width('100%')
    .padding(SHEET_CONTENT_PADDING)
    .backgroundColor(SHEET_BG_GROUPED)
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  @Builder
  private Header() {
    Row() {
      Text(I18n.t('how_to_import_games'))
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
        SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
      })
      .onClick(() => {
        SoundEffectManager.getInstance().play(SoundEffect.BACK);
        this.onDismiss();
      })
    }
    .width('100%')
  }

  @Builder
  private RowItem(icon: Resource, title: string, desc: string) {
    // 纯信息展示行，无点击事件——用无按压态的静态行
    StaticInfoRow({ icon: icon, title: title, desc: desc })
  }

  @Builder
  private RowDivider() {
    Divider()
      .color($r('sys.color.ohos_id_color_list_separator'))
      .strokeWidth('1px')
      .margin({ left: $r('sys.float.ohos_id_card_margin_middle'), right: $r('sys.float.ohos_id_card_margin_middle') })
  }
}

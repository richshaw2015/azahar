import { pasteboard } from '@kit.BasicServicesKit';
import { SheetRowDivider, SheetTitleBar } from '../common/MultiplayerSheets';
import { TextInputSettingItem } from '../settings/TextInputSettingItem';
import { AzaharThemeColors } from '../../types/ThemeTypes';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../utils/ThemeManager';
import { controlAccentOf, immersiveMaterial } from '../common/AzaharControls';
import {
  BUTTON_ICON_SM,
  FONT_SIZE_MIN,
  FONT_SIZE_SETTING_TITLE,
  INPUT_BORDER_RADIUS,
  INPUT_PADDING_H,
  RADIUS_SHEET,
  SETTING_ITEM_PADDING,
  SHEET_BG_GROUPED,
  SHEET_BUTTON_HEIGHT,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING,
  TEXT_DANGER,
  TEXT_ON_ACCENT,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { inputBgOf, listCardBgOf } from '../../utils/ThemeSurfaces';
import { showSuccessToast } from '../../utils/ToastHelper';

/**
 * 金手指新增/详情底部弹窗内容（bindSheet 的 sheetBuilder 用，弹层几何走系统规范）。
 * 游戏详情页金手指 Tab 与游戏内金手指面板共用，保证两边交互一致：
 * 名称/代码（代码框右上角复制）+ 底部删除（canDelete 时）/保存；备注不在表单内编辑，
 * 由父级在保存时沿用原值。
 * 保存由父级 onSave 校验并写盘，返回错误文案（空串=成功，父级负责关弹窗）；
 * 字段变更会清掉上一次的保存错误。
 */
@Component
export struct AzaharCheatFormSheet {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  @Prop title: string = '';
  @Prop canDelete: boolean = false;
  @Link name: string;
  @Link code: string;
  @State private error: string = '';
  @State private copied: boolean = false;

  onClose: () => void = () => {};
  onSave: () => string = () => '';
  onDelete: () => void = () => {};

  aboutToAppear(): void {
    this.error = '';
    this.copied = false;
  }

  private copyCode(): void {
    if (!this.code) {
      return;
    }
    // 同步写剪贴板：setData 的 Promise 可能被 reject（如有复制操作进行中），
    // 之前无 catch 会静默失败；同步版要么写入要么抛错，失败可见
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.code);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.copied = true;
      setTimeout(() => { this.copied = false; }, 2000);
      showSuccessToast(I18n.t('cheat_code_copied'));
    } catch (error) {
      console.error(`[AzaharCheatFormSheet] copy cheat code failed: ${(error as Error).message}`);
    }
  }

  build() {
    Column() {
      SheetTitleBar(this.title, () => {
        this.onClose();
      })

      Column() {
        TextInputSettingItem({
          title: I18n.t('name'),
          value: this.name,
          placeholder: I18n.t('name'),
          showCounter: false,
          onChange: (value: string) => {
            this.name = value;
            this.error = '';
          }
        })
        SheetRowDivider()
        Column({ space: $r('sys.float.ohos_id_text_paragraph_margin_xs') }) {
          Text(I18n.t('code'))
            .fontSize(FONT_SIZE_SETTING_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT_PRIMARY)
            .width('100%')
          Stack({ alignContent: Alignment.TopEnd }) {
            TextArea({ text: this.code, placeholder: I18n.t('placeholder_cheat_code') })
              .width('100%')
              .height(150)
              .fontSize($r('sys.float.ohos_id_text_size_body2'))
              .fontFamily('monospace')
              .fontColor(TEXT_PRIMARY)
              .placeholderColor(TEXT_SECONDARY)
              .backgroundColor(Color.Transparent)
              .padding({ left: INPUT_PADDING_H, right: $r('sys.float.ohos_id_button_height'), top: $r('sys.float.ohos_id_elements_margin_vertical_m'), bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })
              .onFocus(() => {
                SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
              })
              .onChange((value: string) => {
                this.code = value;
                this.error = '';
              })

            Button({ type: ButtonType.Normal }) {
              SymbolGlyph(this.copied ? $r('sys.symbol.checkmark') : $r('sys.symbol.doc_filled_on_doc'))
                .fontSize($r('sys.float.ohos_id_navigation_bar_menu_icon_size'))
                .fontColor([TEXT_PRIMARY])
            }
            .width($r('sys.float.ohos_id_button_height'))
            .height($r('sys.float.ohos_id_button_height'))
            .backgroundColor(Color.Transparent)
            .margin({ top: $r('sys.float.ohos_id_elements_margin_vertical_m'), right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
            .onFocus(() => {
              SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
            })
            .onClick(() => {
              SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
              this.copyCode();
            })
          }
          .width('100%')
          .backgroundColor(inputBgOf(this.themeColors))
          .borderRadius(INPUT_BORDER_RADIUS)
        }
        .width('100%')
        .padding(SETTING_ITEM_PADDING)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .backgroundColor(SHEET_CARD_BG)
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
      .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
      .clip(true)

      if (this.error) {
        Text(this.error)
          .fontSize(FONT_SIZE_MIN)
          .fontColor(TEXT_DANGER)
          .width('100%')
          .margin({ top: $r('sys.float.ohos_id_elements_margin_vertical_m') })
      }

      // 底部操作行：删除（仅已有条目，确认弹窗由父级弹）+ 保存；
      // 高度 44 对齐共享 SheetButton 规范，删除走 NORMAL 白卡底、保存走 EMPHASIZED 主题色
      Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
        if (this.canDelete) {
          Button() {
            Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(BUTTON_ICON_SM)
                .fontColor([TEXT_DANGER])
              Text(I18n.t('delete'))
                .fontSize($r('sys.float.ohos_id_text_size_button2'))
                .fontColor(TEXT_DANGER)
            }
            .justifyContent(FlexAlign.Center)
          }
          .type(ButtonType.Capsule)
          .height(SHEET_BUTTON_HEIGHT)
          .role(ButtonRole.ERROR)
          .backgroundColor(listCardBgOf(this.themeColors))
          .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
          .layoutWeight(1)
          .onFocus(() => {
            SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
          })
          .onClick(() => {
            SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
            this.onDelete();
          })
        }
        Button() {
          Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(BUTTON_ICON_SM)
              .fontColor([TEXT_ON_ACCENT])
            Text(I18n.t('save'))
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
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.error = this.onSave();
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

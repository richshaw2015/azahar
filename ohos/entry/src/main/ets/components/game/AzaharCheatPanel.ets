import { AzaharCheatInfo } from '../../types/AzaharNative';
import { AzaharThemeColors } from '../../types/ThemeTypes';
import { ThemeManager } from '../../utils/ThemeManager';
import { ComposeListItem } from '@kit.ArkUI';
import { controlAccentOf, controlThemeOf, immersiveMaterial } from '../common/AzaharControls';
import { settingsGroupDivider, menuGroupPadding } from '../settings/SettingsList';
import {
  CARD_BORDER_COLOR,
  DIALOG_SHADOW,
  FONT_SIZE_MIN,
  FONT_SIZE_SETTING_DESC,
  OVERLAY_MASK,
  RADIUS_LG,
  SHEET_BG,
  SHEET_CONTENT_PADDING,
  TEXT_ON_ACCENT,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { AzaharEmptySlot } from './AzaharEmptySlot';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { listCardBgOf, secondaryButtonBgOf } from '../../utils/ThemeSurfaces';

@Component
export struct AzaharCheatPanel {
  @Prop gameTitle: string = '';
  @Prop titleId: string = '';
  @Prop screenWidth: number = 0;
  @Prop cheats: AzaharCheatInfo[] = [];
  @Prop themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();

  onBack: () => void = () => {};
  onAdd: () => void = () => {};
  onImport: () => void = () => {};
  onRefresh: () => void = () => {};
  onToggle: (cheat: AzaharCheatInfo, enabled: boolean) => void = () => {};
  onViewDetail: (cheat: AzaharCheatInfo) => void = () => {};

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(OVERLAY_MASK)

      Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_l') }) {
        this.Header()
        this.Toolbar()
        this.Content()
      }
      .width(this.screenWidth >= 700 ? 680 : '92%')
      .constraintSize({ maxWidth: 760 })
      .height(this.screenWidth >= 700 ? 520 : '88%')
      .padding(SHEET_CONTENT_PADDING)
      .backgroundColor(SHEET_BG)
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
      .borderRadius(RADIUS_LG)
      .border({ width: '1px', color: CARD_BORDER_COLOR })
      .shadow(DIALOG_SHADOW)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private Header() {
    Row() {
      SymbolGlyph($r('sys.symbol.square_and_pencil'))
        .fontSize($r('sys.float.ohos_id_navigation_bar_menu_icon_size'))
        .fontColor([controlAccentOf(this.themeColors)])
        .margin({ right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
      Column({ space: $r('sys.float.ohos_id_text_paragraph_margin_xs') }) {
        Text(I18n.t('cheats'))
          .fontSize($r('sys.float.ohos_id_text_size_headline8'))
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_PRIMARY)
        Text(this.titleId ? `${this.gameTitle} · ${this.titleId}` : I18n.t('cheat_no_available_title_id'))
          .fontSize(FONT_SIZE_MIN)
          .fontColor(TEXT_SECONDARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button(I18n.t('back'))
        .type(ButtonType.Capsule)
        .height($r('sys.float.ohos_id_button_height'))
        .padding({ left: $r('sys.float.ohos_id_button_horizontal_padding'), right: $r('sys.float.ohos_id_button_horizontal_padding') })
        .fontSize(FONT_SIZE_SETTING_DESC)
        .fontColor(TEXT_PRIMARY)
        .backgroundColor(secondaryButtonBgOf(this.themeColors))
        .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.BACK);
          this.onBack();
        })
    }
    .width('100%')
  }

  @Builder
  private Toolbar() {
    Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
      Button(I18n.t('add'))
        .type(ButtonType.Capsule)
        .height($r('sys.float.ohos_id_button_height'))
        .padding({ left: $r('sys.float.ohos_id_button_horizontal_padding'), right: $r('sys.float.ohos_id_button_horizontal_padding') })
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .fontSize($r('sys.float.ohos_id_text_size_button2'))
        .fontColor(TEXT_ON_ACCENT)
        .backgroundColor(controlAccentOf(this.themeColors))
        .enabled(this.titleId.length > 0)
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.onAdd();
        })
        .layoutWeight(1)
      Button(I18n.t('import_cheat_file'))
        .type(ButtonType.Capsule)
        .height($r('sys.float.ohos_id_button_height'))
        .padding({ left: $r('sys.float.ohos_id_button_horizontal_padding'), right: $r('sys.float.ohos_id_button_horizontal_padding') })
        .fontSize($r('sys.float.ohos_id_text_size_button2'))
        .fontColor(TEXT_PRIMARY)
        .backgroundColor(secondaryButtonBgOf(this.themeColors))
        .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
        .enabled(this.titleId.length > 0)
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.onImport();
        })
        .layoutWeight(1)
      Button(I18n.t('refresh'))
        .type(ButtonType.Capsule)
        .height($r('sys.float.ohos_id_button_height'))
        .padding({ left: $r('sys.float.ohos_id_button_horizontal_padding'), right: $r('sys.float.ohos_id_button_horizontal_padding') })
        .fontSize($r('sys.float.ohos_id_text_size_button2'))
        .fontColor(TEXT_PRIMARY)
        .backgroundColor(secondaryButtonBgOf(this.themeColors))
        .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
        .enabled(this.titleId.length > 0)
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.onRefresh();
        })
        .layoutWeight(1)
    }
    .width('100%')
  }

  @Builder
  private Content() {
    if (!this.titleId || this.cheats.length === 0) {
      // 空态与首页/详情页统一走 AzaharEmptySlot（同图标规格 + body1 标题 + 描述副标题）
      Column() {
        AzaharEmptySlot({
          title: I18n.t('no_cheats'),
          subtitle: this.titleId ? I18n.t('cheat_empty_desc') : I18n.t('cheat_no_title_id_desc')
        })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end') })
    } else {
      // 与游戏详情页金手指 Tab 同一套列表：List + ListItemGroup CARD + ComposeListItem
      List() {
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ForEach(this.cheats, (cheat: AzaharCheatInfo) => {
            ListItem() {
              this.CheatRow(cheat)
            }
          }, (cheat: AzaharCheatInfo) => `${cheat.index}-${cheat.name}`)
        }
        .padding(menuGroupPadding())
        .backgroundColor(listCardBgOf(this.themeColors))
        .divider(settingsGroupDivider())
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
  }

  @Builder
  private CheatRow(cheat: AzaharCheatInfo) {
    WithTheme({ theme: controlThemeOf(this.themeColors) }) {
      ComposeListItem({
        contentItem: {
          primaryText: cheat.name || I18n.t('unnamed_cheat')
        },
        operateItem: {
          switch: {
            isCheck: cheat.enabled,
            onChange: (enabled: boolean) => {
              SoundEffectManager.getInstance().play(enabled ? SoundEffect.TOGGLE_ON : SoundEffect.TOGGLE_OFF);
              this.onToggle(cheat, enabled);
            }
          }
        }
      })
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.onViewDetail(cheat);
        })
    }
  }
}

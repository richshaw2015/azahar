import { image } from '@kit.ImageKit';
import { SettingsList, settingsGroupDivider, menuGroupMargin } from '../SettingsList';
import { GameConfigIcon, GameConfigInfoRow, GameConfigPrimaryAction } from './GameConfigWidgets';
import { AzaharThemeColors } from '../../../types/ThemeTypes';
import { FileManagerHelper } from '../../../utils/FileManagerHelper';
import { formatFileSize } from '../../../utils/FileSizeFormatter';
import { formatLastPlayed } from '../../../utils/PlayTimeManager';
import { I18n } from '../../../utils/I18nManager';
import { SoundEffectManager } from '../../../utils/SoundEffectManager';
import { FONT_SIZE_PAGE_TITLE, NAV_TITLE_SCROLL_SPACE, TEXT_PRIMARY } from '../../../types/UIConstants';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';

@Component
export struct GameConfigDetailsTab {
  scroller: Scroller = new Scroller();
  // PixelMap 不能用 @Prop（深拷贝会破坏 native 绑定），按引用传递
  @Link icon: image.PixelMap | undefined;
  @Prop displayNameText: string;
  @Prop gameIdRegionText: string;
  @Prop playTimeText: string;
  @Prop titleId: string;
  @Prop publisher: string;
  @Prop romPath: string;
  @Prop romSize: number;
  @Prop lastPlayed: number;
  @Prop playCount: number;
  @Prop topSpace: number = NAV_TITLE_SCROLL_SPACE;
  @Prop themeColors: AzaharThemeColors;
  soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  launchGame: () => void = () => {};

  build() {
    SettingsList({ scroller: this.scroller, topSpace: this.topSpace }) {
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_l') }) {
            GameConfigIcon({ icon: this.$icon, iconSize: 156 })
            Text(this.displayNameText)
              .fontSize(FONT_SIZE_PAGE_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor(TEXT_PRIMARY)
              .textAlign(TextAlign.Center)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: $r('sys.float.ohos_id_elements_margin_vertical_l'), bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })
        }
        ListItem() {
          GameConfigPrimaryAction({
            icon: $r('sys.symbol.play_fill'),
            label: I18n.t('start_game'),
            actionEnabled: true,
            themeColors: this.themeColors,
            soundEffectManager: this.soundEffectManager,
            onAction: () => {
              this.launchGame();
            }
          })
        }
      }
      .backgroundColor(listCardBgOf(this.themeColors))
      .margin(menuGroupMargin())

      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          GameConfigInfoRow(I18n.t('game_id_region'), this.gameIdRegionText)
        }
        ListItem() {
          GameConfigInfoRow(I18n.t('title_id'), this.titleId || I18n.t('not_provided'), true)
        }
        ListItem() {
          GameConfigInfoRow(I18n.t('publisher'), this.publisher || I18n.t('not_provided'))
        }
        ListItem() {
          GameConfigInfoRow(I18n.t('core_play_time'), this.playTimeText)
        }
        ListItem() {
          GameConfigInfoRow(I18n.t('last_played'), formatLastPlayed(this.lastPlayed))
        }
        ListItem() {
          GameConfigInfoRow(I18n.t('launch_count'), `${this.playCount}`)
        }
        ListItem() {
          GameConfigInfoRow(I18n.t('rom_size'), formatFileSize(this.romSize))
        }
        ListItem() {
          GameConfigInfoRow(I18n.t('file_location'), FileManagerHelper.getDisplayPath(this.romPath), true)
        }
      }
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
    }
  }
}

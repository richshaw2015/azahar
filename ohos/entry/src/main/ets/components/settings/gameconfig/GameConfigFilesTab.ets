import { SettingsList, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { GameConfigActionRow } from './GameConfigWidgets';
import { I18n } from '../../../utils/I18nManager';
import { SoundEffectManager } from '../../../utils/SoundEffectManager';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { AzaharThemeColors } from '../../../types/ThemeTypes';

// 目录 pattern 的唯一定义处：Tab 行点击、父页存在性检查与副标题展示共用（{high}/{low}/{titleId} 由父页解析）
// sdmc 下 save/update/dlc/extdata 共用此前缀；副标题展示时剥掉它，否则各行前缀相同、截断后无法区分
export const GAME_DIR_SDMC_ROOT_PREFIX =
  'sdmc/Nintendo 3DS/00000000000000000000000000000000/00000000000000000000000000000000/';
export const GAME_DIR_PATTERN_SAVE = `${GAME_DIR_SDMC_ROOT_PREFIX}title/{high}/{low}/data/00000001`;
export const GAME_DIR_PATTERN_UPDATE = `${GAME_DIR_SDMC_ROOT_PREFIX}title/0004000e/{low}/content`;
export const GAME_DIR_PATTERN_DLC = `${GAME_DIR_SDMC_ROOT_PREFIX}title/0004008c/{low}/content`;
export const GAME_DIR_PATTERN_TEXTURES = 'load/textures/{titleId}';
export const GAME_DIR_PATTERN_MODS = 'load/mods/{titleId}';

/** 单游戏配置页 — 文件管理 Tab：对齐 Android Open 菜单的 7 个目录入口 */
@Component
export struct GameConfigFilesTab {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller: Scroller = new Scroller();
  @Prop topSpace: number = 0;
  @Prop titleId: string = '';
  @Prop appDirDisplayPath: string = '';
  // 对齐 Android：模拟器管理目录按真实存在性置灰（纹理/mods 除外，允许自动创建）
  @Prop saveDirExists: boolean = false;
  @Prop updateDirExists: boolean = false;
  @Prop dlcDirExists: boolean = false;
  @Prop extdataDirExists: boolean = false;
  // 各目录行副标题：父页解析后的显示路径（已剥掉共用 sdmc 根前缀）
  @Prop saveDirDisplayPath: string = '';
  @Prop updateDirDisplayPath: string = '';
  @Prop dlcDirDisplayPath: string = '';
  @Prop extdataDirDisplayPath: string = '';
  @Prop textureDirDisplayPath: string = '';
  @Prop modsDirDisplayPath: string = '';
  soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  openAppFolder: () => void = () => {};
  openTitleFolder: (pattern: string, label: string, createIfMissing: boolean) => void = () => {};
  openExtdataFolder: () => void = () => {};

  @Builder
  private ActionRowImpl(title: string, description: string, enabled: boolean, destructive: boolean, onClick: () => void) {
    GameConfigActionRow({
      icon: '', title: title, description: description, actionEnabled: enabled, destructive: destructive,
      soundEffectManager: this.soundEffectManager, onAction: onClick
    })
  }

  build() {
    SettingsList({ scroller: this.scroller, topSpace: this.topSpace }) {
      // 打开目录：对齐 Android Open 菜单顺序（应用 → 存档 → 更新 → DLC → Extra → 纹理 → Mods）
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
              this.ActionRowImpl(I18n.t('application'),
                this.appDirDisplayPath || I18n.t('not_provided'),
                this.appDirDisplayPath.length > 0,
                false,
                () => this.openAppFolder())
        }
        ListItem() {
              this.ActionRowImpl(I18n.t('normal_save'),
                this.saveDirDisplayPath || I18n.t('not_provided'),
                this.saveDirExists,
                false,
                () => this.openTitleFolder(GAME_DIR_PATTERN_SAVE, I18n.t('normal_save_dir'), false))
        }
        ListItem() {
              this.ActionRowImpl(I18n.t('update'),
                this.updateDirDisplayPath || I18n.t('not_provided'),
                this.updateDirExists,
                false,
                () => this.openTitleFolder(GAME_DIR_PATTERN_UPDATE, I18n.t('update_dir'), false))
        }
        ListItem() {
              this.ActionRowImpl(I18n.t('dlc'),
                this.dlcDirDisplayPath || I18n.t('not_provided'),
                this.dlcDirExists,
                false,
                () => this.openTitleFolder(GAME_DIR_PATTERN_DLC, I18n.t('dlc_dir'), false))
        }
        ListItem() {
              this.ActionRowImpl(I18n.t('extradata'),
                this.extdataDirDisplayPath || I18n.t('not_provided'),
                this.extdataDirExists,
                false,
                () => this.openExtdataFolder())
        }
        ListItem() {
              this.ActionRowImpl(I18n.t('texture_packs'),
                this.textureDirDisplayPath || I18n.t('not_provided'),
                this.titleId.length > 0,
                false,
                () => this.openTitleFolder(GAME_DIR_PATTERN_TEXTURES, I18n.t('texture_pack_dir'), true))
        }
        ListItem() {
              this.ActionRowImpl(I18n.t('mods'),
                this.modsDirDisplayPath || I18n.t('not_provided'),
                this.titleId.length > 0,
                false,
                () => this.openTitleFolder(GAME_DIR_PATTERN_MODS, I18n.t('mods_dir'), true))
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())
    }
  }
}

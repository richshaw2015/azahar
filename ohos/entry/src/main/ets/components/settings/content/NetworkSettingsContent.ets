import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { SettingsList, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { ButtonSettingItem } from '../ButtonSettingItem';
import { TextInputSettingItem } from '../TextInputSettingItem';
import { AzaharNative } from '../../../types/AzaharNative';
import { KEY_CITRA_TOKEN, KEY_LAST_ARTIC_BASE_ADDR, KEY_WEB_API_URL } from '../../../types/SettingsTypes';
import {
  RADIUS_SHEET,
  SHEET_BG_GROUPED,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING
} from '../../../types/UIConstants';
import { immersiveMaterial } from '../../common/AzaharControls';
import { MultiplayerSheets, SheetButton, SheetTitleBar } from '../../common/MultiplayerSheets';
import { I18n } from '../../../utils/I18nManager';
import { SettingsManager } from '../../../utils/SettingsManager';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { showErrorToast } from '../../../utils/ToastHelper';
import { SoundEffect, SoundEffectManager } from '../../../utils/SoundEffectManager';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { AzaharThemeColors } from '../../../types/ThemeTypes';

const DEFAULT_WEB_API_URL: string = 'https://api.citra-emu.org';
const DEFAULT_ARTIC_PORT: number = 5543;

@Component
export struct NetworkSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  @State webApiUrl: string = DEFAULT_WEB_API_URL;
  @State networkToken: string = '';
  @State showMultiplayerSheet: boolean = false;
  @State showArticSheet: boolean = false;
  @State articAddrText: string = '';

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private themeManager: ThemeManager = ThemeManager.getInstance();

  async aboutToAppear(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    await this.themeManager.initialize(this.context);
    this.webApiUrl = this.settingsManager.getString(KEY_WEB_API_URL) || DEFAULT_WEB_API_URL;
    this.networkToken = this.settingsManager.getString(KEY_CITRA_TOKEN);
  }

  private async updateString(key: string, value: string): Promise<void> {
    await this.settingsManager.setString(key, value);
    AzaharNative.applyConfig();
  }

  private openArticSheet(): void {
    this.articAddrText = this.settingsManager.getString(KEY_LAST_ARTIC_BASE_ADDR);
    this.showArticSheet = true;
  }

  private confirmArtic(): void {
    const addr = this.articAddrText.trim();
    if (addr.length === 0) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('artic_base_addr_required'));
      return;
    }
    const path = addr.includes('://') ? addr : `articbase://${addr}`;
    void this.settingsManager.setString(KEY_LAST_ARTIC_BASE_ADDR, addr);
    this.showArticSheet = false;
    router.pushUrl({
      url: 'pages/GameView',
      params: { romPath: path }
    }).catch((error: Error) => {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('open_failed_fmt', 'error', error.message));
    });
  }

  // 对齐 Android「连接到 Artic Base」地址输入弹窗
  @Builder
  ArticSheet() {
    Column() {
      SheetTitleBar(I18n.t('artic_base_enter_address'), () => {
        this.showArticSheet = false;
      })
      Column() {
        TextInputSettingItem({
          title: I18n.t('artic_base_addr'),
          description: I18n.t('artic_base_addr_desc'),
          value: this.articAddrText,
          placeholder: `192.168.1.10:${DEFAULT_ARTIC_PORT}`,
          maxLength: 160,
          showCounter: false,
          onChange: (value: string) => {
            this.articAddrText = value;
          }
        })
      }
      .width('100%')
      .backgroundColor(SHEET_CARD_BG)
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
      .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
      .clip(true)

      Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
        SheetButton(I18n.t('cancel'), false, true, this.themeManager.getControlAccent(), () => {
          this.showArticSheet = false;
        })
        SheetButton(I18n.t('connect'), true, this.articAddrText.trim().length > 0,
          this.themeManager.getControlAccent(), () => {
            this.confirmArtic();
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

  build() {
    Stack() {
      SettingsList({ scroller: this.scroller }) {
        // 联机大厅服务配置：房间列表/开房登记走该 API，身份令牌可留空匿名（对齐 Android 网络设置页）
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            TextInputSettingItem({
              title: I18n.t('web_api_url'),
              description: I18n.t('web_api_url_desc'),
              value: this.webApiUrl,
              placeholder: DEFAULT_WEB_API_URL,
              maxLength: 160,
              showCounter: false,
              onChange: (value: string) => {
                this.webApiUrl = value;
                void this.updateString(KEY_WEB_API_URL, value.trim() || DEFAULT_WEB_API_URL);
              }
            })
          }
          ListItem() {
            TextInputSettingItem({
              title: I18n.t('network_token'),
              description: I18n.t('network_token_desc'),
              value: this.networkToken,
              placeholder: I18n.t('optional_empty'),
              maxLength: 160,
              showCounter: false,
              onChange: (value: string) => {
                this.networkToken = value;
                void this.updateString(KEY_CITRA_TOKEN, value.trim());
              }
            })
          }
        }
        .padding(menuGroupPadding())
        .backgroundColor(listCardBgOf(this.themeColors))
        .divider(settingsGroupDivider())
        .margin(menuGroupMargin())

        // 联机功能入口：多人联机菜单 + Artic Base 地址弹窗（对齐 Android 首页两项的弹窗交互）
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            ButtonSettingItem({
              title: I18n.t('multiplayer'),
              description: I18n.t('multiplayer_description'),
              onItemClick: () => {
                this.showMultiplayerSheet = true;
              }
            })
          }
          ListItem() {
            ButtonSettingItem({
              title: I18n.t('artic_base_connect'),
              description: I18n.t('artic_base_connect_desc'),
              onItemClick: () => {
                this.openArticSheet();
              }
            })
          }
        }
        .padding(menuGroupPadding())
        .backgroundColor(listCardBgOf(this.themeColors))
        .divider(settingsGroupDivider())
        .margin(menuGroupMargin())
      }

      // 联机弹窗组（入口/加入/创建/大厅），与游戏暂停菜单共用同一组件
      MultiplayerSheets({ showMultiplayerSheet: this.$showMultiplayerSheet })

      Column()
        .bindSheet($$this.showArticSheet, this.ArticSheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
        })
    }
    .width('100%')
    .height('100%')
  }
}

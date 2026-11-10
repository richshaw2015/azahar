import { common } from '@kit.AbilityKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { ComposeListItem, IconType, SymbolGlyphModifier } from '@kit.ArkUI';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { TextInputSettingItem } from '../settings/TextInputSettingItem';
import { SliderSettingItem } from '../settings/SliderSettingItem';
import { SelectSettingItem } from '../settings/SelectSettingItem';
import { AzaharMultiplayerRoomInfo, AzaharNative, AzaharNetPlayStatus } from '../../types/AzaharNative';
import { KEY_MULTIPLAYER_ROOM_ADDRESS, KEY_MULTIPLAYER_ROOM_PASSWORD, KEY_MULTIPLAYER_ROOM_PORT, SettingOption } from '../../types/SettingsTypes';
import {
  BUTTON_BG_SECONDARY,
  RADIUS_SHEET,
  SHEET_BG_GROUPED,
  SHEET_BUTTON_HEIGHT,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING,
  TEXT_DANGER,
  TEXT_ON_ACCENT,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';
import { immersiveMaterial } from './AzaharControls';
import { AzaharEmptySlot } from '../game/AzaharEmptySlot';
import { I18n } from '../../utils/I18nManager';
import { LanDiscoveryManager } from '../../utils/LanDiscoveryManager';
import { SettingsManager } from '../../utils/SettingsManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { ThemeManager } from '../../utils/ThemeManager';
import { showErrorToast, showInfoToast, showSuccessToast } from '../../utils/ToastHelper';
import { secondaryButtonBgOf } from '../../utils/ThemeSurfaces';

const DEFAULT_ROOM_PORT: number = 24872;
const MIN_ROOM_PLAYERS: number = 2;
const MAX_ROOM_PLAYERS: number = 16;

function localIpAddress(): string {
  try {
    const ipInfo = wifiManager.getIpInfo();
    if (ipInfo && ipInfo.ipAddress) {
      const ip = ipInfo.ipAddress;
      return `${(ip >> 24) & 0xff}.${(ip >> 16) & 0xff}.${(ip >> 8) & 0xff}.${ip & 0xff}`;
    }
  } catch (_e) {
  }
  return '0.0.0.0';
}

function netPlayErrorText(code: number): string {
  switch (code) {
    case AzaharNetPlayStatus.WrongPassword:
      return I18n.t('netplay_error_wrong_password');
    case AzaharNetPlayStatus.CouldNotConnect:
      return I18n.t('netplay_error_could_not_connect');
    case AzaharNetPlayStatus.RoomIsFull:
      return I18n.t('netplay_error_room_full');
    case AzaharNetPlayStatus.AlreadyInRoom:
      return I18n.t('netplay_error_already');
    case AzaharNetPlayStatus.CreateRoomError:
      return I18n.t('netplay_error_create');
    case AzaharNetPlayStatus.NameCollision:
      return I18n.t('netplay_error_name_collision');
    default:
      return I18n.tf1('netplay_error_generic_fmt', 'code', code);
  }
}

function isValidPort(value: number): boolean {
  return Number.isFinite(value) && value >= 1 && value <= 65535 && Math.floor(value) === value;
}

/** Sheet 标题栏 + 关闭按钮（联机弹窗与 Artic 弹窗共用） */
@Builder
export function SheetTitleBar(title: string, onClose: () => void) {
  Row() {
    Text(title)
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
      onClose();
    })
  }
  .width('100%')
  .margin({ bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })
}

/** Sheet 白卡内行间的发丝分隔线（与设置页 settingsGroupDivider 同规格：1px + list_separator + 左缩进 16vp） */
@Builder
export function SheetRowDivider() {
  Divider()
    .strokeWidth('1px')
    .color($r('sys.color.ohos_id_color_list_separator'))
    .margin({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
}

/** Sheet 白卡操作行：24vp 系统图标槽 symbol + 主文本，danger 行图标与文本走警告色。
 *  各弹窗操作菜单统一走这里（存档详情/布局编辑菜单/联机等），不要各写各的 ComposeListItem 配置。 */
@Builder
export function SheetActionRow(icon: Resource, title: string, danger: boolean, onClick: () => void) {
  ComposeListItem({
    contentItem: {
      iconStyle: IconType.SYSTEM_ICON,
      symbolStyle: new SymbolGlyphModifier(icon).fontColor([danger ? TEXT_DANGER : TEXT_PRIMARY]),
      primaryText: title
    }
  })
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      SoundEffectManager.getInstance().play(danger ? SoundEffect.CONFIRM : SoundEffect.DECIDE);
      onClick();
    })
}

/** Sheet 底部确认/取消按钮（强调色由调用方传入） */
@Builder
export function SheetButton(label: string, primary: boolean, enabled: boolean, accent: ResourceColor,
  onClick: () => void) {
  Button(label)
    .type(ButtonType.Capsule)
    // 与其他 sheet 底部确认按钮一致的全尺寸高度（LayoutEditorSheets 同款）
    .height(SHEET_BUTTON_HEIGHT)
    .buttonStyle(primary ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
    .fontSize($r('sys.float.ohos_id_text_size_button2'))
    .fontColor(primary ? TEXT_ON_ACCENT : TEXT_PRIMARY)
    .backgroundColor(primary ? accent : secondaryButtonBgOf(ThemeManager.getInstance().getCurrentColors()))
    .systemMaterial(primary ? undefined : immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
    .enabled(enabled)
    .layoutWeight(1)
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      SoundEffectManager.getInstance().play(primary ? SoundEffect.DECIDE : SoundEffect.BACK);
      onClick();
    })
}

/** 多人联机底部弹窗组（对齐 Android NetPlayDialog/LobbyBrowser）：
 *  入口菜单（加入/创建/浏览公共房间）→ 各表单弹窗。自身无可见内容，
 *  父组件把 showMultiplayerSheet 置 true 即弹出入口菜单。 */
@Component
export struct MultiplayerSheets {
  /** 入口弹窗开关：父组件绑定的状态，置 true 弹出 */
  @Link showMultiplayerSheet: boolean;
  @State private showJoinSheet: boolean = false;
  @State private showCreateSheet: boolean = false;
  @State private showLobbySheet: boolean = false;
  @State private lobbyRooms: AzaharMultiplayerRoomInfo[] = [];
  // 局域网发现的房间（UDP 广播），与公共大厅合并展示、排在前部
  @State private lanRooms: AzaharMultiplayerRoomInfo[] = [];
  private lanDiscovery: LanDiscoveryManager = LanDiscoveryManager.getInstance();
  @State private isRefreshingRooms: boolean = false;
  @State private joinAddress: string = '';
  @State private joinPortText: string = `${DEFAULT_ROOM_PORT}`;
  @State private joinPassword: string = '';
  @State private createPortText: string = `${DEFAULT_ROOM_PORT}`;
  @State private createRoomName: string = '';
  @State private createPassword: string = '';
  @State private createMaxPlayers: number = MAX_ROOM_PLAYERS;
  @State private createGameIndex: number = 0;
  @State private createGameOptions: SettingOption[] = [{ value: -1, label: I18n.t('no_preference') }];
  @State private joinBusy: boolean = false;
  // 加入/建房弹窗展示的只读用户名（Android NetPlayDialog 同款：取自系统资料，点击提示去系统设置改）
  @State private systemUsername: string = '';

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private themeManager: ThemeManager = ThemeManager.getInstance();

  async aboutToAppear(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    await this.themeManager.initialize(this.context);
  }

  aboutToDisappear(): void {
    // 组件随游戏页销毁：房间生命周期结束，停止 LAN 通告/监听
    this.lanDiscovery.stopAdvertise();
    this.lanDiscovery.stopDiscovery();
  }

  private openJoinSheet(): void {
    this.showMultiplayerSheet = false;
    this.systemUsername = this.readSystemUsername();
    this.joinAddress = this.settingsManager.getString(KEY_MULTIPLAYER_ROOM_ADDRESS);
    this.joinPortText = `${this.settingsManager.getNumber(KEY_MULTIPLAYER_ROOM_PORT) || DEFAULT_ROOM_PORT}`;
    this.joinPassword = this.settingsManager.getString(KEY_MULTIPLAYER_ROOM_PASSWORD);
    this.showJoinSheet = true;
  }

  private openCreateSheet(): void {
    this.showMultiplayerSheet = false;
    this.systemUsername = this.readSystemUsername();
    this.createPortText = `${this.settingsManager.getNumber(KEY_MULTIPLAYER_ROOM_PORT) || DEFAULT_ROOM_PORT}`;
    this.createRoomName = '';
    this.createPassword = this.settingsManager.getString(KEY_MULTIPLAYER_ROOM_PASSWORD);
    this.createGameIndex = 0;
    this.loadCreateGameOptions();
    this.showCreateSheet = true;
  }

  private openLobbySheet(): void {
    this.showMultiplayerSheet = false;
    this.showLobbySheet = true;
    this.lanDiscovery.startDiscovery((rooms: AzaharMultiplayerRoomInfo[]) => {
      this.lanRooms = rooms;
    });
    this.refreshLobby();
  }

  // LAN 发现的房间排在公共列表前，便于同网段直连
  private allLobbyRooms(): AzaharMultiplayerRoomInfo[] {
    return this.lanRooms.concat(this.lobbyRooms);
  }

  // 已安装游戏元数据 → 偏好游戏下拉
  private loadCreateGameOptions(): void {
    const options: SettingOption[] = [{ value: -1, label: I18n.t('no_preference') }];
    try {
      const seen: string[] = [];
      for (const path of AzaharNative.getInstalledGamePaths()) {
        const metadata = AzaharNative.getGameMetadata(path);
        if (!metadata.valid || !metadata.titleId || seen.includes(metadata.titleId)) {
          continue;
        }
        seen.push(metadata.titleId);
        const id = Number.parseInt(metadata.titleId, 16);
        if (!Number.isNaN(id)) {
          options.push({ value: id, label: metadata.longTitle || metadata.shortTitle || metadata.titleId });
        }
      }
    } catch (error) {
      console.warn(`Unable to load create-room game options: ${(error as Error).message}`);
    }
    this.createGameOptions = options;
  }

  // 联机用户名取自 3DS 系统资料（cfg 存档），与 Android SystemSaveGame.getUsername 同源；
  // 系统资料不可用时按空处理，走校验失败路径
  private readSystemUsername(): string {
    try {
      const profile = AzaharNative.getSystemProfile();
      return profile.available ? profile.username.trim() : '';
    } catch (error) {
      console.warn(`Unable to read system profile username: ${(error as Error).message}`);
      return '';
    }
  }

  private checkedNickname(): string | null {
    // 对齐 Android：charset/长度同 NetPlayManager.usernameRegex，加入/建房再要求至少 5 字符
    const name = this.readSystemUsername();
    if (!/^[a-zA-Z0-9._\- ]{4,20}$/.test(name)) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('username_invalid'));
      return null;
    }
    if (name.length < 5) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('multiplayer_nickname_too_short'));
      return null;
    }
    return name;
  }

  private doJoin(): void {
    const port = Number(this.joinPortText);
    if (!isValidPort(port)) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('multiplayer_port_invalid'));
      return;
    }
    if (this.joinAddress.trim().length < 7) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('multiplayer_address_invalid'));
      return;
    }
    const nickname = this.checkedNickname();
    if (!nickname || this.joinBusy) {
      return;
    }
    this.joinBusy = true;
    try {
      void this.settingsManager.setString(KEY_MULTIPLAYER_ROOM_ADDRESS, this.joinAddress.trim());
      void this.settingsManager.setNumber(KEY_MULTIPLAYER_ROOM_PORT, port);
      void this.settingsManager.setString(KEY_MULTIPLAYER_ROOM_PASSWORD, this.joinPassword);
      const status = AzaharNative.multiplayerJoinRoom(this.joinAddress.trim(), port, nickname, this.joinPassword);
      if (status === AzaharNetPlayStatus.NoError) {
        SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
        showSuccessToast(I18n.t('multiplayer_join_success'));
        this.showJoinSheet = false;
      } else {
        SoundEffectManager.getInstance().play(SoundEffect.FAIL);
        showErrorToast(netPlayErrorText(status));
      }
    } finally {
      this.joinBusy = false;
    }
  }

  private doCreate(): void {
    const port = Number(this.createPortText);
    if (!isValidPort(port)) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('multiplayer_port_invalid'));
      return;
    }
    const nickname = this.checkedNickname();
    if (!nickname || this.joinBusy) {
      return;
    }
    const roomName = this.createRoomName.trim() || `${nickname}'s room`;
    if (roomName.length < 3 || roomName.length > 20) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('multiplayer_room_name_invalid'));
      return;
    }
    this.joinBusy = true;
    try {
      void this.settingsManager.setNumber(KEY_MULTIPLAYER_ROOM_PORT, port);
      void this.settingsManager.setString(KEY_MULTIPLAYER_ROOM_PASSWORD, this.createPassword);
      const selectedGame = this.createGameOptions[this.createGameIndex];
      const gameId = selectedGame && typeof selectedGame.value === 'number' ? selectedGame.value : -1;
      const gameName = gameId < 0 ? '' : (selectedGame?.label || '');
      // 与 Android 一致：建房固定绑定本机 Wi-Fi 地址，不复用上次直连的远端地址
      const status = AzaharNative.multiplayerCreateRoom(localIpAddress(), port, nickname, gameName,
        gameId, this.createPassword, roomName, this.createMaxPlayers);
      if (status === AzaharNetPlayStatus.NoError) {
        SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
        showSuccessToast(I18n.t('multiplayer_create_success'));
        this.showCreateSheet = false;
        // 建房成功后开始局域网广播，同网段设备在大厅列表可直接看到
        this.lanDiscovery.startAdvertise(roomName, port, gameName, 1,
          this.createMaxPlayers, this.createPassword.length > 0);
      } else {
        SoundEffectManager.getInstance().play(SoundEffect.FAIL);
        showErrorToast(netPlayErrorText(status));
      }
    } finally {
      this.joinBusy = false;
    }
  }

  // 拉取公共房间列表（对齐 Android LobbyBrowser；用当前 Web API URL/令牌配置）
  private refreshLobby(): void {
    if (this.isRefreshingRooms) {
      return;
    }
    this.isRefreshingRooms = true;
    try {
      AzaharNative.applyConfig();
      this.lobbyRooms = AzaharNative.getMultiplayerRooms();
    } catch (error) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('multiplayer_lobby_refresh_failed_fmt', 'error', (error as Error).message));
    } finally {
      this.isRefreshingRooms = false;
    }
  }

  private joinLobbyRoom(room: AzaharMultiplayerRoomInfo): void {
    if (room.hasPassword) {
      // 密码房：回填加入表单让用户补密码
      this.joinAddress = room.address;
      this.joinPortText = `${room.port || DEFAULT_ROOM_PORT}`;
      this.joinPassword = '';
      this.showLobbySheet = false;
      this.showJoinSheet = true;
      return;
    }
    const nickname = this.checkedNickname();
    if (!nickname || this.joinBusy) {
      return;
    }
    this.joinBusy = true;
    try {
      void this.settingsManager.setString(KEY_MULTIPLAYER_ROOM_ADDRESS, room.address);
      void this.settingsManager.setNumber(KEY_MULTIPLAYER_ROOM_PORT, room.port || DEFAULT_ROOM_PORT);
      void this.settingsManager.setString(KEY_MULTIPLAYER_ROOM_PASSWORD, '');
      const status = AzaharNative.multiplayerJoinRoom(room.address, room.port || DEFAULT_ROOM_PORT, nickname, '');
      if (status === AzaharNetPlayStatus.NoError) {
        SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
        showSuccessToast(I18n.t('multiplayer_join_success'));
        this.showLobbySheet = false;
      } else {
        SoundEffectManager.getInstance().play(SoundEffect.FAIL);
        showErrorToast(netPlayErrorText(status));
      }
    } finally {
      this.joinBusy = false;
    }
  }

  // 对齐 Android NetPlayDialog 未加入房间时的三个入口
  @Builder
  MultiplayerSheet() {
    Column() {
      SheetTitleBar(I18n.t('multiplayer'), () => {
        this.showMultiplayerSheet = false;
      })
      Column({ space: 0 }) {
        ComposeListItem({
          contentItem: { primaryText: I18n.t('multiplayer_join_room') },
          operateItem: { arrow: { value: $r('sys.symbol.chevron_right'), action: () => { this.openJoinSheet(); } } }
        })
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.openJoinSheet();
        })
        SheetRowDivider()
        ComposeListItem({
          contentItem: { primaryText: I18n.t('multiplayer_create_room') },
          operateItem: { arrow: { value: $r('sys.symbol.chevron_right'), action: () => { this.openCreateSheet(); } } }
        })
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.openCreateSheet();
        })
        SheetRowDivider()
        ComposeListItem({
          contentItem: { primaryText: I18n.t('multiplayer_browse_lobby') },
          operateItem: { arrow: { value: $r('sys.symbol.chevron_right'), action: () => { this.openLobbySheet(); } } }
        })
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.openLobbySheet();
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

  // 对齐 Android showNetPlayInputDialog(isCreate=false)：地址/端口/密码
  @Builder
  JoinSheet() {
    Column() {
      SheetTitleBar(I18n.t('multiplayer_join_room'), () => {
        this.showJoinSheet = false;
      })
      Column({ space: 0 }) {
        ComposeListItem({
          contentItem: { primaryText: I18n.t('username') },
          operateItem: { text: this.systemUsername }
        })
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          showInfoToast(I18n.t('username_uses_system'));
        })
        SheetRowDivider()
        TextInputSettingItem({
          title: I18n.t('address'),
          value: this.joinAddress,
          placeholder: '192.168.1.10',
          maxLength: 160,
          showCounter: false,
          onChange: (value: string) => {
            this.joinAddress = value;
          }
        })
        SheetRowDivider()
        TextInputSettingItem({
          title: I18n.t('port'),
          value: this.joinPortText,
          placeholder: `${DEFAULT_ROOM_PORT}`,
          maxLength: 5,
          showCounter: false,
          onChange: (value: string) => {
            this.joinPortText = value;
          }
        })
        SheetRowDivider()
        TextInputSettingItem({
          title: I18n.t('password'),
          value: this.joinPassword,
          placeholder: I18n.t('multiplayer_open_room_optional'),
          maxLength: 160,
          showCounter: false,
          onChange: (value: string) => {
            this.joinPassword = value;
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
          this.showJoinSheet = false;
        })
        SheetButton(I18n.t('multiplayer_join'), true, !this.joinBusy, this.themeManager.getControlAccent(), () => {
          this.doJoin();
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

  // 对齐 Android showNetPlayInputDialog(isCreate=true)：房间名/端口/密码/最大玩家
  @Builder
  CreateSheet() {
    Column() {
      SheetTitleBar(I18n.t('multiplayer_create_room'), () => {
        this.showCreateSheet = false;
      })
      Column({ space: 0 }) {
        ComposeListItem({
          contentItem: { primaryText: I18n.t('username') },
          operateItem: { text: this.systemUsername }
        })
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          showInfoToast(I18n.t('username_uses_system'));
        })
        SheetRowDivider()
        TextInputSettingItem({
          title: I18n.t('multiplayer_room_name'),
          value: this.createRoomName,
          placeholder: I18n.t('multiplayer_room_name_placeholder'),
          maxLength: 20,
          showCounter: false,
          onChange: (value: string) => {
            this.createRoomName = value;
          }
        })
        SheetRowDivider()
        TextInputSettingItem({
          title: I18n.t('port'),
          value: this.createPortText,
          placeholder: `${DEFAULT_ROOM_PORT}`,
          maxLength: 5,
          showCounter: false,
          onChange: (value: string) => {
            this.createPortText = value;
          }
        })
        SheetRowDivider()
        TextInputSettingItem({
          title: I18n.t('password'),
          value: this.createPassword,
          placeholder: I18n.t('multiplayer_open_room_optional'),
          maxLength: 160,
          showCounter: false,
          onChange: (value: string) => {
            this.createPassword = value;
          }
        })
        SheetRowDivider()
        SelectSettingItem({
          title: I18n.t('multiplayer_preferred_game'),
          options: this.createGameOptions,
          selectedIndex: this.createGameIndex,
          onSelect: (index: number) => {
            this.createGameIndex = index;
          }
        })
        SheetRowDivider()
        SliderSettingItem({
          title: I18n.t('multiplayer_max_players'),
          value: this.createMaxPlayers,
          min: MIN_ROOM_PLAYERS,
          max: MAX_ROOM_PLAYERS,
          step: 1,
          onChange: (value: number) => {
            this.createMaxPlayers = Math.round(value);
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
          this.showCreateSheet = false;
        })
        SheetButton(I18n.t('multiplayer_create_room'), true, !this.joinBusy, this.themeManager.getControlAccent(), () => {
          this.doCreate();
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

  // 对齐 Android LobbyBrowser 底部面板：公共房间列表 / 空态文案 / 刷新按钮
  @Builder
  LobbySheet() {
    Column() {
      SheetTitleBar(I18n.t('multiplayer_browse_lobby'), () => {
        this.showLobbySheet = false;
      })
      Scroll() {
        Column({ space: 0 }) {
          if (this.allLobbyRooms().length === 0) {
            Column() {
              AzaharEmptySlot({
                title: I18n.t('multiplayer_no_public_rooms')
              })
            }
            .width('100%')
            .height(170)
            .justifyContent(FlexAlign.Center)
          }
          ForEach(this.allLobbyRooms(), (room: AzaharMultiplayerRoomInfo, index: number) => {
            if (index > 0) {
              SheetRowDivider()
            }
            ComposeListItem({
              contentItem: {
                primaryText: room.name || I18n.t('multiplayer_unnamed_room'),
                secondaryText: `${room.address}:${room.port} · ${room.memberCount}/${room.maxPlayers}${room.hasPassword ? ' · ' + I18n.t('password') : ''}${room.id.startsWith('lan_') ? ' · LAN' : ''}`
              }
            })
            .onFocus(() => {
              SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
            })
            .onClick(() => {
              SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
              this.joinLobbyRoom(room);
            })
          }, (room: AzaharMultiplayerRoomInfo) => room.id || `${room.address}:${room.port}:${room.name}`)
        }
      }
      .width('100%')
      .constraintSize({ maxHeight: 320 })
      .backgroundColor(SHEET_CARD_BG)
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
      .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
      .clip(true)

      Row() {
        SheetButton(I18n.t('refresh_lobby'), true, !this.isRefreshingRooms, this.themeManager.getControlAccent(), () => {
          this.refreshLobby();
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
    // bindSheet 同一组件只能挂一个：各弹窗各挂一个空 Column 兄弟节点
    Column() {
      Column()
        .bindSheet($$this.showMultiplayerSheet, this.MultiplayerSheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
        })
      Column()
        .bindSheet($$this.showJoinSheet, this.JoinSheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
        })
      Column()
        .bindSheet($$this.showLobbySheet, this.LobbySheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK),
          onDisappear: () => {
            this.lanDiscovery.stopDiscovery();
          }
        })
      Column()
        .bindSheet($$this.showCreateSheet, this.CreateSheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
        })
    }
    .width(0)
    .height(0)
  }
}

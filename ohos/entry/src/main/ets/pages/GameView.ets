import { router, window, display } from '@kit.ArkUI';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { inputDevice } from '@kit.InputKit';
import { deviceInfo, settings } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KEY_DISABLE_GESTURE_BACK_IN_GAME, KEY_PRIVACY_MODE_IN_GAME } from '../types/SettingsTypes';
import { AzaharFrontendAction, AzaharVirtualButtonLayer } from '../components/game/AzaharVirtualButtonLayer';
import { GameViewHud } from '../components/game/GameViewHud';
import { GameViewQuickActions, ORIENTATION_VALUES } from '../components/game/GameViewQuickActions';
import { GameViewOverlays } from '../components/game/GameViewOverlays';
import { GameViewPanels } from '../components/game/GameViewPanels';
import { computePadLayout, DEFAULT_PAD_VISIBILITY, PadLayout, PadRect, PadSizes } from '../utils/VirtualPadLayout';
import { AzaharLoadingDialog } from '../components/common/AzaharLoadingDialog';
import { getOverlayControlSizes } from '../utils/OverlayThemeHelper';
import { immersiveMaterial, controlAccentOf } from '../components/common/AzaharControls';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { AzaharAnalog, AzaharCheatInfo, AzaharCoreError, AzaharGameMetadata, AzaharKey, AzaharLoadResult, AzaharMovieStatus, AzaharNative, AzaharSaveStateInfo, AzaharSaveStateStatus, QUICK_SAVE_STATE_SLOT } from '../types/AzaharNative';
import { AzaharThemeColors } from '../types/ThemeTypes';
import { BUTTON_PRESS_OFFSET, HAIRLINE_COLOR, OVERLAY_MASK, PAGE_BG, RADIUS_MD, SURFACE_CARD, TEXT_DANGER, TEXT_ON_ACCENT, TEXT_PRIMARY, TEXT_SECONDARY, BUTTON_BG_SECONDARY, FONT_SIZE_SETTING_DESC } from '../types/UIConstants';
import { BackgroundMusicManager } from '../utils/BackgroundMusicManager';
import { CheatsSeed } from '../utils/CheatsSeed';
import { DeviceProfile } from '../utils/DeviceProfile';
import { DownloadDirManager } from '../utils/DownloadDirManager';
import { FileManagerHelper } from '../utils/FileManagerHelper';
import { GameConfigManager } from '../utils/GameConfigManager';
import { image } from '@kit.ImageKit';
import { GameManager, GameInfo } from '../utils/GameManager';
import { I18n } from '../utils/I18nManager';
import { PAGE_TRANSITION_DURATION } from '../utils/PageTransitionHelper';
import { PersistedUriManager } from '../utils/PersistedUriManager';
import { PlayTimeManager } from '../utils/PlayTimeManager';
import { KeyboardBindingManager } from '../utils/KeyboardBindingManager';
import { SettingsManager } from '../utils/SettingsManager';
import { LayoutConfigManager } from '../utils/LayoutConfigManager';
import { LayoutComponent, LayoutConfiguration, PositionedLayoutComponent } from '../types/LayoutTypes';
import { HapticManager } from '../utils/HapticManager';
import { SoundEffect, SoundEffectManager } from '../utils/SoundEffectManager';
import { ThemeManager } from '../utils/ThemeManager';
import { initToastHelper, showErrorToast, showSuccessToast, showWarningToast } from '../utils/ToastHelper';
import { WidgetService } from '../utils/WidgetService';
import { DEFAULT_SAVE_STATE_SLOT_COUNT, KEY_AUDIO_INPUT_TYPE, KEY_CONTROL_OPACITY, KEY_GAMEPAD_HOTKEY_MAP, KEY_IGNORE_SAFE_AREA, KEY_LAYOUT_OPTION, KEY_LOCK_GAME_BRIGHTNESS, KEY_PERFORMANCE_OVERLAY_ENABLE, KEY_PERFORMANCE_OVERLAY_POSITION, KEY_RESOLUTION_FACTOR, KEY_SAVE_STATE_SLOT_COUNT, KEY_SCREEN_ORIENTATION, KEY_SOFT_INPUT_BEHAVIOUR, KEY_TURBO_LIMIT, KEY_UPRIGHT_SCREEN } from '../types/SettingsTypes';

interface GestureBackWindow {
  setGestureBackEnabled(enabled: boolean): Promise<void>;
}

interface PhysicalKeyBinding {
  keyCode: number;
  key: AzaharKey;
}

// 输入来源标识：物理键盘/手柄事件直接用 event.keyCode（≥2000），虚拟按键层与宏各用独立伪源
const VIRTUAL_KEY_SOURCE: number = 30000;
const MACRO_KEY_SOURCE: number = 30001;

const GAMEPAD_KEY_BINDINGS: PhysicalKeyBinding[] = [
  { keyCode: 2301, key: AzaharKey.A },
  { keyCode: 2302, key: AzaharKey.B },
  { keyCode: 2304, key: AzaharKey.X },
  { keyCode: 2305, key: AzaharKey.Y },
  { keyCode: 2307, key: AzaharKey.L },
  { keyCode: 2308, key: AzaharKey.R },
  { keyCode: 2309, key: AzaharKey.ZL },
  { keyCode: 2310, key: AzaharKey.ZR },
  { keyCode: 2312, key: AzaharKey.Start },
  { keyCode: 2311, key: AzaharKey.Select },
  { keyCode: 2012, key: AzaharKey.Up },
  { keyCode: 2013, key: AzaharKey.Down },
  { keyCode: 2014, key: AzaharKey.Left },
  { keyCode: 2015, key: AzaharKey.Right }
];

const ALL_DIGITAL_KEYS: AzaharKey[] = [
  AzaharKey.A,
  AzaharKey.B,
  AzaharKey.X,
  AzaharKey.Y,
  AzaharKey.Up,
  AzaharKey.Down,
  AzaharKey.Left,
  AzaharKey.Right,
  AzaharKey.L,
  AzaharKey.R,
  AzaharKey.Start,
  AzaharKey.Select,
  AzaharKey.ZL,
  AzaharKey.ZR
];

const GAMEPAD_DPAD_KEY_CODES: number[] = [2012, 2013, 2014, 2015];
const PERF_STATS_GAME_FPS: number = 1;
// 慢速挡位：帧率按全速百分比限速（对齐 nds 慢速=半速语义）
const SLOW_MOTION_PERCENT: number = 50;
// native input_type 枚举（audio_core InputType）：0=自动 1=无 6=设备麦克风
const MIC_INPUT_TYPE_AUTO: number = 0;
const MIC_INPUT_TYPE_NULL: number = 1;
const MIC_INPUT_TYPE_OHOS: number = 6;
// APT 睡眠协商状态（core SleepState）：0=醒着 1=询问中 2=准备中 3=睡眠中
const LID_SLEEP_STATE_AWAKE: number = 0;
const LID_SLEEP_STATE_ASLEEP: number = 3;
const LID_SLEEP_WATCH_INTERVAL_MS: number = 120;
// 协商兜底：超时仍按睡眠处理（真机对超时未应答同样强制入睡）
const LID_SLEEP_WATCH_MAX_TICKS: number = 42;

interface GameViewParams {
  romPath?: string;
  movieMode?: string;
  moviePath?: string;
  movieAuthor?: string;
  movieReadOnly?: boolean;
}

@Entry
@Component
struct GameView {
  @State romPath: string = '';
  @State gameTitle: string = '';
  @State gameTitleId: string = '';
  @State statusText: string = I18n.t('game_status_prepare_start');
  /** 游戏打开期间的加载遮罩：模拟器 startEmulation 成功或加载失败时关闭 */
  @State isLoadingGame: boolean = true;
  @State isPaused: boolean = false;
  @State surfaceReady: boolean = false;
  @State circlePadOffsetX: number = 0;
  @State circlePadOffsetY: number = 0;
  @State cStickOffsetX: number = 0;
  @State cStickOffsetY: number = 0;
  @State circlePadCenterOffsetX: number = 0;
  @State circlePadCenterOffsetY: number = 0;
  @State cStickCenterOffsetX: number = 0;
  @State cStickCenterOffsetY: number = 0;
  @State circlePadActive: boolean = false;
  @State cStickActive: boolean = false;
  @State controlsWidth: number = 0;
  @State controlsHeight: number = 0;
  /** 原生画面矩形（vp，两屏并集）；null = 无画面信息 */
  @State gameRect: PadRect | null = null;
  /** 暂停菜单用：游戏图标(存档封面)/在线封面路径、收藏态、纹理滤镜下标 */
  @State gameIcon: image.PixelMap | null = null;
  @State isFavorite: boolean = false;
  @State showPauseMenu: boolean = false;
  /** 存档写入进行中（原生异步执行，期间显示全屏遮罩并阻断交互） */
  @State saveStateSaving: boolean = false;
  @State saveStateInfo: AzaharSaveStateInfo[] = [];
  @State saveStateSlotCount: number = DEFAULT_SAVE_STATE_SLOT_COUNT;
  @State showSaveStateDetail: boolean = false;
  @State detailStateSlot: number = 0;
  @State showCheatPanel: boolean = false;
  // 金手指新增/详情统一走底部弹窗（bindSheet），与游戏详情页金手指 Tab 交互一致；
  // index=-1 表示新增，enabled 取打开时的快照（表单内不提供开关，沿用列表行 Toggle）
  @State showCheatForm: boolean = false;
  @State cheatFormCheat: AzaharCheatInfo = { index: -1, name: '', notes: '', code: '', type: '', enabled: false };
  @State cheatFormName: string = '';
  @State cheatFormCode: string = '';
  @State cheats: AzaharCheatInfo[] = [];
  @State inputOpacity: number = 70;
  @State showOverlay: boolean = true;
  @State fastForwardEnabled: boolean = false;
  @State slowMotionEnabled: boolean = false;
  @State swapScreenEnabled: boolean = false;
  @State uprightScreenEnabled: boolean = false;
  @State microphoneEnabled: boolean = false;
  @State lidClosed: boolean = false;
  // 系统已进入睡眠（遮罩依据）：与盖子状态分开——协商中/被拒时盖虽合但机器醒着，画面照常
  @State lidSleeping: boolean = false;
  // 合盖触发的系统睡眠是否已经挂起模拟（与手动暂停区分开，开盖时只恢复这一种）
  private lidSleepPaused: boolean = false;
  private lidSleepWatchTimer: number = -1;
  private lidSleepWatchTicks: number = 0;
  // 合盖事件跨线程投递，首个 Awake 读数可能只是尚未消费；见到协商态后再回落 Awake 才算拒绝
  private lidSleepWatchSeenPending: boolean = false;
  @State showQuickActions: boolean = false;
  // 麦克风手动静音前的输入类型，恢复时优先用它而不是配置默认值
  private micSavedInputType: number | null = null;
  @State performanceOverlayEnabled: boolean = false;
  @State performanceOverlayPosition: number = 0;
  @State performanceOverlayText: string = '';
  @State movieStatus: AzaharMovieStatus = { mode: 'none', currentInput: 0, totalInput: 0 };

  // 桌面卡片点击当前运行中的游戏时递增，请求本页面直接恢复模拟
  @StorageLink('widgetResumeRequest') @Watch('onWidgetResumeRequest') widgetResumeRequest: number = 0;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private layoutManager: LayoutConfigManager = LayoutConfigManager.getInstance();
  // 布局编辑器保存的自定义按键矩形（窗口 vp 坐标）；空 = 自适应默认布局
  @State customPadComponents: PositionedLayoutComponent[] = [];
  private uriManager: PersistedUriManager = PersistedUriManager.getInstance();
  private downloadDirManager: DownloadDirManager = DownloadDirManager.getInstance();
  private gameConfigManager: GameConfigManager = GameConfigManager.getInstance();
  private playTimeManager: PlayTimeManager = PlayTimeManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private xComponentId: string = 'azahar_xcomponent';
  private windowClass: window.Window | null = null;
  private displayChangeListener: ((displayId: number) => void) | null = null;
  private windowSizeChangeListener: ((size: window.Size) => void) | null = null;
  private overlayBoundsRefreshTimer: number = -1;
  private lifecycleAutoPaused: boolean = false;
  private stillImagePickerOpen: boolean = false;
  private isLeavingGame: boolean = false;
  private applicationLoaded: boolean = false;
  private emulationStarted: boolean = false;
  private startupRetryTimer: number = -1;
  private framePumpTimer: number = -1;
  private layoutPollTicks: number = 0;
  private perfStatsTimer: number = -1;
  private physicalKeysDown: Set<number> = new Set<number>();
  private keyboardBindingManager: KeyboardBindingManager = KeyboardBindingManager.getInstance();
  // 3DS 按键 → 当前按住它的物理键码集合；多绑定/宏下避免一个来源松开误释放
  private physicalKeyHolders: Map<AzaharKey, Set<number>> = new Map();
  // 手柄按住的 3DS 按键（native 映射后、帧泵轮询快照），驱动虚拟按键按下视觉反馈
  @State externalPressedKeys: number[] = [];
  // 手柄驱动的 3DS 摇杆值（死区/映射后快照），驱动虚拟摇杆随物理摇杆移动
  @State externalCirclePadX: number = 0;
  @State externalCirclePadY: number = 0;
  @State externalCStickX: number = 0;
  @State externalCStickY: number = 0;
  // 组合键按键集（gamepad_combo.buttons）：虚拟宏按键 BUTTON_MACRO 的触发目标，
  // 与手柄组合键共用同一配置，页面进入时读取
  private virtualMacroKeys: AzaharKey[] = [];
  private gamepadHotkeyMap: Map<number, string> = new Map<number, string>();
  // Hotkey Enable 修饰键（对齐 Android HotkeyUtility）：>0 表示已绑定，
  // 绑定后需按住它其他快捷键才生效；未绑定则快捷键直接触发
  private gamepadHotkeyEnableCode: number = -1;
  private gamepadHotkeyEnabled: boolean = false;
  // 已作为快捷键吞掉的按下，用于吞掉对应的抬起（避免给游戏发孤立的 keyUp）
  private gamepadHotkeyPressed: Set<number> = new Set<number>();
  private gamepadDeviceCache: Map<number, boolean> = new Map<number, boolean>();
  private softInputBehaviour: string = 'always_visible';
  // 安全区内边距（vp，应用于按键层/性能计数器/角标按钮；px 版下发 native）
  @State padInsetLeft: number = 0;
  @State padInsetTop: number = 0;
  @State padInsetRight: number = 0;
  @State padInsetBottom: number = 0;
  private ignoreSafeArea: boolean = false;
  // 窗口安全区与布局编辑器组件都已解析：按键层在此之后才创建，避免先按自适应算法布局渲染再跳到编辑器坐标
  @State controlsLayoutReady: boolean = false;
  private gamePageVisible: boolean = false;
  private gameWindowControlsActive: boolean = false;
  private gameWindowControlsQueue: Promise<void> = Promise.resolve();
  // 锁定亮度
  private brightnessLocked: boolean = false;
  private brightnessWatching: boolean = false;
  private preGameBrightness: number = -1;
  private lockedBrightnessRaw: number = -1;
  private isGamepadConnected: boolean = false;
  private gamepadDeviceIds: Set<number> = new Set<number>();
  private inputDeviceListening: boolean = false;
  private inputDeviceChangeListener = (event: inputDevice.DeviceListener): void => {
    this.handleInputDeviceChange(event);
  };

  @Builder
  private buildLoadingDialog(): void {
    AzaharLoadingDialog({
      text: this.statusText
    })
  }

  @Builder
  private buildSaveStateSavingDialog(): void {
    AzaharLoadingDialog({
      text: this.statusText
    })
  }

  async aboutToAppear(): Promise<void> {
    initToastHelper(this.getUIContext());
    this.startGamepadMonitor();
    await this.soundEffectManager.initialize(this.context);
    this.virtualMacroKeys = this.keyboardBindingManager.getComboButtons();
    await this.initializeAndBoot();
  }

  aboutToDisappear(): void {
    this.gamePageVisible = false;
    // 页面销毁即"离开"：阻止 initializeAndBoot/tryStartEmulation 等启动路径继续推进
    this.isLeavingGame = true;
    this.stopGamepadMonitor();
    this.disableFastForward(false);
    this.cancelStartupRetry();
    this.stopLidSleepWatch();
    this.stopFramePump();
    this.releaseAllInput();
    // 页面销毁即结束计时会话；exitGame 已结算过时这里是无操作
    this.playTimeManager.finishSession();
    if (AzaharNative.isRunning()) {
      // 卡片换游戏等绕过 exitGame 的销毁路径：页面销毁即会话终止，停掉旧会话
      AzaharNative.stopEmulation();
    }
    AppStorage.set('gameViewActive', false);
    AppStorage.set('activeGameRomPath', '');
    this.refreshWidgetPlayTime();
    this.setKeepScreenOn(false);
    // 恢复窗口设置：方向跟随系统、亮度交还系统
    this.restoreScreenOrientation();
    void this.restoreBrightness();
    if (this.windowClass) {
      try {
        this.windowClass.off('avoidAreaChange');
      } catch (_e) {
        // 注销避让区监听幂等，失败可忽略
      }
      try {
        if (this.windowSizeChangeListener) {
          this.windowClass.off('windowSizeChange', this.windowSizeChangeListener);
        }
      } catch (_e) {
        // 注销窗口尺寸监听幂等，失败可忽略
      }
    }
    if (this.displayChangeListener) {
      try {
        display.off('change', this.displayChangeListener);
      } catch (_e) {
        // 注销显示变化监听幂等，失败可忽略
      }
    }
    if (this.overlayBoundsRefreshTimer >= 0) {
      clearTimeout(this.overlayBoundsRefreshTimer);
      this.overlayBoundsRefreshTimer = -1;
    }
  }

  onPageShow(): void {
    this.gamePageVisible = true;
    this.updateScreenRotation();
    this.loadInputSettings();
    this.restoreFullscreen();
    this.setKeepScreenOn(true);
    // 从设置页返回时重新应用：方向锁定、安全区内边距
    void this.applyScreenOrientation();
    void this.applySafeAreaInsets();

    // 合盖中不自动恢复：开盖由 toggleLid 显式驱动
    if (this.lifecycleAutoPaused && AzaharNative.isPaused() && !this.lidClosed) {
      if (AzaharNative.resumeEmulation()) {
        this.playTimeManager.resumeSession();
        this.lifecycleAutoPaused = false;
        this.isPaused = false;
        this.refreshMovieStatus();
        this.statusText = this.getRunningStatusText();
        this.startFramePump();
      }
    } else if (this.emulationStarted && !this.isPaused && this.surfaceReady) {
      this.startFramePump();
    }
  }

  onPageHide(): void {
    this.gamePageVisible = false;
    this.stopLidSleepWatch();
    this.stopFramePump();
    this.releaseAllInput();
    this.setKeepScreenOn(false);
    this.disableFastForward(false);
    this.disableSlowMotion(false);
    if (AzaharNative.isRunning()) {
      if (AzaharNative.pauseEmulation()) {
        this.playTimeManager.pauseSession();
        this.lifecycleAutoPaused = true;
        this.isPaused = true;
        this.statusText = I18n.t('game_status_paused');
        // 合盖期间产生的生命周期暂停归属合盖语境（协商可能尚未完成），开盖时恢复
        if (this.lidClosed) {
          this.lidSleepPaused = true;
        }
      }
    }
  }

  private async initializeAndBoot(): Promise<void> {
    this.updateScreenRotation();
    const params = router.getParams() as GameViewParams;
    this.romPath = params?.romPath || '';
    // 尽早登记活跃会话（同步、早于首个 await）：启动期间卡片再点时按已运行处理——
    // 同游戏弹回本页，不同游戏先销毁本页再启动，避免叠加第二个 GameView 抢原生会话
    AppStorage.setOrCreate('gameViewActive', true);
    AppStorage.setOrCreate('activeGameRomPath', this.romPath);
    const appInfo = AzaharNative.getAppInfo(this.romPath);
    this.gameTitle = appInfo.fileName || I18n.t('game_no_program_selected');

    await this.initWindowSettings();
    // 卡片换游戏等路径可能在等待期间销毁本页：检查取消，避免继续推进
    if (this.isLeavingGame) {
      return;
    }
    await this.settingsManager.initialize(this.context);
    await this.layoutManager.init(this.context);
    await BackgroundMusicManager.getInstance().initialize(this.context);
    await BackgroundMusicManager.getInstance().pauseForGame();
    await this.uriManager.initialize(this.context);
    await this.downloadDirManager.initialize(this.context);
    await this.gameConfigManager.initialize(this.context);
    // 销毁后不得再触碰 native 会话（initEmulator/loadApplication 与新页的启动会冲突）
    if (this.isLeavingGame) {
      return;
    }
    this.loadInputSettings();
    this.controlsLayoutReady = true;
    const deviceType = DeviceProfile.getDeviceType();
    const downloadDirPath = this.downloadDirManager.getDownloadDirPath();
    if (!downloadDirPath) {
      this.isLoadingGame = false;
      this.statusText = I18n.t('download_dir_not_set');
      BackgroundMusicManager.getInstance().resumeFromGame();
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(this.statusText);
      return;
    }
    const initialized = AzaharNative.initEmulator(
      this.context.filesDir,
      this.context.cacheDir,
      downloadDirPath,
      deviceType,
      this.settingsManager.getTabletJitUserEnabled(deviceType)
    );
    if (!initialized) {
      this.isLoadingGame = false;
      this.statusText = I18n.t('native_init_failed');
      BackgroundMusicManager.getInstance().resumeFromGame();
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(this.statusText);
      return;
    }
    this.settingsManager.syncNativeSettings(deviceType);
    // swap_screen 是会话级状态（全局设置项已废弃）：每局按 false 重新播种，
    // 否则上一局暂存值会残留进本局；单游戏覆盖在 applyNativeOverrides 中仍可生效
    AzaharNative.setConfig('swap_screen', false);
    this.gameConfigManager.applyNativeOverrides(this.romPath);
    // 会话级画面开关以本局生效值为准（此时全局同步+单游戏覆盖已播种完毕，
    // loadInputSettings 早期读到的是上一局遗留的暂存值，需要重读一次）
    this.refreshScreenToggleStates();
    // 语音输入默认关（对齐 nds 麦克风门禁）：设置里的麦克风源仅作恢复目标，
    // 启动把生效 input_type 压为 Null，游戏采样得到静音而非常驻吹气信号；
    // 用户在局内 toggle 开启时才按设置源喂入
    AzaharNative.setConfig('input_type', MIC_INPUT_TYPE_NULL);
    this.microphoneEnabled = false;
    this.applyMovieStartupConfig(params || {});
    this.loadGameMetadata();
    // 内置金手指播种统一收敛在 GameView，覆盖首页/卡片/详情页/录像等全部启动入口；
    // 且必须早于 loadApplication：core 启动时读取并缓存 cheats/<titleId>.txt，之后再落盘本会话不会生效
    CheatsSeed.getInstance().ensureSeed(this.context, downloadDirPath, this.gameTitleId);
    const gameConfig = this.gameConfigManager.getConfig(this.romPath);
    if (gameConfig.customName.trim()) {
      this.gameTitle = gameConfig.customName.trim();
    }

    const result = AzaharNative.loadApplication(this.romPath);
    if (result !== AzaharLoadResult.Success) {
      this.isLoadingGame = false;
      this.statusText = this.describeLoadError(result);
      this.setKeepScreenOn(false);
      BackgroundMusicManager.getInstance().resumeFromGame();
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(this.statusText);
      return;
    }

    this.applicationLoaded = true;
    this.statusText = this.surfaceReady ? this.getReadyStatusText() : I18n.t('game_waiting_surface');
    this.tryStartEmulation();
  }

  // 游戏真正激活摄像头但缺少权限时，native（EnsurePipeline）会置位 pending 标记，
  // 帧泵消费标记后在此弹系统授权框；授权后 applyConfig → ReloadCameraDevices 重开相机，
  // 拒绝则保持黑帧（native 侧会话内只置位一次，与 Android camera_permission_requested 语义一致）
  private async onCameraPermissionRequest(): Promise<void> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(this.context,
        ['ohos.permission.CAMERA' as Permissions]);
      if (result.authResults.length > 0 && result.authResults[0] === 0) {
        AzaharNative.applyConfig();
      }
    } catch (_error) {
      console.warn(`[GameView] request CAMERA permission failed: ${(_error as Error)?.message}`);
    }
  }

  // 游戏调用麦克风且未授权时 native 置位 pending，帧泵消费后弹系统授权框；
  // 授权后 applyConfig 让 mic_u 重建输入设备；拒绝则本局保持静音输入
  private async onMicPermissionRequest(): Promise<void> {
    if (await this.requestMicPermission()) {
      AzaharNative.applyConfig();
    }
  }

  // 拉起系统麦克风授权；授权失败/异常均返回 false（调用方据此决定是否启用真实设备输入）
  private async requestMicPermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(this.context,
        ['ohos.permission.MICROPHONE' as Permissions]);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (_error) {
      console.warn(`[GameView] request MICROPHONE permission failed: ${(_error as Error)?.message}`);
      return false;
    }
  }

  // 对应 Android StillImageCameraHelper.openFilePicker：游戏激活静态图片相机且
  // native 无缓存路径时置位 pending，帧泵消费后拉起系统文件选择器。
  // DocumentViewPicker 取真实路径（retro 式 FileUri.path，native 直接读，不拷沙箱）；
  // 路径只进 native 会话缓存 last_path，与 Android 一致不持久化——重启/相机重建后
  // 会再次弹出。取消则保持黑帧
  private async onStillImagePickRequest(): Promise<void> {
    if (this.stillImagePickerOpen) {
      return;
    }
    this.stillImagePickerOpen = true;
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['Images (.png, .jpg, .jpeg, .bmp)|.png,.jpg,.jpeg,.bmp'];
      const result = await documentPicker.select(options);
      const uri = result?.[0];
      if (!uri) {
        return;
      }
      AzaharNative.setStillImagePath(new fileUri.FileUri(uri).path);
      AzaharNative.applyConfig();
    } catch (_error) {
      console.warn(`[GameView] camera image picker failed: ${(_error as Error)?.message}`);
    } finally {
      this.stillImagePickerOpen = false;
    }
  }

  private tryStartEmulation(): void {
    if (this.emulationStarted || !this.applicationLoaded || this.isLeavingGame) {
      return;
    }

    const runtimeInfo = AzaharNative.getRuntimeInfo();
    this.surfaceReady = runtimeInfo.surfaceReady;
    if (runtimeInfo.surfaceReady) {
      this.refreshGameRect();
    }
    if (!runtimeInfo.surfaceReady) {
      this.statusText = I18n.t('game_waiting_surface');
      this.scheduleStartupRetry();
      return;
    }

    if (AzaharNative.startEmulation()) {
      this.cancelStartupRetry();
      this.lifecycleAutoPaused = false;
      this.emulationStarted = true;
      this.isLoadingGame = false;
      this.statusText = this.getRunningStatusText();
      this.isPaused = false;
      this.startFramePump();
      void this.startPlayStatsSession();
    } else {
      const latestInfo = AzaharNative.getRuntimeInfo();
      this.statusText = I18n.tf1('game_start_failed_fmt', 'status', latestInfo.backendStatus);
      if (latestInfo.backendStatus === 'azahar_core_no_surface') {
        this.scheduleStartupRetry();
      } else {
        this.isLoadingGame = false;
      }
    }
  }

  /** 启动成功后开计时会话；init 幂等，重复进入安全 */
  private async startPlayStatsSession(): Promise<void> {
    await this.playTimeManager.init(this.context);
    // init 等待期间可能已退出或被生命周期暂停：退出则不再开会话，暂停则立即挂起计时段
    if (this.isLeavingGame) {
      return;
    }
    this.playTimeManager.startSession(this.gameTitleId, this.romPath);
    if (this.isPaused) {
      this.playTimeManager.pauseSession();
    }
  }

  private scheduleStartupRetry(): void {
    if (this.startupRetryTimer >= 0 || this.isLeavingGame || this.emulationStarted) {
      return;
    }
    this.startupRetryTimer = setTimeout(() => {
      this.startupRetryTimer = -1;
      this.tryStartEmulation();
    }, 100);
  }

  private cancelStartupRetry(): void {
    if (this.startupRetryTimer < 0) {
      return;
    }
    clearTimeout(this.startupRetryTimer);
    this.startupRetryTimer = -1;
  }

  private startFramePump(): void {
    this.updateGameWindowControls(this.gamePageVisible && this.emulationStarted && !this.isPaused && !this.isLeavingGame);
    if (this.framePumpTimer >= 0 || this.isLeavingGame) {
      return;
    }
    this.framePumpTimer = setInterval(() => {
      if (this.isLeavingGame) {
        this.stopFramePump();
        return;
      }
      if (AzaharNative.consumeCameraPermissionRequest()) {
        void this.onCameraPermissionRequest();
      }
      if (AzaharNative.consumeMicPermissionRequest()) {
        void this.onMicPermissionRequest();
      }
      if (AzaharNative.consumeStillImagePickRequest()) {
        void this.onStillImagePickRequest();
      }
      const coreError = AzaharNative.consumeCoreError();
      if (coreError) {
        this.onCoreRuntimeError(coreError);
      }
      this.syncExternalInputState();
      // 每 ~500ms 轮询一次原生画面布局（帧泵 16ms × 31）
      this.layoutPollTicks++;
      if (this.layoutPollTicks >= 31) {
        this.layoutPollTicks = 0;
        this.refreshGameRect();
        this.syncLidStateWithNative();
      }
      if (!this.emulationStarted || this.isPaused || !this.surfaceReady) {
        return;
      }
      AzaharNative.doFrame();
    }, 16);
    this.startPerfStatsUpdater();
  }

  /** 轮询手柄输入快照（映射后按键 + 摇杆），变化时才写 @State 触发按键层重绘。
   *  触控层隐藏（softInputBehaviour）时没有按键可亮，跳过 NAPI 轮询并清残留高亮，
   *  避免隐藏期间按住的键在恢复显示瞬间闪旧态 */
  private syncExternalInputState(): void {
    if (!this.showOverlay) {
      if (this.externalPressedKeys.length > 0) {
        this.externalPressedKeys = [];
      }
      if (this.externalCirclePadX !== 0 || this.externalCirclePadY !== 0 ||
        this.externalCStickX !== 0 || this.externalCStickY !== 0) {
        this.externalCirclePadX = 0;
        this.externalCirclePadY = 0;
        this.externalCStickX = 0;
        this.externalCStickY = 0;
      }
      return;
    }
    const held = AzaharNative.getGamepadPressedKeys();
    const prev = this.externalPressedKeys;
    if (held.length !== prev.length ||
      !held.every((key: number) => prev.indexOf(key) >= 0)) {
      this.externalPressedKeys = held;
    }
    const axes = AzaharNative.getGamepadAnalogState();
    if (axes.length >= 4 &&
      (axes[0] !== this.externalCirclePadX || axes[1] !== this.externalCirclePadY ||
        axes[2] !== this.externalCStickX || axes[3] !== this.externalCStickY)) {
      this.externalCirclePadX = axes[0];
      this.externalCirclePadY = axes[1];
      this.externalCStickX = axes[2];
      this.externalCStickY = axes[3];
    }
  }

  private stopFramePump(): void {
    this.updateGameWindowControls(false);
    if (this.framePumpTimer < 0) {
      this.stopPerfStatsUpdater();
      return;
    }
    clearInterval(this.framePumpTimer);
    this.framePumpTimer = -1;
    this.stopPerfStatsUpdater();
  }

  private startPerfStatsUpdater(): void {
    if (this.perfStatsTimer >= 0 || !this.performanceOverlayEnabled || this.isLeavingGame) {
      return;
    }
    this.updatePerformanceOverlayText();
    this.perfStatsTimer = setInterval(() => {
      this.updatePerformanceOverlayText();
    }, 1000);
  }

  private stopPerfStatsUpdater(): void {
    if (this.perfStatsTimer >= 0) {
      clearInterval(this.perfStatsTimer);
      this.perfStatsTimer = -1;
    }
    this.performanceOverlayText = '';
  }

  private updatePerformanceOverlayText(): void {
    if (!this.performanceOverlayEnabled || !this.emulationStarted || this.isPaused) {
      this.performanceOverlayText = '';
      return;
    }

    const stats = AzaharNative.getPerfStats();
    if (stats.length <= PERF_STATS_GAME_FPS || stats[PERF_STATS_GAME_FPS] <= 0) {
      return;
    }

    this.performanceOverlayText = `FPS: ${Math.floor(stats[PERF_STATS_GAME_FPS] + 0.5)}`;
  }

  private async initWindowSettings(): Promise<void> {
    try {
      this.windowClass = await window.getLastWindow(this.context);
      await this.windowClass.setWindowLayoutFullScreen(true);
      await this.windowClass.setWindowSystemBarEnable([]);
      await this.windowClass.setWindowKeepScreenOn(true);
      await this.applyBrightnessLock();
      await this.applyScreenOrientation();
      await this.applySafeAreaInsets();
      // 避让区域变化（旋转/折叠屏等）时重新计算安全区内边距
      try {
        this.windowClass.on('avoidAreaChange', () => {
          void this.applySafeAreaInsets();
        });
      } catch (_e) {
        console.warn(`[GameView] register avoidAreaChange failed, safe-area refit disabled: ${(_e as Error)?.message}`);
      }
      try {
        this.windowSizeChangeListener = (_size: window.Size): void => {
          this.updateOverlayBoundsFromWindow();
        };
        this.windowClass.on('windowSizeChange', this.windowSizeChangeListener);
      } catch (_e) {
        console.warn(`[GameView] register windowSizeChange failed: ${(_e as Error)?.message}`);
      }
      try {
        this.displayChangeListener = (_displayId: number): void => {
          if (this.overlayBoundsRefreshTimer >= 0) {
            clearTimeout(this.overlayBoundsRefreshTimer);
          }
          // Display orientation can update before drawableRect; read the window after it settles.
          this.overlayBoundsRefreshTimer = setTimeout(() => {
            this.overlayBoundsRefreshTimer = -1;
            this.updateOverlayBoundsFromWindow();
          }, 50);
        };
        display.on('change', this.displayChangeListener);
      } catch (_e) {
        console.warn(`[GameView] register display change failed: ${(_e as Error)?.message}`);
      }
      this.updateOverlayBoundsFromWindow();
    } catch (_error) {
      this.windowClass = null;
      this.updateOverlayBoundsFromWindow();
    }
  }

  private async restoreFullscreen(): Promise<void> {
    if (!this.windowClass) {
      return;
    }
    try {
      await this.windowClass.setWindowLayoutFullScreen(true);
      await this.windowClass.setWindowSystemBarEnable([]);
    } catch (_error) {
      console.warn(`[GameView] restoreFullscreen failed: ${(_error as Error)?.message}`);
    }
  }

  private updateGameWindowControls(active: boolean): void {
    this.gameWindowControlsActive = active;
    this.gameWindowControlsQueue = this.gameWindowControlsQueue.then(async () => {
      const targetWindow = this.windowClass;
      if (!targetWindow) {
        return;
      }
      const gestureWindow = targetWindow as object as GestureBackWindow;
      const disableBack = this.gameWindowControlsActive &&
        this.settingsManager.getBoolean(KEY_DISABLE_GESTURE_BACK_IN_GAME);
      try {
        if (typeof gestureWindow.setGestureBackEnabled === 'function') {
          await gestureWindow.setGestureBackEnabled(!disableBack);
        } else if (disableBack) {
          hilog.warn(0x0000, 'GameView', 'setGestureBackEnabled is unavailable');
        }
      } catch (error) {
        hilog.error(0x0000, 'GameView', 'Failed to set gesture back: %{public}s', JSON.stringify(error));
      }
      try {
        await targetWindow.setWindowPrivacyMode(this.gameWindowControlsActive &&
          this.settingsManager.getBoolean(KEY_PRIVACY_MODE_IN_GAME));
      } catch (error) {
        hilog.error(0x0000, 'GameView', 'Failed to set window privacy mode: %{public}s', JSON.stringify(error));
      }
    });
  }

  private async setKeepScreenOn(keepOn: boolean): Promise<void> {
    if (!this.windowClass) {
      return;
    }
    try {
      await this.windowClass.setWindowKeepScreenOn(keepOn);
    } catch (_error) {
      console.warn(`[GameView] setWindowKeepScreenOn failed: ${(_error as Error)?.message}`);
    }
  }

  // 屏幕方向：auto→跟随系统(受旋转锁定) portrait→竖屏 landscape→横屏；退出游戏恢复
  private async applyScreenOrientation(): Promise<void> {
    if (!this.windowClass) {
      return;
    }
    try {
      const setting = this.settingsManager.getString(KEY_SCREEN_ORIENTATION) || 'auto';
      let orientation: window.Orientation;
      switch (setting) {
        case 'landscape':
          orientation = window.Orientation.AUTO_ROTATION_LANDSCAPE;
          break;
        case 'portrait':
          orientation = window.Orientation.AUTO_ROTATION_PORTRAIT;
          break;
        default:
          orientation = window.Orientation.AUTO_ROTATION_RESTRICTED;
          break;
      }
      await this.windowClass.setPreferredOrientation(orientation);
    } catch (_e) {
      console.warn(`[GameView] setPreferredOrientation failed: ${(_e as Error)?.message}`);
    }
  }

  private async restoreScreenOrientation(): Promise<void> {
    if (!this.windowClass) {
      return;
    }
    try {
      await this.windowClass.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
    } catch (_e) {
      console.warn(`[GameView] restoreScreenOrientation failed: ${(_e as Error)?.message}`);
    }
  }

  // 锁定亮度：读取当前系统亮度并钉为本窗口亮度；退后台/退出自动失效
  private async applyBrightnessLock(): Promise<void> {
    if (!this.windowClass || !this.settingsManager.getBoolean(KEY_LOCK_GAME_BRIGHTNESS)) {
      return;
    }
    try {
      const raw = settings.getValueSync(this.context, settings.display.SCREEN_BRIGHTNESS_STATUS, '255');
      let value = parseInt(raw, 10);
      if (isNaN(value) || value < 0 || value > 255) {
        value = 255;
      }
      const level = Math.min(1.0, Math.max(0.05, value / 255));
      this.preGameBrightness = level;
      this.lockedBrightnessRaw = value;
      await this.windowClass.setWindowBrightness(level);
      this.brightnessLocked = true;
      this.startBrightnessWatch();
    } catch (_e) {
      console.warn(`[GameView] setWindowBrightness(lock) failed: ${(_e as Error)?.message}`);
    }
  }

  // 监听系统亮度键值：用户在控制中心调整时跟随新值重新钉住；自动亮度模式下不监听
  private startBrightnessWatch(): void {
    if (this.brightnessWatching) {
      return;
    }
    try {
      const auto = settings.getValueSync(this.context, settings.display.AUTO_SCREEN_BRIGHTNESS, '0');
      if (parseInt(auto, 10) === settings.display.AUTO_SCREEN_BRIGHTNESS_MODE) {
        return;
      }
    } catch (_e) {
      // 自动亮度开关查询失败，按锁定亮度继续
    }
    try {
      this.brightnessWatching = settings.registerKeyObserver(this.context,
        settings.display.SCREEN_BRIGHTNESS_STATUS, settings.domainName.DEVICE_SHARED, () => {
          this.onSystemBrightnessChanged();
        });
    } catch (_e) {
      console.warn(`[GameView] register brightness observer failed: ${(_e as Error)?.message}`);
    }
  }

  private onSystemBrightnessChanged(): void {
    if (!this.brightnessLocked || !this.windowClass) {
      return;
    }
    try {
      const raw = settings.getValueSync(this.context, settings.display.SCREEN_BRIGHTNESS_STATUS, '-1');
      const value = parseInt(raw, 10);
      if (isNaN(value) || value < 0 || value > 255 || value === this.lockedBrightnessRaw) {
        return;
      }
      this.lockedBrightnessRaw = value;
      const level = Math.min(1.0, Math.max(0.05, value / 255));
      this.preGameBrightness = level;
      this.windowClass.setWindowBrightness(level).catch((_err: Error) => {});
    } catch (_e) {
      // 亮度查询失败时保持当前亮度
    }
  }

  private stopBrightnessWatch(): void {
    if (!this.brightnessWatching) {
      return;
    }
    this.brightnessWatching = false;
    try {
      settings.unregisterKeyObserver(this.context,
        settings.display.SCREEN_BRIGHTNESS_STATUS, settings.domainName.DEVICE_SHARED);
    } catch (_e) {
      // 注销亮度观察器幂等，失败可忽略
    }
  }

  // 2in1 上 setWindowBrightness(-1) 不生效且窗口亮度会直接写成系统亮度，需要写回进入前的值
  private async restoreBrightness(): Promise<void> {
    this.stopBrightnessWatch();
    if (!this.brightnessLocked || !this.windowClass) {
      return;
    }
    this.brightnessLocked = false;
    try {
      if (deviceInfo.deviceType === '2in1' && this.preGameBrightness >= 0) {
        await this.windowClass.setWindowBrightness(this.preGameBrightness);
      } else {
        await this.windowClass.setWindowBrightness(-1);
      }
    } catch (_e) {
      console.warn(`[GameView] restoreBrightness failed: ${(_e as Error)?.message}`);
    }
  }

  // 安全区内边距：竖屏=顶部状态栏/挖孔 + 底部导航条；横屏=左右对称避让（参照 nds resolveSafeArea）
  // px 值下发 native 平移画面矩形，vp 值驱动按键层/性能计数器/角标按钮
  private async applySafeAreaInsets(): Promise<void> {
    this.ignoreSafeArea = this.settingsManager.getBoolean(KEY_IGNORE_SAFE_AREA);
    let topPx = 0;
    let bottomPx = 0;
    let leftPx = 0;
    let rightPx = 0;
    if (this.windowClass && !this.ignoreSafeArea) {
      try {
        const snapshot = display.getDefaultDisplaySync();
        const density = snapshot.densityPixels || 1;
        const screenWidthPx = snapshot.width;
        const screenHeightPx = snapshot.height;
        const isLandscape = screenWidthPx > screenHeightPx;
        const windowStatus = this.windowClass.getWindowStatus();
        if (windowStatus !== 4 && windowStatus !== 5) {
          const capInset = (value: number, max: number): number => {
            if (value <= 0) {
              return 0;
            }
            return value > max / 2 ? Math.floor(max / 2) : value;
          };
          const systemArea = this.windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          const cutoutArea = this.windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
          let navArea: window.AvoidArea | null = null;
          try {
            navArea = this.windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
          } catch (_e) {
            // 导航指示条避让区不可得，仅缺失指示条内边距
          }
          const avoidTop = Math.max(systemArea.topRect.height, cutoutArea.topRect.height);
          const avoidBottom = Math.max(systemArea.bottomRect.height,
            navArea ? navArea.bottomRect.height : 0);
          const avoidLeft = Math.max(
            systemArea.leftRect.left + systemArea.leftRect.width,
            cutoutArea.leftRect.left + cutoutArea.leftRect.width,
            navArea ? navArea.leftRect.left + navArea.leftRect.width : 0);
          const avoidRight = Math.max(
            systemArea.rightRect.width > 0 ? screenWidthPx - systemArea.rightRect.left : 0,
            cutoutArea.rightRect.width > 0 ? screenWidthPx - cutoutArea.rightRect.left : 0,
            navArea && navArea.rightRect.width > 0 ? screenWidthPx - navArea.rightRect.left : 0);

          let cutoutTop = 0;
          let cutoutBottom = 0;
          let cutoutLeft = 0;
          let cutoutRight = 0;
          let waterfallTop = 0;
          let waterfallBottom = 0;
          let waterfallLeft = 0;
          let waterfallRight = 0;
          try {
            const cutoutInfo = await snapshot.getCutoutInfo();
            if (cutoutInfo.boundingRects) {
              for (const rect of cutoutInfo.boundingRects) {
                const centerX = rect.left + rect.width / 2;
                const centerY = rect.top + rect.height / 2;
                if (centerY <= screenHeightPx / 2) {
                  cutoutTop = Math.max(cutoutTop, rect.top + rect.height);
                } else {
                  cutoutBottom = Math.max(cutoutBottom, screenHeightPx - rect.top);
                }
                if (centerX <= screenWidthPx / 2) {
                  cutoutLeft = Math.max(cutoutLeft, rect.left + rect.width);
                } else {
                  cutoutRight = Math.max(cutoutRight, screenWidthPx - rect.left);
                }
              }
            }
            if (cutoutInfo.waterfallDisplayAreaRects) {
              const w = cutoutInfo.waterfallDisplayAreaRects;
              waterfallTop = w.top.top + w.top.height;
              waterfallBottom = w.bottom.height > 0 ? screenHeightPx - w.bottom.top : 0;
              waterfallLeft = w.left.left + w.left.width;
              waterfallRight = w.right.width > 0 ? screenWidthPx - w.right.left : 0;
            }
          } catch (_e) {
            // 挖孔/瀑布屏信息在部分设备不可得，按无挖孔处理
          }

          topPx = capInset(Math.max(avoidTop, cutoutTop, waterfallTop), screenHeightPx);
          bottomPx = capInset(Math.max(avoidBottom, cutoutBottom, waterfallBottom), screenHeightPx);
          leftPx = capInset(Math.max(avoidLeft, cutoutLeft, waterfallLeft), screenWidthPx);
          rightPx = capInset(Math.max(avoidRight, cutoutRight, waterfallRight), screenWidthPx);
          if (isLandscape) {
            // 横屏只保留左右对称避让（同 nds）
            const symmetric = capInset(Math.max(leftPx, rightPx), screenWidthPx);
            leftPx = symmetric;
            rightPx = symmetric;
            topPx = 0;
            bottomPx = 0;
          } else {
            leftPx = 0;
            rightPx = 0;
          }
        }
      } catch (_e) {
        // 显示/窗口属性查询在部分设备不可得，按无避让处理
      }
    }

    AzaharNative.setScreenOffsets(leftPx, topPx, rightPx, bottomPx);
    const density = display.getDefaultDisplaySync().densityPixels || 1;
    this.padInsetTop = Math.round(topPx / density * 100) / 100;
    this.padInsetBottom = Math.round(bottomPx / density * 100) / 100;
    this.padInsetLeft = Math.round(leftPx / density * 100) / 100;
    this.padInsetRight = Math.round(rightPx / density * 100) / 100;
    this.refreshGameRect();
  }

  private updateScreenRotation(): void {
    try {
      const currentDisplay = display.getDefaultDisplaySync();
      AzaharNative.setScreenRotation(currentDisplay.rotation);
      this.updateOverlayBoundsFromWindow();
    } catch (_error) {
      console.warn(`[GameView] updateScreenRotation failed: ${(_error as Error)?.message}`);
    }
  }

  private updateOverlayBoundsFromWindow(): void {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      const density = defaultDisplay.densityPixels || 1;
      if (this.windowClass) {
        const props = this.windowClass.getWindowProperties();
        const rect = props.drawableRect && props.drawableRect.width > 0 ? props.drawableRect : props.windowRect;
        if (rect.width > 0 && rect.height > 0) {
          this.setOverlayBounds(Math.round(rect.width / density), Math.round(rect.height / density));
          return;
        }
      }
      // Display dimensions may remain in their natural orientation after rotation.
      const isLandscape = defaultDisplay.orientation === display.Orientation.LANDSCAPE ||
        defaultDisplay.orientation === display.Orientation.LANDSCAPE_INVERTED;
      const shortSide = Math.min(defaultDisplay.width, defaultDisplay.height);
      const longSide = Math.max(defaultDisplay.width, defaultDisplay.height);
      const width = isLandscape ? longSide : shortSide;
      const height = isLandscape ? shortSide : longSide;
      this.setOverlayBounds(Math.round(width / density), Math.round(height / density));
    } catch (_error) {
      console.warn(`[GameView] updateOverlayBounds failed: ${(_error as Error)?.message}`);
    }
  }

  private setOverlayBounds(width: number, height: number): void {
    if (width > 0 && width !== this.controlsWidth) {
      this.controlsWidth = width;
    }
    if (height > 0 && height !== this.controlsHeight) {
      this.controlsHeight = height;
    }
    this.refreshCustomPadComponents();
  }

  // 读取当前默认布局配置，取当前方向/尺寸的最优变体；
  // 未保存过自定义布局时返回的默认组件与自适应算法一致，按键层照用即可
  private refreshCustomPadComponents(): void {
    if (!this.layoutManager.isInitialized() || this.controlsWidth <= 0 || this.controlsHeight <= 0) {
      return;
    }
    try {
      const perGameLayoutId = this.gameConfigManager.getConfig(this.romPath).layoutId;
      const config = perGameLayoutId
        ? (this.layoutManager.getLayoutById(perGameLayoutId) ||
          this.layoutManager.getDefaultLayout(this.controlsWidth, this.controlsHeight))
        : this.layoutManager.getDefaultLayout(this.controlsWidth, this.controlsHeight);
      this.customPadComponents =
        this.layoutManager.resolveGameComponents(config, this.controlsWidth, this.controlsHeight, 'default');
      this.applyScreenRectsFromLayout(config);
    } catch (_e) {
      this.customPadComponents = [];
      AzaharNative.clearCustomScreenRects();
    }
  }

  // 屏幕矩形下发（对齐 nds resolveCustomLayout）：已存布局变体命中时把编辑器的
  // 双屏矩形（vp→px）交给 native 渲染；未命中（内置默认生成）清除显式矩形，
  // 画面回退 layout_option 自动布局
  private applyScreenRectsFromLayout(config: LayoutConfiguration): void {
    const variant = LayoutConfigManager.buildVariant(this.controlsWidth, this.controlsHeight);
    const top = this.customPadComponents.find(
      (c: PositionedLayoutComponent) => c.component === LayoutComponent.TOP_SCREEN);
    const bottom = this.customPadComponents.find(
      (c: PositionedLayoutComponent) => c.component === LayoutComponent.BOTTOM_SCREEN);
    if (!this.layoutManager.hasUsableVariant(config, variant) || !top || !bottom) {
      AzaharNative.clearCustomScreenRects();
      return;
    }
    const density = display.getDefaultDisplaySync().densityPixels || 1;
    AzaharNative.setCustomScreenRects(
      Math.round(top.rect.x * density), Math.round(top.rect.y * density),
      Math.round(top.rect.width * density), Math.round(top.rect.height * density),
      Math.round(bottom.rect.x * density), Math.round(bottom.rect.y * density),
      Math.round(bottom.rect.width * density), Math.round(bottom.rect.height * density));
  }

  private describeLoadError(result: AzaharLoadResult): string {
    switch (result) {
      case AzaharLoadResult.NotInitialized:
        return I18n.t('native_init_failed');
      case AzaharLoadResult.EmptyPath:
        return I18n.t('load_error_empty_path');
      case AzaharLoadResult.UnsupportedFormat:
        return I18n.t('load_error_unsupported_format');
      case AzaharLoadResult.FileNotFound:
        return I18n.t('load_error_file_not_found');
      default:
        return I18n.t('load_error_failed');
    }
  }

  private loadGameMetadata(): void {
    try {
      const metadata = AzaharNative.getGameMetadata(this.romPath);
      this.gameTitleId = metadata.titleId;
      // 与首页列表共用 GameManager.getDisplayName 的命名逻辑（自定义名 > 名称来源偏好 > 元数据名）
      this.gameTitle = GameManager.getInstance().getDisplayName(this.currentGame(metadata)) || this.gameTitle;
    } catch (_error) {
      this.gameTitleId = '';
    }
  }

  /** 当前运行游戏的 GameInfo 视图模型，供 GameManager.getDisplayName 等统一逻辑复用 */
  private currentGame(meta: AzaharGameMetadata): GameInfo {
    const fileName = this.romPath.substring(Math.max(this.romPath.lastIndexOf('/'), this.romPath.lastIndexOf('\\')) + 1);
    return {
      uri: '',
      path: this.romPath,
      name: meta.longTitle || meta.shortTitle || fileName,
      fileName: fileName,
      extension: '',
      titleId: meta.titleId || this.gameTitleId,
      shortTitle: meta.shortTitle,
      longTitle: meta.longTitle,
      publisher: meta.publisher,
      regions: meta.regions,
      productCode: meta.productCode || '',
      extdataId: meta.extdataId,
      fileType: meta.fileType,
      encrypted: meta.encrypted,
      insertable: meta.insertable,
      inserted: false,
      systemTitle: meta.systemTitle,
      visible: true,
      hasIcon: meta.hasIcon,
      installed: GameManager.getInstance().isInstalledTitlePath(this.romPath),
      mediaType: 0,
      lastPlayed: 0,
      playCount: 0,
      playTimeMs: 0,
      favorite: false
    };
  }

  private loadInputSettings(): void {
    this.loadGamepadHotkeys();
    this.inputOpacity = this.settingsManager.getNumber(KEY_CONTROL_OPACITY);
    this.softInputBehaviour = this.settingsManager.getString(KEY_SOFT_INPUT_BEHAVIOUR);
    this.applySoftInputBehaviour();
    this.refreshCustomPadComponents();
    this.performanceOverlayEnabled = this.settingsManager.getBoolean(KEY_PERFORMANCE_OVERLAY_ENABLE);
    this.performanceOverlayPosition = this.settingsManager.getNumber(KEY_PERFORMANCE_OVERLAY_POSITION);
    this.refreshScreenToggleStates();
    // 麦克风启用态 = 当前生效输入类型不是 Null；手动静音保存的源在本局内有效
    this.microphoneEnabled =
      this.getEffectiveNumberConfig('input_type', this.settingsManager.getNumber(KEY_AUDIO_INPUT_TYPE)) !==
        MIC_INPUT_TYPE_NULL;
    if (!this.microphoneEnabled) {
      this.micSavedInputType = null;
    }
    this.lidClosed = !AzaharNative.getShellOpen();
    // 页面重建恢复睡眠遮罩：壳合着且原生侧处于暂停 = 上次是睡眠中离场
    this.lidSleeping = this.lidClosed && AzaharNative.isPaused();
  }

  private getEffectiveNumberConfig(key: string, fallback: number): number {
    const value = AzaharNative.getConfig(key);
    return typeof value === 'number' ? value : fallback;
  }

  private getEffectiveBooleanConfig(key: string, fallback: boolean): boolean {
    const value = AzaharNative.getConfig(key);
    return typeof value === 'boolean' ? value : fallback;
  }

  /** 会话级画面开关的初始态：native 暂存表中的生效值（全局设置 + 单游戏覆盖合成） */
  private refreshScreenToggleStates(): void {
    this.swapScreenEnabled = this.getEffectiveBooleanConfig('swap_screen', false);
    this.uprightScreenEnabled = this.getEffectiveBooleanConfig('upright_screen', this.settingsManager.getBoolean(KEY_UPRIGHT_SCREEN));
  }

  private applyMovieStartupConfig(params: GameViewParams): void {
    AzaharNative.setConfig('movie_record_path', '');
    AzaharNative.setConfig('movie_record_author', '');
    AzaharNative.setConfig('movie_playback_path', '');
    AzaharNative.setConfig('movie_read_only', true);

    const mode = params.movieMode || '';
    const moviePath = params.moviePath || '';
    if (mode === 'record' && moviePath) {
      AzaharNative.setConfig('movie_record_path', moviePath);
      AzaharNative.setConfig('movie_record_author', params.movieAuthor || I18n.t('azahar_ohos_author'));
      this.movieStatus = { mode: 'recording', currentInput: 0, totalInput: 0 };
      this.statusText = I18n.t('movie_prepare_record');
    } else if (mode === 'play' && moviePath) {
      AzaharNative.setConfig('movie_playback_path', moviePath);
      AzaharNative.setConfig('movie_read_only', params.movieReadOnly !== false);
      this.movieStatus = { mode: 'playing', currentInput: 0, totalInput: 0 };
      this.statusText = I18n.t('movie_prepare_playback');
    } else {
      this.movieStatus = { mode: 'none', currentInput: 0, totalInput: 0 };
    }
  }

  private refreshMovieStatus(): void {
    try {
      this.movieStatus = AzaharNative.getMovieStatus();
    } catch (_error) {
      this.movieStatus = { mode: 'none', currentInput: 0, totalInput: 0 };
    }
  }

  private getReadyStatusText(): string {
    if (this.movieStatus.mode === 'recording') {
      return I18n.t('movie_prepare_record');
    }
    if (this.movieStatus.mode === 'playing') {
      return I18n.t('movie_prepare_playback');
    }
    return I18n.t('game_status_prepare_start');
  }

  private getRunningStatusText(): string {
    if (this.movieStatus.mode === 'recording') {
      return I18n.t('movie_recording');
    }
    if (this.movieStatus.mode === 'playing') {
      return I18n.t('movie_playing');
    }
    if (this.movieStatus.mode === 'finished') {
      return I18n.t('movie_finished');
    }
    return I18n.t('game_status_running');
  }

  private refreshCheats(): void {
    if (!this.gameTitleId) {
      this.cheats = [];
      return;
    }
    this.cheats = AzaharNative.getCheats(this.gameTitleId);
  }

  private openCheatPanel(): void {
    this.soundEffectManager.play(SoundEffect.SELECT);
    this.refreshCheats();
    this.showPauseMenu = false;
    this.showCheatPanel = true;
    this.releaseAllInput();
  }

  private closeCheatPanel(): void {
    this.soundEffectManager.play(SoundEffect.BACK);
    this.showCheatForm = false;
    this.showCheatPanel = false;
    this.showPauseMenu = true;
  }

  // 新增与查看/编辑共用同一底部弹窗：index=-1 表示新增（保存时 upsert 追加）
  private openCheatForm(cheat: AzaharCheatInfo): void {
    this.cheatFormCheat = cheat;
    this.cheatFormName = cheat.name;
    this.cheatFormCode = cheat.code;
    this.showCheatForm = true;
  }

  private viewCheatDetail(cheat: AzaharCheatInfo): void {
    this.openCheatForm(cheat);
  }

  private closeCheatForm(playSound: boolean = true): void {
    if (playSound) {
      this.soundEffectManager.play(SoundEffect.BACK);
    }
    this.showCheatForm = false;
  }

  /** 表单内删除：先关弹窗再走确认删除，避免弹窗下残留已删条目 */
  private deleteCheatForm(): void {
    const cheat = this.cheatFormCheat;
    this.showCheatForm = false;
    this.deleteCheat(cheat);
  }

  private beginAddCheat(): void {
    this.soundEffectManager.play(SoundEffect.DECIDE);
    this.openCheatForm({ index: -1, name: '', notes: '', code: '', type: '', enabled: false });
  }

  private async importCheatFile(): Promise<void> {
    if (!this.gameTitleId) {
      showWarningToast(I18n.t('cheat_no_available_title_id'));
      return;
    }
    let file: fileIo.File | undefined;
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.txt'];
      const result = await documentPicker.select(options);
      if (!result || result.length === 0) {
        return;
      }
      await this.uriManager.persistFilePermission(result[0]);
      const path = FileManagerHelper.pathFromUri(result[0]);
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      if (stat.size <= 0 || stat.size > 4 * 1024 * 1024) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('cheat_import_invalid_file'));
        return;
      }
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      const contents = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buffer));
      if (!AzaharNative.importCheats(this.gameTitleId, contents)) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('cheat_import_invalid_file'));
        return;
      }
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      this.refreshCheats();
      showSuccessToast(I18n.t('cheat_imported'));
    } catch (error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('cheat_import_failed_fmt', 'error', JSON.stringify(error)));
    } finally {
      if (file) {
        fileIo.closeSync(file);
      }
    }
  }

  /** 校验并写回金手指：成功返回空串，失败返回错误文案（表单弹窗统一走这里） */
  private upsertCheatChecked(index: number, name: string, notes: string, code: string,
    enabled: boolean): string {
    const trimmedName = name.trim();
    const trimmedCode = code.trim();
    if (!this.gameTitleId) {
      return I18n.t('cheat_no_title_id_cannot_save');
    }
    if (!trimmedName) {
      return I18n.t('cheat_name_required');
    }
    if (!trimmedCode) {
      return I18n.t('cheat_code_required');
    }
    const invalidLine = AzaharNative.validateGatewayCheatCode(trimmedCode);
    if (invalidLine !== 0) {
      return I18n.tf1('cheat_invalid_line_fmt', 'line', invalidLine);
    }
    if (!AzaharNative.upsertGatewayCheat(this.gameTitleId, index, trimmedName, notes.trim(),
      trimmedCode, enabled)) {
      return I18n.t('save_failed');
    }
    return '';
  }

  /** 底部弹窗保存：保留条目原有 enabled 态（表单内无开关），成功后关弹窗并刷新列表 */
  private saveCheatForm(): string {
    const error = this.upsertCheatChecked(this.cheatFormCheat.index, this.cheatFormName,
      this.cheatFormCheat.notes, this.cheatFormCode, this.cheatFormCheat.enabled);
    if (error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      return error;
    }
    this.soundEffectManager.play(SoundEffect.CONFIRM);
    this.showCheatForm = false;
    this.refreshCheats();
    showSuccessToast(I18n.t('cheat_saved'));
    return '';
  }

  private toggleCheat(cheat: AzaharCheatInfo, enabled: boolean): void {
    if (!this.gameTitleId) {
      return;
    }
    // 开关音由调用侧统一播放（ToggleSettingItem / AzaharCheatPanel 行内 switch.onChange），此处不重复播
    if (AzaharNative.setCheatEnabled(this.gameTitleId, cheat.index, enabled)) {
      this.refreshCheats();
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('cheat_toggle_failed'));
    }
  }

  // 暂停菜单金手指分区的"全部禁用"：先弹确认（文案带启用统计），对齐详情页金手指 Tab
  private disableAllCheats(): void {
    const enabled = this.cheats.filter((cheat: AzaharCheatInfo) => cheat.enabled).length;
    this.openConfirmDialog(
      I18n.t('confirm_disable_all_cheats'),
      I18n.tf2('cheats_enabled_count_fmt', 'enabled', enabled, 'total', this.cheats.length),
      I18n.t('disable_all_cheats'),
      () => {
        this.performDisableAllCheats();
      }
    );
  }

  private performDisableAllCheats(): void {
    let failed = false;
    this.cheats.forEach((cheat: AzaharCheatInfo) => {
      if (cheat.enabled && !AzaharNative.setCheatEnabled(this.gameTitleId, cheat.index, false)) {
        failed = true;
      }
    });
    this.refreshCheats();
    if (failed) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('cheat_toggle_failed'));
    } else {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
    }
  }

  private deleteCheat(cheat: AzaharCheatInfo): void {
    this.openConfirmDialog(
      I18n.t('delete_cheat_title'),
      I18n.tf1(
        'delete_cheat_message_fmt',
        'name',
        cheat.name || I18n.t('unnamed_cheat')
      ),
      I18n.t('delete'),
      () => {
        this.performDeleteCheat(cheat);
      }
    );
  }

  private performDeleteCheat(cheat: AzaharCheatInfo): void {
    if (!this.gameTitleId) {
      return;
    }
    if (AzaharNative.removeCheat(this.gameTitleId, cheat.index)) {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      this.refreshCheats();
      showSuccessToast(I18n.t('cheat_deleted'));
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('cheat_delete_failed'));
    }
  }

  private async selectAndLoadAmiibo(): Promise<void> {
    try {
      // 对齐安卓 SAF：系统文件选择器直选 .bin，不限定固定目录
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.bin'];
      const result = await documentPicker.select(options);
      if (!result || result.length === 0) {
        return;
      }
      const path = FileManagerHelper.pathFromUri(result[0]);

      await this.uriManager.persistFilePermission(result[0]);
      if (AzaharNative.loadAmiibo(path)) {
        this.soundEffectManager.play(SoundEffect.CONFIRM);
        showSuccessToast(I18n.t('amiibo_loaded'));
        return;
      }
      this.soundEffectManager.play(SoundEffect.FAIL);
      if (!AzaharNative.isSearchingForAmiibo()) {
        showWarningToast(I18n.t('amiibo_not_requested'));
      } else {
        showErrorToast(I18n.t('amiibo_load_failed'));
      }
    } catch (error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('amiibo_select_failed_fmt', 'error', JSON.stringify(error)));
    }
  }

  private ensureDirectory(path: string): void {
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
    } catch (_error) {
      try {
        fileIo.mkdirSync(path, true);
      } catch (_mkdirError) {
        console.warn(`GameView: mkdir failed: ${(_mkdirError as Error)?.message}`);
      }
    }
  }

  // 对齐 Android：点移除直接调 NativeLibrary.removeAmiibo()，无二次确认
  private removeCurrentAmiibo(): void {
    if (AzaharNative.removeAmiibo()) {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      showSuccessToast(I18n.t('amiibo_removed'));
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('amiibo_none_to_remove'));
    }
  }

  private onXComponentLoad(context: object): void {
    const registered = AzaharNative.registerXComponent(this.xComponentId, context);
    this.surfaceReady = registered && AzaharNative.getRuntimeInfo().surfaceReady;
    this.tryStartEmulation();
    if (this.emulationStarted && !this.isPaused && this.surfaceReady) {
      this.startFramePump();
    }
  }

  private togglePause(): void {
    // 合盖=系统睡眠态，不走暂停菜单语义；开盖后恢复
    if (this.lidClosed) {
      return;
    }
    if (this.isPaused) {
      if (AzaharNative.resumeEmulation()) {
        this.playTimeManager.resumeSession();
        this.lifecycleAutoPaused = false;
        this.isPaused = false;
        this.statusText = this.getRunningStatusText();
        this.showPauseMenu = false;
        this.startFramePump();
      }
    } else {
      if (AzaharNative.pauseEmulation()) {
        this.playTimeManager.pauseSession();
        this.stopFramePump();
        this.lifecycleAutoPaused = false;
        this.isPaused = true;
        this.statusText = I18n.t('game_status_paused');
        this.showPauseMenu = true;
        this.refreshSaveStateInfo();
        this.refreshCheats();
      }
    }
  }

  private openPauseMenu(): void {
    // 合盖=系统睡眠态，不弹暂停菜单；开盖后恢复
    if (this.lidClosed) {
      return;
    }
    this.soundEffectManager.play(SoundEffect.SELECT);
    this.disableFastForward(false);
    this.disableSlowMotion(false);
    this.stopFramePump();
    if (!this.isPaused) {
      if (AzaharNative.pauseEmulation()) {
        this.playTimeManager.pauseSession();
        this.lifecycleAutoPaused = false;
        this.isPaused = true;
        this.statusText = I18n.t('game_status_paused');
      }
    }
    this.showPauseMenu = true;
    this.refreshSaveStateInfo();
    this.refreshCheats();
    this.refreshMovieStatus();
    this.releaseAllInput();
    this.loadPauseMenuExtras();
  }

  // 暂停菜单打开时加载封面图标/收藏态，避免构建期重复 IO
  private loadPauseMenuExtras(): void {
    this.isFavorite = this.gameTitleId ? GameManager.getInstance().isFavoriteTitle(this.gameTitleId) : false;
    // 暂停菜单小尺寸位统一用包体 Icon（顶部 + 存档槽位缩略图共用），封面只在详情页大图位展示
    GameManager.getInstance().getGameIcon(this.romPath)
      .then((icon: image.PixelMap | null) => {
        if (this.showPauseMenu) {
          this.gameIcon = icon;
        }
      })
      .catch(() => {});
  }

  private toggleFavorite(): void {
    if (!this.gameTitleId) {
      return;
    }
    const next = !this.isFavorite;
    this.isFavorite = next;
    GameManager.getInstance().setFavoriteTitle(this.gameTitleId, next, this.romPath);
  }

  private resumeFromPauseMenu(): void {
    // 合盖=系统睡眠态，不走暂停菜单恢复；开盖后恢复
    if (this.lidClosed) {
      return;
    }
    if (AzaharNative.resumeEmulation()) {
      this.applyResumedState();
    }
  }

  /**
   * 桌面卡片点击当前运行中的游戏时触发（Index.resumeRunningGameView 递增计数器）。
   * 关闭暂停菜单等覆盖层并恢复模拟。
   */
  private onWidgetResumeRequest(): void {
    if (this.isLeavingGame || this.isLoadingGame || !this.applicationLoaded) {
      return;
    }
    this.showPauseMenu = false;
    this.showSaveStateDetail = false;
    this.showCheatPanel = false;
    this.showCheatForm = false;
    this.showQuickActions = false;
    if (this.isPaused) {
      this.resumeFromPauseMenu();
    }
    hilog.info(0x0000, 'GameView', 'Resumed game from widget request');
  }

  /** 会话结束后刷新桌面卡片里的游玩时长 */
  private refreshWidgetPlayTime(): void {
    if (!this.romPath) {
      return;
    }
    WidgetService.refresh(this.context, GameManager.getInstance(), undefined,
      this.downloadDirManager.getDownloadDirPath()).catch((error: Error) => {
      hilog.warn(0x0000, 'GameView', 'Refresh widget play time failed: %{public}s', error.message);
    });
  }

  /** 恢复运行后的 UI/状态同步；reset 原生侧已内嵌恢复，复用同一段 */
  private applyResumedState(): void {
    this.playTimeManager.resumeSession();
    this.soundEffectManager.play(SoundEffect.BACK);
    this.lifecycleAutoPaused = false;
    this.isPaused = false;
    this.refreshMovieStatus();
    this.statusText = this.getRunningStatusText();
    this.showPauseMenu = false;
    this.showCheatPanel = false;
    this.showCheatForm = false;
    this.startFramePump();
  }

  onBackPress(): boolean {
    if (this.showQuickActions) {
      this.showQuickActions = false;
      return true;
    }
    if (this.showCheatForm) {
      this.closeCheatForm();
      return true;
    }
    if (this.showSaveStateDetail) {
      this.closeSaveStateDetail();
      return true;
    }
    if (this.showCheatPanel) {
      this.closeCheatPanel();
      return true;
    }
    if (this.showPauseMenu) {
      this.resumeFromPauseMenu();
      return true;
    }
    this.openPauseMenu();
    return true;
  }

  // 暂停菜单即第一重确认，退出不再弹二次确认（区别于安卓的三步流程）
  private exitGame(): void {
    this.soundEffectManager.play(SoundEffect.BACK);
    this.isLeavingGame = true;
    this.disableFastForward(false);
    this.disableSlowMotion(false);
    this.cancelStartupRetry();
    this.stopFramePump();
    this.releaseAllInput();
    this.setKeepScreenOn(false);
    this.playTimeManager.finishSession();
    AzaharNative.stopEmulation();
    BackgroundMusicManager.getInstance().resumeFromGame();
    router.back();
  }

  private handleVirtualKeyChange(key: AzaharKey, pressed: boolean): void {
    this.applySourceKeyChange(key, pressed, VIRTUAL_KEY_SOURCE);
  }

  /** 虚拟宏按键整组按键上报；宏是独立来源，与物理键/普通虚拟键共享持有者计数 */
  private handleMacroKeys(keys: AzaharKey[], pressed: boolean): void {
    for (let i = 0; i < keys.length; i++) {
      this.applySourceKeyChange(keys[i], pressed, MACRO_KEY_SOURCE);
    }
  }

  private handleVirtualAction(action: AzaharFrontendAction): void {
    if (action === 'more') {
      this.showQuickActions = true;
      return;
    }
    if (action === 'pause') {
      this.openPauseMenu();
      return;
    }
    if (action === 'quick_save') {
      void this.saveState(QUICK_SAVE_STATE_SLOT);
      return;
    }
    if (action === 'quick_load') {
      this.loadState(QUICK_SAVE_STATE_SLOT);
      return;
    }
    if (action === 'fast_forward') {
      this.toggleFastForward();
      return;
    }
    if (action === 'slow_motion') {
      this.toggleSlowMotion();
      return;
    }
    if (action === 'swap_screens') {
      this.toggleSwapScreens();
      return;
    }
    if (action === 'toggle_soft_input') {
      this.toggleSoftInput();
      return;
    }
    if (action === 'toggle_lid') {
      this.toggleLid();
      return;
    }
    if (action === 'toggle_microphone') {
      void this.toggleMicrophone();
      return;
    }
    if (action === 'toggle_upright_screen') {
      this.toggleUprightScreen();
      return;
    }
    if (action === 'open_settings') {
      this.openSettingsFromGame();
      return;
    }
    if (action === 'toggle_screen_orientation') {
      this.showScreenOrientationPicker();
      return;
    }
    if (action === 'reset') {
      this.resetEmulationWithPrompt();
    }
  }

  private toggleFastForward(): void {
    if (this.fastForwardEnabled) {
      this.disableFastForward(true);
      return;
    }
    // 与慢速互斥（对齐 nds）
    this.disableSlowMotion(false);
    // turbo_limit 为百分比；0 = 无限制（native GetFrameLimit()==0 不做限速）
    const turboLimit = this.settingsManager.getNumber(KEY_TURBO_LIMIT);
    const nextLimit = turboLimit >= 0 ? turboLimit : 200;
    if (!AzaharNative.setTemporaryFrameLimit(nextLimit)) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('fast_forward_enable_failed'));
      return;
    }
    this.fastForwardEnabled = true;
    this.soundEffectManager.play(SoundEffect.TOGGLE_ON);
    showSuccessToast(I18n.tf1('fast_forward_enabled_fmt', 'limit',
      nextLimit === 0 ? I18n.t('opt_unlimited') : `${nextLimit}%`));
  }

  private disableFastForward(playSound: boolean = true): void {
    if (!this.fastForwardEnabled) {
      return;
    }
    AzaharNative.disableTemporaryFrameLimit();
    this.fastForwardEnabled = false;
    if (playSound) {
      this.soundEffectManager.play(SoundEffect.TOGGLE_OFF);
    }
  }

  private toggleSlowMotion(): void {
    if (this.slowMotionEnabled) {
      this.disableSlowMotion(true);
      return;
    }
    // 与快进互斥（对齐 nds）
    this.disableFastForward(false);
    if (!AzaharNative.setTemporaryFrameLimit(SLOW_MOTION_PERCENT)) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('slow_motion_enable_failed'));
      return;
    }
    this.slowMotionEnabled = true;
    this.soundEffectManager.play(SoundEffect.TOGGLE_ON);
    showSuccessToast(I18n.tf1('slow_motion_enabled_fmt', 'limit', `${SLOW_MOTION_PERCENT}%`));
  }

  private disableSlowMotion(playSound: boolean = true): void {
    if (!this.slowMotionEnabled) {
      return;
    }
    AzaharNative.disableTemporaryFrameLimit();
    this.slowMotionEnabled = false;
    if (playSound) {
      this.soundEffectManager.play(SoundEffect.TOGGLE_OFF);
    }
  }

  /** 触控开关：运行时翻转触控层可见性（对齐 nds toggle_soft_input），
   *  softInputBehaviour 的下一次重算（手柄连接变化等）会将其归位 */
  private toggleSoftInput(): void {
    this.showOverlay = !this.showOverlay;
    this.soundEffectManager.play(this.showOverlay ? SoundEffect.TOGGLE_ON : SoundEffect.TOGGLE_OFF);
  }

  // 3DS 翻盖开关：对齐真机——合盖经 APT 睡眠协商后挂起模拟，开盖唤醒恢复
  private toggleLid(): void {
    if (this.lidClosed) {
      this.openLid();
    } else {
      this.closeLid();
    }
  }

  private closeLid(): void {
    if (!AzaharNative.setShellOpen(false)) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('lid_toggle_failed'));
      return;
    }
    this.lidClosed = true;
    this.showQuickActions = false;
    this.soundEffectManager.play(SoundEffect.TOGGLE_ON);
    this.startLidSleepWatch();
  }

  private openLid(): void {
    if (!AzaharNative.setShellOpen(true)) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('lid_toggle_failed'));
      return;
    }
    this.stopLidSleepWatch();
    this.lidClosed = false;
    this.lidSleeping = false;
    this.soundEffectManager.play(SoundEffect.TOGGLE_OFF);
    this.resumeAfterLidOpen();
    // 不打 toast：遮罩消失 + 音效已构成完整视觉/听觉反馈
  }

  /** 开盖后恢复"因睡眠而挂起"的暂停：lidSleepPaused 是本页记录的睡眠暂停；
   *  isPaused=false 但原生侧 paused 说明睡眠暂停跨页面重建丢了记账，同样恢复 */
  private resumeAfterLidOpen(): void {
    if (AzaharNative.isPaused() && (this.lidSleepPaused || !this.isPaused)) {
      if (AzaharNative.resumeEmulation()) {
        this.playTimeManager.resumeSession();
        this.lifecycleAutoPaused = false;
        this.isPaused = false;
        this.statusText = this.getRunningStatusText();
        this.startFramePump();
      }
    }
    this.lidSleepPaused = false;
  }

  /** 壳状态可能被读档等外部路径改变：UI 记账跟随 native 真值。
   *  盖合时核心侧 SyncShellStateAfterLoad 会重发睡眠协商，这里只同步 UI 态 */
  private syncLidStateWithNative(): void {
    const shellOpen = AzaharNative.getShellOpen();
    if (shellOpen === !this.lidClosed) {
      return;
    }
    this.lidClosed = !shellOpen;
    if (this.lidClosed) {
      this.startLidSleepWatch();
    } else {
      this.stopLidSleepWatch();
      this.lidSleeping = false;
      this.resumeAfterLidOpen();
    }
  }

  /** 轮询 APT 睡眠协商结果：Asleep → 挂起；回到 Awake（被拒/取消）→ 提示并保持运行 */
  private startLidSleepWatch(): void {
    this.stopLidSleepWatch();
    this.lidSleepWatchTicks = 0;
    this.lidSleepWatchSeenPending = false;
    this.lidSleepWatchTimer = setInterval(() => {
      this.lidSleepWatchTicks++;
      const state = AzaharNative.getSystemSleepState();
      if (state === LID_SLEEP_STATE_ASLEEP || this.lidSleepWatchTicks >= LID_SLEEP_WATCH_MAX_TICKS) {
        this.enterLidSleep();
        return;
      }
      if (state !== LID_SLEEP_STATE_AWAKE) {
        this.lidSleepWatchSeenPending = true;
        return;
      }
      if (this.lidSleepWatchSeenPending) {
        // 协商被游戏拒绝/取消：真机语义为保持合盖但继续运行
        this.stopLidSleepWatch();
        this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('lid_sleep_rejected'));
      }
    }, LID_SLEEP_WATCH_INTERVAL_MS);
  }

  private stopLidSleepWatch(): void {
    if (this.lidSleepWatchTimer >= 0) {
      clearInterval(this.lidSleepWatchTimer);
      this.lidSleepWatchTimer = -1;
    }
  }

  private enterLidSleep(): void {
    this.stopLidSleepWatch();
    if (this.isPaused || !this.emulationStarted) {
      return;
    }
    if (AzaharNative.pauseEmulation()) {
      this.playTimeManager.pauseSession();
      this.stopFramePump();
      this.lidSleepPaused = true;
      this.isPaused = true;
      this.lidSleeping = true;
      this.statusText = I18n.t('game_status_paused');
    }
  }

  // 麦克风开关：关闭时切到 Null 输入（游戏收静音），开启时恢复配置源；
  // 真实设备源需先走系统授权（拒绝则保持关闭），模拟源无需权限
  private async toggleMicrophone(): Promise<void> {
    if (this.microphoneEnabled) {
      this.micSavedInputType =
        this.getEffectiveNumberConfig('input_type', this.settingsManager.getNumber(KEY_AUDIO_INPUT_TYPE));
      AzaharNative.setConfig('input_type', MIC_INPUT_TYPE_NULL);
      AzaharNative.applyConfig();
      this.microphoneEnabled = false;
      this.soundEffectManager.play(SoundEffect.TOGGLE_OFF);
      showSuccessToast(I18n.t('mic_disabled'));
      return;
    }
    const gameInputType = this.gameConfigManager.getConfig(this.romPath).inputType;
    const configuredInputType = gameInputType >= 0 ? gameInputType : this.settingsManager.getNumber(KEY_AUDIO_INPUT_TYPE);
    const target = this.micSavedInputType ?? configuredInputType;
    if (target === MIC_INPUT_TYPE_NULL) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('mic_no_source'));
      return;
    }
    if (target === MIC_INPUT_TYPE_AUTO || target === MIC_INPUT_TYPE_OHOS) {
      const granted = await this.requestMicPermission();
      if (!granted) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showWarningToast(I18n.t('mic_permission_denied'));
        return;
      }
    }
    AzaharNative.setConfig('input_type', target);
    AzaharNative.applyConfig();
    this.microphoneEnabled = true;
    this.soundEffectManager.play(SoundEffect.TOGGLE_ON);
    showSuccessToast(I18n.t('mic_enabled'));
  }

  // 屏幕方向直放按钮的单选弹窗；更多面板内由 OptionMenuRow 提供同一条路径
  private showScreenOrientationPicker(): void {
    const labels: string[] = [
      I18n.t('screen_orientation_auto'),
      I18n.t('screen_orientation_portrait'),
      I18n.t('screen_orientation_landscape')
    ];
    const sheets: SheetInfo[] = ORIENTATION_VALUES.map((value: string, index: number): SheetInfo => ({
      title: labels[index],
      action: () => {
        this.applyScreenOrientationSetting(value);
      }
    }));
    this.getUIContext().showActionSheet({
      title: I18n.t('settings_screen_orientation'),
      message: '',
      autoCancel: true,
      sheets: sheets,
      systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
    });
  }

  private applyScreenOrientationSetting(value: string): void {
    if (ORIENTATION_VALUES.indexOf(value) < 0) {
      value = 'auto';
    }
    void this.settingsManager.setString(KEY_SCREEN_ORIENTATION, value);
    void this.applyScreenOrientation();
  }

  /** 当前布局已直接放置的组件集（更多面板按此过滤，对齐 nds）：自定义/默认解析结果，
   *  未初始化时按算法默认布局的 pause/fast_forward/more 槽位 */
  private quickActionPlacedComponents(): LayoutComponent[] {
    if (this.customPadComponents.length > 0) {
      return this.customPadComponents.map((c: PositionedLayoutComponent) => c.component);
    }
    return [
      LayoutComponent.BUTTON_PAUSE,
      LayoutComponent.BUTTON_FAST_FORWARD_TOGGLE,
      LayoutComponent.BUTTON_MORE
    ];
  }

  // 交换屏幕是会话级快捷操作（对齐 nds areScreensSwapped）：只写 native 暂存表不落盘，
  // 下次启动由 syncNativeSettings/applyNativeOverrides 按全局+单游戏覆盖重新播种
  private toggleSwapScreens(): void {
    const nextValue = !this.swapScreenEnabled;
    this.swapScreenEnabled = nextValue;
    AzaharNative.setConfig('swap_screen', nextValue);
    AzaharNative.applyConfig();
    this.refreshGameRect();
    this.soundEffectManager.play(nextValue ? SoundEffect.TOGGLE_ON : SoundEffect.TOGGLE_OFF);
  }

  private async toggleUprightScreen(): Promise<void> {
    const nextValue = !this.uprightScreenEnabled;
    this.uprightScreenEnabled = nextValue;
    await this.settingsManager.setBoolean(KEY_UPRIGHT_SCREEN, nextValue);
    AzaharNative.applyConfig();
    this.soundEffectManager.play(nextValue ? SoundEffect.TOGGLE_ON : SoundEffect.TOGGLE_OFF);
  }

  private openSettingsFromGame(): void {
    this.openPauseMenu();
    router.pushUrl({ url: 'pages/Settings' });
  }

  // 横屏布局循环顺序与 Android 一致（LAYOUTS_TO_CYCLE 默认值）：
  // LargeScreen -> SingleScreen -> SideScreen -> Hybrid -> Default -> Custom
  private cycleScreenLayout(): void {
    const cycleOrder: number[] = [2, 1, 3, 4, 0, 5];
    const current = this.settingsManager.getNumber(KEY_LAYOUT_OPTION);
    const pos = cycleOrder.indexOf(current);
    const next = cycleOrder[(pos + 1) % cycleOrder.length];
    void this.settingsManager.setNumber(KEY_LAYOUT_OPTION, next).then(() => {
      AzaharNative.applyConfig();
    });
  }

  // 手柄快捷键映射（gamepad_hotkey_map：action -> 物理键码），设置页可改，
  // onPageShow -> loadInputSettings 会重新加载
  private loadGamepadHotkeys(): void {
    this.gamepadHotkeyMap.clear();
    this.gamepadHotkeyEnableCode = -1;
    const raw = this.settingsManager.getString(KEY_GAMEPAD_HOTKEY_MAP);
    if (!raw) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, number>;
      for (const action of Object.keys(parsed)) {
        const code = parsed[action];
        if (typeof code !== 'number' || code <= 0) {
          continue;
        }
        if (action === 'enable') {
          this.gamepadHotkeyEnableCode = code;
        } else {
          this.gamepadHotkeyMap.set(code, action);
        }
      }
    } catch (_error) {
      console.warn(`[GameView] gamepad hotkey map parse failed, ignored: ${(_error as Error)?.message}`);
    }
  }

  private handleGamepadHotkey(event: KeyEvent, isDown: boolean): boolean {
    // 十字键码与键盘方向键同值，仅游戏手柄设备触发，避免键盘误触发
    const isDpadCode = GAMEPAD_DPAD_KEY_CODES.includes(event.keyCode);
    const gamepadEvent = !isDpadCode || this.isGamepadDeviceEvent(event);

    // Enable 修饰键：按下置位、松开复位，事件本身不进游戏（Android: handled=true）
    if (this.gamepadHotkeyEnableCode > 0 && event.keyCode === this.gamepadHotkeyEnableCode) {
      if (!gamepadEvent) {
        return false;
      }
      this.gamepadHotkeyEnabled = isDown;
      return true;
    }

    const action = this.gamepadHotkeyMap.get(event.keyCode);
    if (action === undefined || !gamepadEvent) {
      return false;
    }
    if (!isDown) {
      return this.gamepadHotkeyPressed.delete(event.keyCode);
    }
    // 已绑定 Enable 但未按住时，快捷键不触发也不吞事件（Android: 事件不进游戏但继续分发）
    if (this.gamepadHotkeyEnableCode > 0 && !this.gamepadHotkeyEnabled) {
      return false;
    }
    this.gamepadHotkeyPressed.add(event.keyCode);
    switch (action) {
      case 'toggle_pause':
        if (this.showPauseMenu) {
          this.resumeFromPauseMenu();
        } else {
          this.openPauseMenu();
        }
        break;
      case 'swap_screens':
        this.toggleSwapScreens();
        break;
      case 'cycle_layouts':
        this.cycleScreenLayout();
        break;
      case 'save_state':
        void this.saveState(QUICK_SAVE_STATE_SLOT);
        break;
      case 'load_state':
        this.loadState(QUICK_SAVE_STATE_SLOT);
        break;
      case 'fast_forward':
        this.toggleFastForward();
        break;
      case 'close_game':
        this.exitGame();
        break;
      default:
        break;
    }
    return true;
  }

  /** 物理键码 → 目标 3DS 按键列表。键盘码走用户可配置映射（一键多绑定=宏），
   *  手柄码保留内置表（手柄 gameplay 键大多在 isNativeGamepadGameplayKey 提前拦截） */
  private getPhysicalKeyBindings(keyCode: number): AzaharKey[] {
    if (keyCode < 2300) {
      return this.keyboardBindingManager.getKeys(keyCode);
    }
    for (let i = 0; i < GAMEPAD_KEY_BINDINGS.length; i++) {
      if (GAMEPAD_KEY_BINDINGS[i].keyCode === keyCode) {
        return [GAMEPAD_KEY_BINDINGS[i].key];
      }
    }
    return [];
  }

  private applySoftInputBehaviour(): void {
    if (this.softInputBehaviour === 'always_invisible') {
      this.showOverlay = false;
    } else if (this.softInputBehaviour === 'hide_system_buttons_when_controller_connected') {
      this.showOverlay = !this.isGamepadConnected;
    } else {
      this.showOverlay = true;
    }
  }

  private startGamepadMonitor(): void {
    if (this.inputDeviceListening) {
      return;
    }
    try {
      inputDevice.on('change', this.inputDeviceChangeListener);
      this.inputDeviceListening = true;
      this.syncGamepadDevices();
    } catch (err) {
      console.warn(`[GameView] Failed to register input device listener: ${String(err)}`);
    }
  }

  private stopGamepadMonitor(): void {
    if (!this.inputDeviceListening) {
      return;
    }
    try {
      inputDevice.off('change', this.inputDeviceChangeListener);
    } catch (err) {
      console.warn(`[GameView] Failed to unregister input device listener: ${String(err)}`);
    }
    this.inputDeviceListening = false;
    this.gamepadDeviceIds.clear();
  }

  private async syncGamepadDevices(): Promise<void> {
    try {
      const deviceIds: number[] = await inputDevice.getDeviceList();
      for (const deviceId of deviceIds) {
        try {
          const deviceInfo: inputDevice.InputDeviceData = await inputDevice.getDeviceInfo(deviceId);
          if (deviceInfo.sources.includes('joystick')) {
            this.gamepadDeviceIds.add(deviceId);
          }
        } catch (_err) {
          // 单个设备可能在枚举过程中被拔出；不要因此放弃其余设备。
          console.info(`[GameView] Input device disappeared during query: ${deviceId}`);
        }
      }
      this.updateGamepadConnected();
    } catch (err) {
      console.warn(`[GameView] Failed to query input devices: ${String(err)}`);
    }
  }

  private handleInputDeviceChange(event: inputDevice.DeviceListener): void {
    if (event.type === 'add') {
      this.registerGamepadDevice(event.deviceId);
      return;
    }
    if (event.type === 'remove') {
      this.gamepadDeviceIds.delete(event.deviceId);
      this.updateGamepadConnected();
    }
  }

  private async registerGamepadDevice(deviceId: number): Promise<void> {
    try {
      const deviceInfo: inputDevice.InputDeviceData = await inputDevice.getDeviceInfo(deviceId);
      if (!deviceInfo.sources.includes('joystick')) {
        return;
      }
      this.gamepadDeviceIds.add(deviceId);
      this.updateGamepadConnected();
    } catch (err) {
      console.warn(`[GameView] Failed to inspect input device ${deviceId}: ${String(err)}`);
    }
  }

  private updateGamepadConnected(): void {
    const connected = this.gamepadDeviceIds.size > 0;
    if (connected === this.isGamepadConnected) {
      return;
    }
    this.isGamepadConnected = connected;
    console.info(`[GameView] Gamepad ${connected ? 'connected' : 'disconnected'}`);
    this.applySoftInputBehaviour();
  }

  private isGamepadDeviceEvent(event: KeyEvent): boolean {
    const deviceId = event.deviceId || 0;
    if (deviceId <= 0) {
      return false;
    }

    const cached = this.gamepadDeviceCache.get(deviceId);
    if (cached !== undefined) {
      return cached;
    }

    try {
      const deviceInfo = inputDevice.getDeviceInfoSync(deviceId);
      const sources = deviceInfo.sources || [];
      const isGamepad = sources.includes('joystick');
      this.gamepadDeviceCache.set(deviceId, isGamepad);
      return isGamepad;
    } catch (_error) {
      this.gamepadDeviceCache.set(deviceId, false);
      return false;
    }
  }

  private isNativeGamepadGameplayKey(event: KeyEvent): boolean {
    const keyCode = event.keyCode;
    if (keyCode >= 2301 && keyCode <= 2312) {
      return true;
    }
    return GAMEPAD_DPAD_KEY_CODES.includes(keyCode) && this.isGamepadDeviceEvent(event);
  }

  private handlePhysicalKeyEvent(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down && event.type !== KeyType.Up) {
      return false;
    }

    const isDown = event.type === KeyType.Down;
    if (isDown && this.physicalKeysDown.has(event.keyCode)) {
      return true;
    }
    if (isDown) {
      this.physicalKeysDown.add(event.keyCode);
    } else {
      this.physicalKeysDown.delete(event.keyCode);
    }

    if (this.showCheatForm) {
      if (isDown && (event.keyCode === 2070 || event.keyCode === 2313 || event.keyCode === 2054)) {
        this.closeCheatForm();
      }
      return true;
    }

    if (this.showCheatPanel) {
      if (isDown && (event.keyCode === 2070 || event.keyCode === 2313 || event.keyCode === 2054)) {
        this.closeCheatPanel();
      }
      return true;
    }

    if (this.showSaveStateDetail) {
      if (isDown && (event.keyCode === 2070 || event.keyCode === 2313 || event.keyCode === 2054)) {
        this.closeSaveStateDetail();
      }
      return true;
    }

    if (this.showPauseMenu) {
      if (isDown && (event.keyCode === 2070 || event.keyCode === 2313 || event.keyCode === 2054)) {
        this.resumeFromPauseMenu();
      }
      return true;
    }

    // 手柄功能键全部走 gamepad_hotkey_map 配置（热键 tab 可见可改）；
    // 以下硬编码仅限键盘：F5=快速存档、F9=快速读档、F4=重置、Esc=暂停/继续
    if (this.handleGamepadHotkey(event, isDown)) {
      return true;
    }

    if (event.keyCode === 2094) {
      if (isDown) {
        void this.saveState(QUICK_SAVE_STATE_SLOT);
      }
      return true;
    }
    if (event.keyCode === 2098) {
      if (isDown) {
        this.loadState(QUICK_SAVE_STATE_SLOT);
      }
      return true;
    }
    if (event.keyCode === 2093) {
      if (isDown) {
        AzaharNative.resetEmulation();
        this.statusText = I18n.t('game_status_reset');
      }
      return true;
    }
    // 仅键盘 Escape 硬编码；手柄 Mode(2313) 的暂停/继续走 gamepad_hotkey_map
    // 默认绑定（热键 tab 可见可改），与 nds 默认映射对齐
    if (event.keyCode === 2070) {
      if (isDown) {
        if (this.showPauseMenu) {
          this.resumeFromPauseMenu();
        } else {
          this.openPauseMenu();
        }
      }
      return true;
    }

    if (this.isNativeGamepadGameplayKey(event)) {
      return true;
    }

    const keys = this.getPhysicalKeyBindings(event.keyCode);
    if (keys.length === 0) {
      return false;
    }

    for (let i = 0; i < keys.length; i++) {
      this.applySourceKeyChange(keys[i], isDown, event.keyCode);
    }
    return true;
  }

  /** 持有者计数：同一 3DS 按键被多个来源按住（物理键/虚拟键/宏）时，
   *  只有最后一个持有者松开才向 core 发 key-up，避免误释放其他来源仍按住的按键 */
  private applySourceKeyChange(key: AzaharKey, pressed: boolean, sourceId: number): void {
    let holders = this.physicalKeyHolders.get(key);
    if (!holders) {
      holders = new Set<number>();
      this.physicalKeyHolders.set(key, holders);
    }
    const wasHeld = holders.size > 0;
    if (pressed) {
      holders.add(sourceId);
    } else {
      holders.delete(sourceId);
    }
    const nowHeld = holders.size > 0;
    if (nowHeld !== wasHeld) {
      AzaharNative.sendKeyEvent(key, nowHeld);
    }
  }

  private releaseAllInput(): void {
    for (let i = 0; i < ALL_DIGITAL_KEYS.length; i++) {
      AzaharNative.sendKeyEvent(ALL_DIGITAL_KEYS[i], false);
    }
    this.physicalKeysDown.clear();
    this.physicalKeyHolders.clear();
    this.externalPressedKeys = [];
    this.externalCirclePadX = 0;
    this.externalCirclePadY = 0;
    this.externalCStickX = 0;
    this.externalCStickY = 0;
    this.gamepadHotkeyPressed.clear();
    this.gamepadHotkeyEnabled = false;
    this.gamepadDeviceCache.clear();
    this.setAnalogState(AzaharAnalog.CirclePad, 0, 0, false);
    this.setAnalogState(AzaharAnalog.CStick, 0, 0, false);
    this.setAnalogCenterOffset(AzaharAnalog.CirclePad, 0, 0);
    this.setAnalogCenterOffset(AzaharAnalog.CStick, 0, 0);
  }

  private setAnalogState(analog: AzaharAnalog, x: number, y: number, active: boolean): void {
    if (analog === AzaharAnalog.CirclePad) {
      this.circlePadOffsetX = x;
      this.circlePadOffsetY = y;
      this.circlePadActive = active;
    } else {
      this.cStickOffsetX = x;
      this.cStickOffsetY = y;
      this.cStickActive = active;
    }
    AzaharNative.sendAnalogEvent(analog, x, y);
  }

  private setAnalogCenterOffset(analog: AzaharAnalog, x: number, y: number): void {
    if (analog === AzaharAnalog.CirclePad) {
      this.circlePadCenterOffsetX = x;
      this.circlePadCenterOffsetY = y;
    } else {
      this.cStickCenterOffsetX = x;
      this.cStickCenterOffsetY = y;
    }
  }

  // 与 AzaharVirtualButtonLayer.currentPadLayout 完全一致的输入，
  // 保证触摸归一化用的摇杆尺寸 = 屏幕上实际渲染的尺寸
  private currentPadLayout(): PadLayout {
    const width = this.getOverlayWidth();
    const height = this.getOverlayHeight(width);
    const s = getOverlayControlSizes();
    const sizes: PadSizes = {
      lrW: s.lrWidth,
      lrH: s.lrHeight,
      ssW: s.ssWidth,
      ssH: s.ssHeight,
      dpad: s.dpad,
      abxy: s.abxy,
      stick: s.stick,
      cStick: s.cStick,
      small: s.action,
      turbo: s.action
    };
    return computePadLayout({
      width: width,
      height: height,
      gameRect: this.gameRect,
      sizes: sizes,
      visible: DEFAULT_PAD_VISIBILITY
    });
  }

  // px → vp：以控件区尺寸 / 帧缓冲尺寸换算，取两屏并集
  private refreshGameRect(): void {
    const layout = AzaharNative.getScreenLayout();
    let next: PadRect | null = null;
    if (layout && layout.width > 0 && layout.height > 0) {
      const width = this.getOverlayWidth();
      const height = this.getOverlayHeight(width);
      const sx = width / layout.width;
      const sy = height / layout.height;
      const rects: PadRect[] = [];
      if (layout.top) {
        rects.push({ x: layout.top.left * sx, y: layout.top.top * sy,
          w: (layout.top.right - layout.top.left) * sx, h: (layout.top.bottom - layout.top.top) * sy });
      }
      if (layout.bottom) {
        rects.push({ x: layout.bottom.left * sx, y: layout.bottom.top * sy,
          w: (layout.bottom.right - layout.bottom.left) * sx, h: (layout.bottom.bottom - layout.bottom.top) * sy });
      }
      if (rects.length > 0) {
        const l = Math.min(...rects.map((r: PadRect) => r.x));
        const t = Math.min(...rects.map((r: PadRect) => r.y));
        const rr = Math.max(...rects.map((r: PadRect) => r.x + r.w));
        const bb = Math.max(...rects.map((r: PadRect) => r.y + r.h));
        next = { x: l, y: t, w: rr - l, h: bb - t };
      }
    }
    const cur = this.gameRect;
    const same = (cur === null && next === null) ||
      (cur !== null && next !== null &&
        Math.abs(cur.x - next.x) < 0.5 && Math.abs(cur.y - next.y) < 0.5 &&
        Math.abs(cur.w - next.w) < 0.5 && Math.abs(cur.h - next.h) < 0.5);
    if (!same) {
      this.gameRect = next;
    }
  }

  private getOverlayWidth(): number {
    return this.controlsWidth > 0 ? this.controlsWidth : 360;
  }

  private getOverlayHeight(width: number): number {
    const fallback = width > 480 ? width * 9 / 16 : width * 16 / 9;
    return Math.max(1, this.controlsHeight > 0 ? this.controlsHeight : fallback);
  }

  private getAnalogTouchSize(analog: AzaharAnalog): number {
    // 优先用编辑器布局里对应摇杆的渲染尺寸，保证触摸归一化半径与画面一致
    const comp = analog === AzaharAnalog.CStick ? LayoutComponent.CSTICK : LayoutComponent.STICK;
    const custom = this.customPadComponents.find((c: PositionedLayoutComponent) => c.component === comp);
    if (custom) {
      return Math.max(1, custom.rect.width);
    }
    const pad = this.currentPadLayout();
    const controlSizes = getOverlayControlSizes();
    return analog === AzaharAnalog.CStick
      ? (pad.cStick ? pad.cStick.w : controlSizes.cStick)
      : (pad.stick ? pad.stick.w : controlSizes.stick);
  }

  private handleAnalogTouch(event: TouchEvent, analog: AzaharAnalog): void {
    event.stopPropagation();
    if (event.changedTouches.length < 1) {
      return;
    }

    if (event.type === TouchType.Down || event.type === TouchType.Move) {
      const radius = this.getAnalogTouchSize(analog) / 2;
      const touch = event.changedTouches[0];
      let centerOffsetX = analog === AzaharAnalog.CirclePad ? this.circlePadCenterOffsetX : this.cStickCenterOffsetX;
      let centerOffsetY = analog === AzaharAnalog.CirclePad ? this.circlePadCenterOffsetY : this.cStickCenterOffsetY;
      if (event.type === TouchType.Down) {
        centerOffsetX = touch.x - radius;
        centerOffsetY = touch.y - radius;
        this.setAnalogCenterOffset(analog, centerOffsetX, centerOffsetY);
      }
      const rawX = (touch.x - radius - centerOffsetX) / radius;
      const rawY = (touch.y - radius - centerOffsetY) / radius;
      const angle = Math.atan2(rawY, rawX);
      const clampedRadius = Math.min(1, Math.sqrt(rawX * rawX + rawY * rawY));
      const x = Math.cos(angle) * clampedRadius;
      const y = Math.sin(angle) * clampedRadius;
      this.setAnalogState(analog, x, y, true);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.setAnalogState(analog, 0, 0, false);
      this.setAnalogCenterOffset(analog, 0, 0);
    }
  }

  private handleRuntimeMenuAction(actionId: string): void {
    if (actionId === 'resume') {
      this.resumeFromPauseMenu();
    } else if (actionId === 'settings') {
      router.pushUrl({ url: 'pages/Settings' });
    } else if (actionId === 'touch_controls') {
      router.pushUrl({ url: 'pages/settings/DisplaySettings' });
    } else if (actionId === 'screenshot') {
      this.captureScreenshot();
    } else if (actionId === 'swap_screens') {
      this.toggleSwapScreens();
    } else if (actionId === 'rotate_upright') {
      void this.toggleUprightScreen();
    } else if (actionId === 'save_movie') {
      this.saveMovie();
    } else if (actionId === 'close_movie') {
      this.closeMovie();
    } else if (actionId === 'cheats') {
      this.openCheatPanel();
    } else if (actionId === 'amiibo_load') {
      void this.selectAndLoadAmiibo();
    } else if (actionId === 'amiibo_remove') {
      this.removeCurrentAmiibo();
    } else if (actionId === 'reset') {
      this.resetEmulationWithPrompt();
    } else if (actionId === 'exit') {
      this.exitGame();
    }
  }

  private refreshSaveStateInfo(): void {
    try {
      // 每次刷新现读槽位数量，设置页中改动在下一次打开存档面板即生效
      this.saveStateSlotCount = this.settingsManager.getNumber(KEY_SAVE_STATE_SLOT_COUNT);
      const states = AzaharNative.getSaveStateInfo(this.saveStateSlotCount);
      states.sort((left: AzaharSaveStateInfo, right: AzaharSaveStateInfo) => left.slot - right.slot);
      this.saveStateInfo = states;
    } catch (_error) {
      this.saveStateInfo = [];
    }
  }

  private refreshSaveStateInfoLater(): void {
    this.refreshSaveStateInfo();
    setTimeout(() => {
      this.refreshSaveStateInfo();
    }, 700);
  }

  private getSaveStateForSlot(slot: number): AzaharSaveStateInfo | undefined {
    for (let i = 0; i < this.saveStateInfo.length; i++) {
      if (this.saveStateInfo[i].slot === slot) {
        return this.saveStateInfo[i];
      }
    }
    return undefined;
  }

  private hasSaveState(slot: number): boolean {
    return this.getSaveStateForSlot(slot) !== undefined;
  }

  private emptySaveState(slot: number): AzaharSaveStateInfo {
    return {
      slot: slot,
      time: 0,
      status: AzaharSaveStateStatus.OK,
      buildName: '',
      fileSize: 0,
      screenshotPath: '',
      hasUndo: false
    };
  }

  private getDetailSaveState(): AzaharSaveStateInfo {
    const info = this.getSaveStateForSlot(this.detailStateSlot);
    return info || this.emptySaveState(this.detailStateSlot);
  }

  /** 槽位显示名：快速槽（0）与普通槽（1-10）分开命名，对齐桌面端 Quick Save / Slot N */
  private saveStateSlotLabel(slot: number): string {
    return slot === QUICK_SAVE_STATE_SLOT
      ? I18n.t('save_state_quick_slot')
      : I18n.tf1('save_state_slot_fmt', 'slot', slot);
  }

  private openSaveStateDetail(slot: number): void {
    this.detailStateSlot = slot;
    this.showSaveStateDetail = true;
  }

  private closeSaveStateDetail(): void {
    this.showSaveStateDetail = false;
  }

  private saveStateToSlot(slot: number): void {
    void this.saveState(slot).then((ok: boolean) => {
      if (ok) {
        this.closeSaveStateDetail();
      }
    });
  }

  private loadStateFromSlot(slot: number): void {
    if (this.loadState(slot)) {
      this.closeSaveStateDetail();
      // 对齐 nds：载入成功后关闭菜单并恢复游戏，Load 信号随首个 RunLoop 消费
      this.resumeFromPauseMenu();
    }
  }

  private deleteSaveState(slot: number): void {
    if (AzaharNative.deleteState(slot)) {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      showSuccessToast(I18n.tf1('save_state_deleted_fmt', 'slot', this.saveStateSlotLabel(slot)));
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('save_state_delete_failed_fmt', 'slot', this.saveStateSlotLabel(slot)));
    }
    this.refreshSaveStateInfo();
    this.closeSaveStateDetail();
  }

  private undoSaveState(slot: number): void {
    if (AzaharNative.undoState(slot)) {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      showSuccessToast(I18n.tf1('undo_overwrite_done_fmt', 'slot', this.saveStateSlotLabel(slot)));
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('undo_overwrite_failed_fmt', 'slot', this.saveStateSlotLabel(slot)));
    }
    this.refreshSaveStateInfo();
    this.closeSaveStateDetail();
  }

  private async saveState(slot: number): Promise<boolean> {
    if (this.saveStateSaving) {
      return false;
    }
    // 原生侧在 async work 里等 .cst 落盘 + 生成截图，期间显示加载遮罩（对齐 nds 同步保存的阻塞语义但不冻 UI）
    this.saveStateSaving = true;
    let success = false;
    try {
      success = await AzaharNative.saveState(slot);
    } finally {
      this.saveStateSaving = false;
    }
    if (success) {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      this.statusText = I18n.tf1('save_state_completed_fmt', 'slot', this.saveStateSlotLabel(slot));
      showSuccessToast(this.statusText);
      this.refreshSaveStateInfoLater();
      return true;
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('save_state_unavailable'));
      return false;
    }
  }

  // core 在 emu 线程上报的运行错误（帧泵消费）：存档类错误游戏继续运行，
  // 其余错误 native 侧已自动暂停，用户经暂停菜单决定恢复或退出（对齐 Qt 端语义）
  private onCoreRuntimeError(error: AzaharCoreError): void {
    this.soundEffectManager.play(SoundEffect.FAIL);
    let text: string;
    if (error.status === 'error_savestate_build_mismatch') {
      text = I18n.t('save_state_load_version_mismatch');
    } else if (error.status === 'error_savestate') {
      text = I18n.t('save_state_op_failed');
    } else {
      text = I18n.tf1('core_runtime_error_fmt', 'status', error.status);
    }
    this.statusText = text;
    this.soundEffectManager.play(SoundEffect.FAIL);
    showErrorToast(text);
  }

  private loadState(slot: number): boolean {
    this.refreshSaveStateInfo();
    if (!this.hasSaveState(slot)) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.tf1('save_state_slot_empty_fmt', 'slot', this.saveStateSlotLabel(slot)));
      return false;
    }
    if (AzaharNative.loadState(slot)) {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      this.statusText = I18n.tf1('load_state_requested_fmt', 'slot', this.saveStateSlotLabel(slot));
      showSuccessToast(this.statusText);
      return true;
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('load_state_unavailable'));
      return false;
    }
  }

  private resetEmulationWithPrompt(): void {
    this.openConfirmDialog(
      I18n.t('reset_game_title'),
      I18n.t('reset_game_message'),
      I18n.t('reset'),
      () => {
        // resetEmulation 原生侧已完成 pause→reset→resume（对齐 nds），成功后只需同步 UI 状态
        if (AzaharNative.resetEmulation()) {
          // reset 同步清掉速度模式（对齐 nds：重置即退出快进/慢速）
          this.soundEffectManager.play(SoundEffect.CONFIRM);
          this.disableFastForward(false);
          this.disableSlowMotion(false);
          this.applyResumedState();
          this.statusText = I18n.t('game_status_reset');
        } else {
          this.soundEffectManager.play(SoundEffect.FAIL);
          showErrorToast(I18n.t('reset_failed'));
        }
      }
    );
  }

  private getSafeScreenshotName(): string {
    const baseName = (this.gameTitle || this.romPath || 'azahar').replace(/[\\/:*?"<>|]/g, '_').trim();
    return baseName.length > 0 ? baseName : 'azahar';
  }

  private formatScreenshotTimestamp(): string {
    const date = new Date();
    const y = `${date.getFullYear()}`;
    const m = `${date.getMonth() + 1}`.padStart(2, '0');
    const d = `${date.getDate()}`.padStart(2, '0');
    const hh = `${date.getHours()}`.padStart(2, '0');
    const mm = `${date.getMinutes()}`.padStart(2, '0');
    const ss = `${date.getSeconds()}`.padStart(2, '0');
    const ms = `${date.getMilliseconds()}`.padStart(3, '0');
    return `${y}${m}${d}_${hh}${mm}${ss}${ms}`;
  }

  /** 截图全流程防重入：native 取帧 + 相册保存对话框期间屏蔽再次触发。
   *  无此守卫时第二次触发会并发第二个 showAssetsCreationDialog（系统拒绝）
   *  或与未清理的同名临时文件竞争，误报"当前无法截图" */
  private screenshotBusy: boolean = false;

  private captureScreenshot(): void {
    if (this.screenshotBusy) {
      return;
    }
    this.screenshotBusy = true;
    // 先写 cacheDir 临时文件，再由系统相册创建对话框引导用户确认保存位置
    const tmpPath = `${this.context.cacheDir}/azahar_screenshot_${this.getSafeScreenshotName()}_${this.formatScreenshotTimestamp()}.png`;
    const resolutionScale = Math.min(4, Math.max(1, Math.round(this.getEffectiveNumberConfig(
      'resolution_factor',
      this.settingsManager.getNumber(KEY_RESOLUTION_FACTOR)
    ))));
    if (!AzaharNative.captureScreenshot(tmpPath, resolutionScale)) {
      this.screenshotBusy = false;
      this.soundEffectManager.play(SoundEffect.FAIL);
      console.error(`[AzaharGameView] Native captureScreenshot returned false: ${tmpPath}`);
      showErrorToast(I18n.t('screenshot_unavailable'));
      return;
    }
    this.copyScreenshotToGallery(tmpPath)
      .catch((err: Error) => {
        showErrorToast(I18n.t('screenshot_unavailable'));
        console.error(`[AzaharGameView] Save screenshot to gallery failed: ${JSON.stringify(err)}`);
      })
      .finally(() => {
        this.screenshotBusy = false;
        try {
          if (fileIo.accessSync(tmpPath)) {
            fileIo.unlinkSync(tmpPath);
          }
        } catch (_e) {
          // 临时截图文件清理，失败可忽略
        }
      });
  }

  private async copyScreenshotToGallery(filePath: string): Promise<void> {
    const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.context);
    const photoCreationConfigs: photoAccessHelper.PhotoCreationConfig[] = [{
      title: this.getSafeScreenshotName(),
      fileNameExtension: 'png',
      photoType: photoAccessHelper.PhotoType.IMAGE,
      subtype: photoAccessHelper.PhotoSubtype.DEFAULT,
    }];

    const desFileUris: string[] =
      await phAccessHelper.showAssetsCreationDialog([filePath], photoCreationConfigs);
    if (!desFileUris || desFileUris.length === 0) {
      return;
    }

    const srcFile = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
    const desFile = fileIo.openSync(desFileUris[0], fileIo.OpenMode.WRITE_ONLY);
    try {
      fileIo.copyFileSync(srcFile.fd, desFile.fd);
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      showSuccessToast(I18n.t('screenshot_saved_gallery'));
    } finally {
      fileIo.closeSync(srcFile);
      fileIo.closeSync(desFile);
    }
  }

  private saveMovie(): void {
    if (AzaharNative.saveMovie()) {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      this.refreshMovieStatus();
      showSuccessToast(I18n.t('movie_saved'));
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('movie_no_recording'));
    }
  }

  private closeMovie(): void {
    this.openConfirmDialog(
      I18n.t('movie_close_title'),
      I18n.t('movie_close_message'),
      I18n.t('close'),
      () => {
        this.performCloseMovie();
      }
    );
  }

  private performCloseMovie(): void {
    if (AzaharNative.closeMovie()) {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      this.refreshMovieStatus();
      showSuccessToast(I18n.t('movie_closed'));
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('movie_no_active'));
    }
  }

  private uiThemeColors(): AzaharThemeColors {
    return ThemeManager.getInstance().getCurrentColors();
  }

  private openConfirmDialog(title: string, message: string, confirmText: string, onConfirm: () => void): void {
    this.getUIContext().showAlertDialog({
      title: title,
      message: message,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: confirmText,
        fontColor: TEXT_DANGER,
        action: () => {
          this.soundEffectManager.play(SoundEffect.CONFIRM);
          onConfirm();
        }
      },
      secondaryButton: {
        value: I18n.t('cancel'),
        fontColor: controlAccentOf(this.uiThemeColors()),
        action: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
        }
      },
      cancel: () => {
        this.soundEffectManager.play(SoundEffect.BACK);
      }
    });
  }

  // 游戏画面区（上下屏并集）；帧布局未就绪时回退到安全区内的控件区
  private gameDisplayArea(): PadRect {
    const g = this.gameRect;
    if (g !== null) {
      return g;
    }
    return {
      x: this.padInsetLeft,
      y: this.padInsetTop,
      w: Math.max(0, this.controlsWidth - this.padInsetLeft - this.padInsetRight),
      h: Math.max(0, this.controlsHeight - this.padInsetTop - this.padInsetBottom)
    };
  }

  private getPerformanceOverlayArea(): PadRect {
    return this.gameDisplayArea();
  }


  private getPerformanceOverlayAlignment(): Alignment {
    switch (this.performanceOverlayPosition) {
      case 1:
        return Alignment.Top;
      case 2:
        return Alignment.TopEnd;
      case 3:
        return Alignment.BottomStart;
      case 4:
        return Alignment.Bottom;
      case 5:
        return Alignment.BottomEnd;
      default:
        return Alignment.TopStart;
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      XComponent({
            id: this.xComponentId,
            type: XComponentType.SURFACE,
            libraryname: 'azahar_ohos'
          })
            .onLoad((context: object) => {
              this.onXComponentLoad(context);
            })
            .onDestroy(() => {
              this.surfaceReady = false;
              this.stopFramePump();
            })
            .width('100%')
            .height('100%')

          // 睡眠遮罩：只盖游戏画面区（真机屏幕断电），在按键层之下——
          // 虚拟按键/快捷操作照常可用，开合走翻盖按钮
          if (this.lidSleeping) {
            Column() {
              Text(I18n.t('lid_closed_overlay_hint'))
                .fontSize($r('sys.float.ohos_id_text_size_sub_title1'))
                .fontColor($r('app.color.text_on_accent'))
                .opacity(0.6)
            }
              .justifyContent(FlexAlign.Center)
              .position({ x: this.gameDisplayArea().x, y: this.gameDisplayArea().y })
              .width(this.gameDisplayArea().w)
              .height(this.gameDisplayArea().h)
              .backgroundColor($r('app.color.render_surface'))
          }

          // 加载遮罩下 @Prop 更新会延迟到遮罩关闭才下发，按键层在遮罩关闭后用最终布局一次性创建
          if (this.controlsLayoutReady && !this.isLoadingGame) {
            GameViewHud({
              controlsWidth: this.controlsWidth,
              controlsHeight: this.controlsHeight,
              padInsetLeft: this.padInsetLeft,
              padInsetTop: this.padInsetTop,
              padInsetRight: this.padInsetRight,
              padInsetBottom: this.padInsetBottom,
              gameRect: this.gameRect,
              customPadComponents: this.customPadComponents,
              inputOpacity: this.inputOpacity,
              showOverlay: this.showOverlay,
              circlePadOffsetX: this.circlePadOffsetX,
              circlePadOffsetY: this.circlePadOffsetY,
              cStickOffsetX: this.cStickOffsetX,
              cStickOffsetY: this.cStickOffsetY,
              circlePadCenterOffsetX: this.circlePadCenterOffsetX,
              circlePadCenterOffsetY: this.circlePadCenterOffsetY,
              cStickCenterOffsetX: this.cStickCenterOffsetX,
              cStickCenterOffsetY: this.cStickCenterOffsetY,
              circlePadActive: this.circlePadActive,
              cStickActive: this.cStickActive,
              fastForwardEnabled: this.fastForwardEnabled,
              swapScreenEnabled: this.swapScreenEnabled,
              slowMotionEnabled: this.slowMotionEnabled,
              microphoneEnabled: this.microphoneEnabled,
              showPauseMenu: this.showPauseMenu,
              showCheatPanel: this.showCheatPanel,
              showSaveStateDetail: this.showSaveStateDetail,
              showQuickActions: this.showQuickActions,
              hideRecoveryEntry: this.softInputBehaviour === 'always_invisible',
              performanceOverlayEnabled: this.performanceOverlayEnabled,
              performanceOverlayPosition: this.performanceOverlayPosition,
              performanceOverlayText: this.performanceOverlayText,
              perfOverlayAlignment: this.getPerformanceOverlayAlignment(),
              perfOverlayArea: this.getPerformanceOverlayArea(),
              handleAnalogTouch: (event: TouchEvent, analog: AzaharAnalog) => {
                this.handleAnalogTouch(event, analog);
              },
              handleVirtualKeyChange: (key: AzaharKey, pressed: boolean) => {
                this.handleVirtualKeyChange(key, pressed);
              },
              handleVirtualAction: (action: AzaharFrontendAction) => {
                this.handleVirtualAction(action);
              },
              macroKeys: this.virtualMacroKeys,
              externalPressedKeys: this.externalPressedKeys,
              externalCirclePadX: this.externalCirclePadX,
              externalCirclePadY: this.externalCirclePadY,
              externalCStickX: this.externalCStickX,
              externalCStickY: this.externalCStickY,
              handleMacroKeys: (keys: AzaharKey[], pressed: boolean) => {
                this.handleMacroKeys(keys, pressed);
              }
            })
          }

          // 快捷操作面板（更多按钮弹层）：组件内按 show 条件渲染居中悬浮面板，与暂停菜单并行
          GameViewQuickActions({
            show: $showQuickActions,
            placedComponents: this.quickActionPlacedComponents(),
            softInputVisible: this.showOverlay,
            fastForwardActive: this.fastForwardEnabled,
            slowMotionActive: this.slowMotionEnabled,
            microphoneActive: this.microphoneEnabled,
            onAction: (action: AzaharFrontendAction) => {
              this.handleVirtualAction(action);
            }
          })

          Column()
            .bindContentCover($$this.isLoadingGame, this.buildLoadingDialog(), {
              modalTransition: ModalTransition.NONE
            })

          Column()
            .bindContentCover($$this.saveStateSaving, this.buildSaveStateSavingDialog(), {
              modalTransition: ModalTransition.NONE
            })

      if (this.showPauseMenu) {
        GameViewOverlays({
          uiThemeColors: this.uiThemeColors(),
          gameTitle: this.gameTitle,
          gameIcon: this.$gameIcon,
          saveStates: this.saveStateInfo,
          saveStateSlotCount: this.saveStateSlotCount,
          cheats: this.cheats,
          isFavorite: this.isFavorite,
          movieMode: this.movieStatus.mode,
          soundEffectManager: this.soundEffectManager,
          saveStateToSlot: (slot: number) => { this.saveStateToSlot(slot); },
          loadStateFromSlot: (slot: number) => { this.loadStateFromSlot(slot); },
          openSaveStateDetail: (slot: number) => { this.openSaveStateDetail(slot); },
          undoSaveState: (slot: number) => { this.undoSaveState(slot); },
          screenWidth: this.controlsWidth,
          swapScreensEnabled: this.swapScreenEnabled,
          toggleCheat: (cheat: AzaharCheatInfo, enabled: boolean) => { this.toggleCheat(cheat, enabled); },
          importCheats: () => { this.importCheatFile(); },
          beginAddCheat: () => { this.beginAddCheat(); },
          disableAllCheats: () => { this.disableAllCheats(); },
          viewCheatDetail: (cheat: AzaharCheatInfo) => { this.viewCheatDetail(cheat); },
          toggleFavorite: () => { this.toggleFavorite(); },
          handleRuntimeMenuAction: (action: string) => { this.handleRuntimeMenuAction(action); }
        })
      }

      // 详情面板常驻挂载（不随暂停菜单显隐）：金手指面板由暂停菜单"管理金手指"唤起时
      // showPauseMenu 已置 false，若跟着 if 块卸载面板将永远不显示；组件内部按各 show 标志自门控
      GameViewPanels({
        uiThemeColors: this.uiThemeColors(),
        controlsWidth: this.controlsWidth,
        detailStateSlot: this.detailStateSlot,
        getDetailSaveState: (): AzaharSaveStateInfo => this.getDetailSaveState(),
        hasSaveState: (slot: number): boolean => this.hasSaveState(slot),
        gameTitle: this.gameTitle,
        gameTitleId: this.gameTitleId,
        cheats: this.cheats,
        showSaveStateDetail: $showSaveStateDetail,
        showCheatPanel: this.showCheatPanel,
        showCheatForm: $showCheatForm,
        cheatFormCheat: this.cheatFormCheat,
        cheatFormName: $cheatFormName,
        cheatFormCode: $cheatFormCode,
        soundEffectManager: this.soundEffectManager,
        closeSaveStateDetail: () => { this.closeSaveStateDetail(); },
        loadStateFromSlot: (slot: number) => { this.loadStateFromSlot(slot); },
        saveStateToSlot: (slot: number) => { this.saveStateToSlot(slot); },
        deleteSaveState: (slot: number) => { this.deleteSaveState(slot); },
        undoSaveState: (slot: number) => { this.undoSaveState(slot); },
        closeCheatPanel: () => { this.closeCheatPanel(); },
        refreshCheats: () => { this.refreshCheats(); },
        beginAddCheat: () => { this.beginAddCheat(); },
        importCheats: () => { this.importCheatFile(); },
        viewCheatDetail: (cheat: AzaharCheatInfo) => { this.viewCheatDetail(cheat); },
        toggleCheat: (cheat: AzaharCheatInfo, enabled: boolean) => { this.toggleCheat(cheat, enabled); },
        closeCheatForm: () => { this.closeCheatForm(false); },
        saveCheatForm: (): string => { return this.saveCheatForm(); },
        deleteCheatForm: () => { this.deleteCheatForm(); }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.render_surface'))
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.updateScreenRotation();
      this.setOverlayBounds(Number(newArea.width), Number(newArea.height));
    })
    .onKeyPreIme((event: KeyEvent): boolean => {
      return this.handlePhysicalKeyEvent(event);
    })
    .onKeyEventDispatch((event: KeyEvent): boolean => {
      return this.handlePhysicalKeyEvent(event);
    })
    .onKeyEvent((event: KeyEvent): void => {
      if (this.handlePhysicalKeyEvent(event)) {
        event.stopPropagation();
      }
    })
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).opacity(0)
    PageTransitionEnter({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).opacity(0)
    PageTransitionExit({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).opacity(0)
    PageTransitionExit({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).opacity(0)
  }
}

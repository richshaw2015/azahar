import { router, display, window, LengthMetrics, ColorMetrics } from '@kit.ArkUI';
import { common, bundleManager } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AppIconView } from '../components/AppIconView';
import { GlobalWallpaper } from '../components/common/GlobalWallpaper';
import { AZAHAR_CARTRIDGE_FLASH_TOTAL_DURATION_MS, AzaharCartridgeGridModelItem, AzaharCartridgeListModelItem } from '../components/game/AzaharCartridgeItem';
import { AzaharEmptySlot } from '../components/game/AzaharEmptySlot';
import { AzaharHowToGetGamesPanel } from '../components/help/AzaharHowToGetGamesPanel';
import { AzaharWebUploadPanel } from '../components/web/AzaharWebUploadPanel';
import { HomeGameCollection } from '../components/home/HomeGameCollection';
import { HomeSheets } from '../components/home/HomeSheets';
import { HomeTitleControls } from '../components/home/HomeTitleControls';
import { FloatTilesBackground } from '../components/theme/FloatTilesBackground';
import { LaunchParams } from '../entryability/EntryAbility';
import { AzaharGameCardDataSource } from '../models/AzaharGameCardDataSource';
import { AzaharGameCardModel } from '../models/AzaharGameCardModel';
import { AzaharCIAInstallStatus, AzaharNative } from '../types/AzaharNative';
import { GameDetailsTab } from '../types/GameDetailsTab';
import { HomeTab, normalizeHomeTab } from '../types/HomeTab';
import { AzaharColorMode, AzaharTheme, AzaharThemeColors } from '../types/ThemeTypes';
import { controlThemeOf, controlAccentOf } from '../components/common/AzaharControls';
import { OptionMenuRow } from '../components/common/OptionMenuControls';
import { ThemeSelector } from '../components/settings/ThemeSelector';
import { TabSegmentButtonV2, SegmentButtonV2Items, SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, HdsNavigation, HdsNavigationTitleMode, BottomBuilderShowType, hdsMaterial, ScrollEffectType, HideMode, HdsBarStyle } from '@kit.UIDesignKit';
import { COVER_RADIUS_DEFAULT, COVER_RADIUS_MAX, FONT_SIZE_SETTING_TITLE, FONT_SIZE_PAGE_TITLE, INPUT_BG_INLINE, INPUT_PADDING_H, FONT_SIZE_SETTING_DESC, FONT_SIZE_MIN, GRID_COVER_BASE, GRID_COVER_SIZE_MAX, GRID_COVER_SIZE_MIN, LIST_COVER_BASE, LIST_COVER_SIZE_MAX, LIST_COVER_SIZE_MIN, navBackIconModifier, RADIUS_DIALOG, RADIUS_FULL, SEGMENT_BAR_HEIGHT, SHEET_BG_GROUPED, SHEET_CARD_BG, TEXT_DISABLED, TEXT_DANGER, TEXT_PRIMARY, TEXT_SECONDARY, TITLE_BAR_ICON_COLOR } from '../types/UIConstants';
import { GLOBAL_WALLPAPER_URI_KEY, KEY_COVER_CORNER_RADIUS, KEY_DEFAULT_TAB, KEY_GAME_LIST_LAYOUT, KEY_GAME_LIST_SORT_ASCENDING, KEY_GAME_NAME_SOURCE, KEY_GRID_SIZE, KEY_INSERTED_CARTRIDGE, KEY_LIST_SIZE } from '../types/SettingsTypes';
import { BackgroundMusicManager } from '../utils/BackgroundMusicManager';
import { DeviceProfile } from '../utils/DeviceProfile';
import { DownloadDirManager } from '../utils/DownloadDirManager';
import { FileManagerHelper, OpenFolderResult } from '../utils/FileManagerHelper';
import { FullscreenController } from '../utils/FullscreenController';
import { GameConfigManager } from '../utils/GameConfigManager';
import { GameInfo, GameManager } from '../utils/GameManager';
import { formatLastPlayed, formatPlayTimeSummary, LegacyPlayRecord, normalizeTitleId, PlayTimeManager } from '../utils/PlayTimeManager';
import { AzaharLoadingDialog } from '../components/common/AzaharLoadingDialog';
import { I18n } from '../utils/I18nManager';
import { CoverManager } from '../utils/CoverManager';
import { extractDominantColor } from '../utils/CoverColorExtractor';
import { AppIconManager } from '../utils/AppIconManager';
import { PersistedUriManager } from '../utils/PersistedUriManager';
import { SettingsManager } from '../utils/SettingsManager';
import { SoundEffect, SoundEffectManager } from '../utils/SoundEffectManager';
import { createScrollSource, setScrollSourceActive } from '../utils/ScrollAnimationState';
import { ThemeManager } from '../utils/ThemeManager';
import { initToastHelper, showErrorToast, showInfoToast, showSuccessToast, showWarningToast } from '../utils/ToastHelper';
import { ServerInfo, ServerStatus, WebUploadServer } from '../utils/WebUploadServer';
import { WidgetService } from '../utils/WidgetService';

type LayoutType = 'grid' | 'list';

interface RoundedCornerCompat {
  type?: number;
  position?: RoundedCornerPositionCompat;
  radius?: number;
}

interface RoundedCornerPositionCompat {
  x?: number;
  y?: number;
}

interface RoundedCornerDisplayCompat {
  getRoundedCorner?: () => RoundedCornerCompat[];
}

interface RoundedCornerGeometry {
  radius: number;
  centerX: number;
  centerY: number;
}

interface BottomRoundedCornerGeometry {
  left: RoundedCornerGeometry;
  right: RoundedCornerGeometry;
}

const CORNER_TYPE_BOTTOM_RIGHT: number = 2;
const CORNER_TYPE_BOTTOM_LEFT: number = 3;
const HOME_BOTTOM_BUTTON_BASE_HORIZONTAL_PADDING: number = 16;
const HOME_BOTTOM_BUTTON_ROW_VERTICAL_PADDING: number = 8;

const GRID_CARD_BASE_WIDTH: number = GRID_COVER_BASE;
/** 滚动方向切换阈值（vp）：同向累计超过该值才触发操作栏收起/展开，防抖动 */
const ACTION_BAR_SCROLL_THRESHOLD: number = 32;
const ACTION_BAR_MINI_WIDTH: number = 56;
const ACTION_BAR_ITEM_WIDTH: number = 96;
const ACTION_BAR_CONTENT_PADDING: number = 24;
/** HDS floating bar's default edge inset, used only to center the expanded bar. */
const ACTION_BAR_DEFAULT_INSET: number = 16;

AppStorage.setOrCreate('globalWallpaperUri', '');
AppStorage.setOrCreate('globalWallpaperVersion', 0);
AppStorage.setOrCreate('coverSettingsVersion', 0);
AppStorage.setOrCreate('pendingGamePath', '');
// 桌面卡片"已运行则恢复"：GameView 活跃会话标记 + 当前 ROM 路径 + 恢复请求计数器
AppStorage.setOrCreate('gameViewActive', false);
AppStorage.setOrCreate('activeGameRomPath', '');
AppStorage.setOrCreate('widgetResumeRequest', 0);
AppStorage.setOrCreate('gameLibraryRefreshVersion', 0);
AppStorage.setOrCreate('gridSize', GRID_COVER_BASE);
AppStorage.setOrCreate('listSize', LIST_COVER_BASE);
AppStorage.setOrCreate('coverCornerRadius', COVER_RADIUS_DEFAULT);
AppStorage.setOrCreate('playStatsVersion', 0);

interface ActionBarItem {
  label: string;
  icon: Resource;
  enabled: boolean;
  action: () => void;
}

@Entry
@Component
struct Index {
  @State isInitialized: boolean = false;
  @State @Watch('updateLoadingMask') isLoading: boolean = true;
  @State @Watch('updateLoadingMask') isScanning: boolean = false;
  @State showLoadingMask: boolean = false;
  @State scanProgress: string = '';
  @State currentTabIndex: number = HomeTab.RECENT;
  @State defaultTabIndex: number = HomeTab.RECENT;
  @State isSearchMode: boolean = false;
  @State layoutType: LayoutType = 'grid';
  @State gameNameSource: string = 'metadata';
  @State appearanceMode: string = 'auto';
  @State currentThemeId: string = '';
  @State searchQuery: string = '';
  @State sortAscending: boolean = true;
  @State recentGames: GameInfo[] = [];
  @State allGames: GameInfo[] = [];
  @State recentVisibleCount: number = 0;
  @State allVisibleCount: number = 0;
  @State favoritesVisibleCount: number = 0;
  @State insertedCartridgePath: string = '';
  @State downloadDirPath: string = '';
  @State deviceType: string = 'phone';
  @State screenWidth: number = 360;
  private recentActionTabsController: HdsTabsController = new HdsTabsController();
  private allActionTabsController: HdsTabsController = new HdsTabsController();
  @State private recentActionBarCollapsed: boolean = false;
  @State private allActionBarCollapsed: boolean = false;
  @State private actionBarOffsetX: number = 0;
  private recentActionBarScrollAccum: number = 0;
  private recentActionBarScrollDirection: number = 0;
  private allActionBarScrollAccum: number = 0;
  private allActionBarScrollDirection: number = 0;
  private recentGamesScroller: Scroller = new Scroller();
  private favoritesScroller: Scroller = new Scroller();
  private allGamesScroller: Scroller = new Scroller();
  private collectionScrollSourceId: number = createScrollSource();
  @State screenHeight: number = 720;
  @State bottomRoundedCornerLeftRadiusVp: number = 0;
  @State bottomRoundedCornerLeftCenterXVp: number = 0;
  @State bottomRoundedCornerLeftCenterYVp: number = 0;
  @State bottomRoundedCornerRightRadiusVp: number = 0;
  @State bottomRoundedCornerRightCenterXVp: number = 0;
  @State bottomRoundedCornerRightCenterYVp: number = 0;
  @State themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();
  @State webUploadInfo: ServerInfo = WebUploadServer.getInstance().getServerInfo();
  @State showWebUploadPanel: boolean = false;
  @State showHowToGetGamesPanel: boolean = false;
  @State showViewOptionsSheet: boolean = false;
  @State openingGamePath: string = '';
  @State versionName: string = '';
  @StorageLink('globalWallpaperUri') globalWallpaperUri: string = '';
  @StorageLink('gridSize') @Watch('onGridSizeChange') gridSize: number = GRID_COVER_BASE;
  @StorageLink('listSize') @Watch('onListSizeChange') listSize: number = LIST_COVER_BASE;
  @StorageLink('coverCornerRadius') coverCornerRadius: number = COVER_RADIUS_DEFAULT;
  @StorageLink('safeAreaTopVp') safeAreaTopVp: number = 0;
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;
  @StorageLink('coverSettingsVersion') @Watch('onCoverSettingsVersionChange') coverSettingsVersion: number = 0;
  @StorageLink('pendingGamePath') @Watch('onPendingGamePathChange') pendingGamePath: string = '';
  @StorageLink('gameLibraryRefreshVersion') @Watch('onGameLibraryRefreshVersionChange') gameLibraryRefreshVersion: number = 0;
  @StorageLink('playStatsVersion') @Watch('onPlayStatsVersionChange') playStatsVersion: number = 0;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private uriManager: PersistedUriManager = PersistedUriManager.getInstance();
  private downloadDirManager: DownloadDirManager = DownloadDirManager.getInstance();
  private fileManagerHelper: FileManagerHelper = FileManagerHelper.getInstance();
  private gameConfigManager: GameConfigManager = GameConfigManager.getInstance();
  private gameManager: GameManager = GameManager.getInstance();
  private playTimeManager: PlayTimeManager = PlayTimeManager.getInstance();
  private themeManager: ThemeManager = ThemeManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private webUploadServer: WebUploadServer = WebUploadServer.getInstance();
  private themeChangeListener: ((theme: AzaharTheme) => void) | null = null;
  private webUploadStatusListener: ((info: ServerInfo) => void) | null = null;
  private webUploadCompleteListener: ((filename: string, size: number) => void) | null = null;
  private coverChangeListener: ((path: string) => void) | null = null;
  private windowClass: window.Window | null = null;
  private gameCardModelCache: Map<string, AzaharGameCardModel> = new Map<string, AzaharGameCardModel>();
  private recentGamesDataSource: AzaharGameCardDataSource = new AzaharGameCardDataSource();
  private favoritesGamesDataSource: AzaharGameCardDataSource = new AzaharGameCardDataSource();
  private allGamesDataSource: AzaharGameCardDataSource = new AzaharGameCardDataSource();
  private pendingOpenTimer: number = 0;

  // 桌面卡片换游戏：等待旧 GameView 销毁期间记录最新的待启动路径
  private pendingWidgetRelaunchPath: string = '';
  private widgetRelaunchWaiting: boolean = false;

  async aboutToAppear(): Promise<void> {
    initToastHelper(this.getUIContext());
    FileManagerHelper.initAppName(this.context);
    this.loadVersionName();
    await this.initWindowState();
    await this.initializeApp();
  }

  aboutToDisappear(): void {
    setScrollSourceActive(this.collectionScrollSourceId, false);
    if (this.pendingOpenTimer) {
      clearTimeout(this.pendingOpenTimer);
      this.pendingOpenTimer = 0;
    }
    if (this.themeChangeListener) {
      this.themeManager.removeListener(this.themeChangeListener);
      this.themeChangeListener = null;
    }
    if (this.webUploadStatusListener) {
      this.webUploadServer.removeStatusListener(this.webUploadStatusListener);
    }
    try {
      this.windowClass?.off('windowSizeChange');
    } catch (_e) {
      // 注销监听幂等，失败可忽略
      this.webUploadStatusListener = null;
    }
    if (this.webUploadCompleteListener) {
      this.webUploadServer.removeUploadCompleteListener(this.webUploadCompleteListener);
      this.webUploadCompleteListener = null;
    }
    if (this.coverChangeListener) {
      CoverManager.getInstance().removeCoverChangeCallback(this.coverChangeListener);
      this.coverChangeListener = null;
    }
  }

  /**
   * 搜索模式下优先关闭搜索，避免系统返回手势直接退出应用
   */
  onBackPress(): boolean {
    if (this.isSearchMode || this.searchQuery.length > 0) {
      this.closeSearchMode();
      return true;
    }
    return false;
  }

  private closeSearchMode(): void {
    this.isSearchMode = false;
    this.setSearchQuery('');
  }

  onPageShow(): void {
    FullscreenController.getInstance().disableFullscreen().catch((error: Error) => {
      console.error(`[AzaharIndex] disable fullscreen failed: ${error.message}`);
    });
    BackgroundMusicManager.getInstance().resumeFromGame();
    this.refreshLayoutSetting();
    this.refreshGameNameSourceSetting();
    this.refreshCoverScaleSettings();
    this.refreshSortSetting();
    this.recentGames = this.gameManager.getRecentGames();
    this.refreshPlayStats();
    this.syncFavoriteFlags();
    this.syncInsertedCartridgeFlags();
    this.refreshHomeDataSources();
    this.updateScreenMetrics();
    this.processPendingWidgetLaunch();
  }

  private async initWindowState(): Promise<void> {
    try {
      this.windowClass = await window.getLastWindow(this.context);
      this.windowClass.on('windowSizeChange', (_size: window.Size) => {
        this.updateScreenMetrics();
      });
    } catch (_error) {
      this.windowClass = null;
    }
    this.updateScreenMetrics();
  }

  private loadVersionName(): void {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.versionName = bundleInfo.versionName || '1.0.0';
    } catch (_error) {
      this.versionName = '1.0.0';
    }
  }

  private updateScreenMetrics(): void {
    try {
      if (this.windowClass) {
        const props = this.windowClass.getWindowProperties();
        const rect = props.drawableRect && props.drawableRect.width > 0 ? props.drawableRect : props.windowRect;
        const density = display.getDefaultDisplaySync().densityPixels || 1;
        this.screenWidth = Math.round(rect.width / density);
        this.screenHeight = Math.round(rect.height / density);
        this.updateBottomRoundedCornerInsets();
        return;
      }
      const d = display.getDefaultDisplaySync();
      const density = d.densityPixels || 1;
      this.screenWidth = Math.round(d.width / density);
      this.screenHeight = Math.round(d.height / density);
      this.updateBottomRoundedCornerInsets();
    } catch (_error) {
      console.warn(`updateBottomRoundedCornerInsets failed: ${(_error as Error)?.message}`);
    }
  }

  private updateBottomRoundedCornerInsets(): void {
    const geometry = this.readBottomRoundedCornerGeometryVp();
    if (geometry.left.radius !== this.bottomRoundedCornerLeftRadiusVp ||
      geometry.left.centerX !== this.bottomRoundedCornerLeftCenterXVp ||
      geometry.left.centerY !== this.bottomRoundedCornerLeftCenterYVp ||
      geometry.right.radius !== this.bottomRoundedCornerRightRadiusVp ||
      geometry.right.centerX !== this.bottomRoundedCornerRightCenterXVp ||
      geometry.right.centerY !== this.bottomRoundedCornerRightCenterYVp) {
      this.bottomRoundedCornerLeftRadiusVp = geometry.left.radius;
      this.bottomRoundedCornerLeftCenterXVp = geometry.left.centerX;
      this.bottomRoundedCornerLeftCenterYVp = geometry.left.centerY;
      this.bottomRoundedCornerRightRadiusVp = geometry.right.radius;
      this.bottomRoundedCornerRightCenterXVp = geometry.right.centerX;
      this.bottomRoundedCornerRightCenterYVp = geometry.right.centerY;
    }
  }

  private readBottomRoundedCornerGeometryVp(): BottomRoundedCornerGeometry {
    const emptyCorner: RoundedCornerGeometry = { radius: 0, centerX: 0, centerY: 0 };
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      const roundedCornerDisplay = defaultDisplay as Object as RoundedCornerDisplayCompat;
      if (!roundedCornerDisplay.getRoundedCorner) {
        return { left: emptyCorner, right: emptyCorner };
      }

      const densityPixels = defaultDisplay.densityPixels > 0 ? defaultDisplay.densityPixels : 1;
      const displayWidthPx = defaultDisplay.width;
      const displayHeightPx = defaultDisplay.height;
      const corners = roundedCornerDisplay.getRoundedCorner();
      let left: RoundedCornerGeometry = emptyCorner;
      let right: RoundedCornerGeometry = emptyCorner;
      for (const corner of corners) {
        const radius = Number(corner.radius ?? 0);
        if (radius <= 0) {
          continue;
        }
        const centerXPx = Number(corner.position?.x ??
          (corner.type === CORNER_TYPE_BOTTOM_RIGHT ? displayWidthPx - radius : radius));
        const centerYPx = Number(corner.position?.y ?? displayHeightPx - radius);
        const nextGeometry: RoundedCornerGeometry = {
          radius: radius / densityPixels,
          centerX: centerXPx / densityPixels,
          centerY: centerYPx / densityPixels
        };
        if (corner.type === CORNER_TYPE_BOTTOM_LEFT) {
          if (nextGeometry.radius > left.radius) {
            left = nextGeometry;
          }
        } else if (corner.type === CORNER_TYPE_BOTTOM_RIGHT) {
          if (nextGeometry.radius > right.radius) {
            right = nextGeometry;
          }
        }
      }
      return { left, right };
    } catch (_error) {
      return { left: emptyCorner, right: emptyCorner };
    }
  }

  private getHomeBottomButtonLeftPadding(bottomPadding: number): number {
    const cornerInset = this.calculateBottomLeftRoundedCornerInset(bottomPadding);
    return Math.max(HOME_BOTTOM_BUTTON_BASE_HORIZONTAL_PADDING, cornerInset);
  }

  private getHomeBottomButtonRightPadding(bottomPadding: number): number {
    const cornerInset = this.calculateBottomRightRoundedCornerInset(bottomPadding);
    return Math.max(HOME_BOTTOM_BUTTON_BASE_HORIZONTAL_PADDING, cornerInset);
  }

  private calculateBottomLeftRoundedCornerInset(bottomPadding: number): number {
    if (this.bottomRoundedCornerLeftRadiusVp <= 0 || this.screenHeight <= 0) {
      return 0;
    }
    const y = this.screenHeight - Math.max(0, bottomPadding);
    if (y <= this.bottomRoundedCornerLeftCenterYVp) {
      return 0;
    }
    const dy = y - this.bottomRoundedCornerLeftCenterYVp;
    if (dy >= this.bottomRoundedCornerLeftRadiusVp) {
      return Math.max(0, Math.ceil(this.bottomRoundedCornerLeftCenterXVp));
    }
    const radius = this.bottomRoundedCornerLeftRadiusVp;
    const arcOffset = Math.sqrt(Math.max(0, radius * radius - dy * dy));
    return Math.max(0, Math.ceil(this.bottomRoundedCornerLeftCenterXVp - arcOffset));
  }

  private calculateBottomRightRoundedCornerInset(bottomPadding: number): number {
    if (this.bottomRoundedCornerRightRadiusVp <= 0 || this.screenWidth <= 0 || this.screenHeight <= 0) {
      return 0;
    }
    const y = this.screenHeight - Math.max(0, bottomPadding);
    if (y <= this.bottomRoundedCornerRightCenterYVp) {
      return 0;
    }
    const dy = y - this.bottomRoundedCornerRightCenterYVp;
    if (dy >= this.bottomRoundedCornerRightRadiusVp) {
      return Math.max(0, Math.ceil(this.screenWidth - this.bottomRoundedCornerRightCenterXVp));
    }
    const radius = this.bottomRoundedCornerRightRadiusVp;
    const arcOffset = Math.sqrt(Math.max(0, radius * radius - dy * dy));
    const safeRightX = this.bottomRoundedCornerRightCenterXVp + arcOffset;
    return Math.max(0, Math.ceil(this.screenWidth - safeRightX));
  }

  private async initializeApp(): Promise<void> {
    this.isLoading = true;
    try {
      await this.settingsManager.initialize(this.context);
      await this.soundEffectManager.initialize(this.context);
      await BackgroundMusicManager.getInstance().initialize(this.context);
      await this.uriManager.initialize(this.context);
      await this.downloadDirManager.initialize(this.context);
      await this.initializeTheme();
      this.restoreHomePreferences();
      this.initializeWebUploadListeners();
      this.restoreGlobalWallpaper();

      this.deviceType = DeviceProfile.getDeviceType();
      this.insertedCartridgePath = this.settingsManager.getString(KEY_INSERTED_CARTRIDGE);
      this.initializeCoverListener();
      CoverManager.getInstance().initialize(this.context).catch((err: Error) => {
        console.error(`[AzaharIndex] CoverManager init failed: ${err.message}`);
      });
      await this.gameManager.initialize(this.context);
      await this.gameConfigManager.initialize(this.context);
      // 游玩统计独立于最近列表持久化；首次升级时继承已有的最后游玩时间和启动次数
      await this.playTimeManager.init(this.context);
      this.playTimeManager.seedLegacyRecords(this.gameManager.getRecentGames().map(
        (game: GameInfo) => new LegacyPlayRecord(game.path, game.lastPlayed, game.playCount)));
      this.recentGames = this.gameManager.getRecentGames();
      this.syncInsertedCartridgeFlags();
      this.refreshHomeDataSources();
      AppIconManager.getInstance().refreshStyleProp();

      if (!this.downloadDirManager.isInitialized()) {
        await this.initializeDownloadDir();
      } else {
        this.downloadDirPath = this.downloadDirManager.getDownloadDirPath();
        this.gameManager.ensureLibraryDirectories(this.downloadDirPath);
        if (!this.initializeNativeRuntime(this.downloadDirPath)) {
          this.soundEffectManager.play(SoundEffect.FAIL);
          showErrorToast(I18n.t('native_init_failed'));
          return;
        }
        this.refreshPlayStats();
        this.refreshGameIcons(this.recentGames);
        this.refreshGameCovers(this.recentGames);
        this.refreshHomeDataSources();
        await this.scanAllGames();
      }

      await this.refreshWidgetData();
      this.processPendingWidgetLaunch();
    } catch (error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('init_failed_fmt', 'error', JSON.stringify(error)));
    } finally {
      this.isLoading = false;
    }
  }

  private initializeNativeRuntime(userDir: string): boolean {
    this.deviceType = DeviceProfile.getDeviceType();
    this.isInitialized = AzaharNative.initEmulator(
      this.context.filesDir,
      this.context.cacheDir,
      userDir,
      this.deviceType,
      this.settingsManager.getTabletJitUserEnabled(this.deviceType)
    );
    if (this.isInitialized) {
      this.settingsManager.syncNativeSettings(this.deviceType);
    }
    return this.isInitialized;
  }

  private ensureNativeRuntime(): boolean {
    const info = AzaharNative.getRuntimeInfo();
    if (info.initialized) {
      return true;
    }
    if (!this.downloadDirPath) {
      return false;
    }
    return this.initializeNativeRuntime(this.downloadDirPath);
  }

  private restoreHomePreferences(): void {
    const savedLayout = this.settingsManager.getString(KEY_GAME_LIST_LAYOUT);
    this.layoutType = savedLayout === 'list' ? 'list' : 'grid';
    this.gameNameSource = this.normalizeGameNameSource(this.settingsManager.getString(KEY_GAME_NAME_SOURCE));
    AppStorage.setOrCreate('gridSize', this.normalizeCoverSize(this.settingsManager.getNumber(KEY_GRID_SIZE), true));
    AppStorage.setOrCreate('listSize', this.normalizeCoverSize(this.settingsManager.getNumber(KEY_LIST_SIZE), false));
    AppStorage.setOrCreate('coverCornerRadius', this.normalizeCoverRadius(this.settingsManager.getNumber(KEY_COVER_CORNER_RADIUS)));
    const savedTab = this.settingsManager.getNumber(KEY_DEFAULT_TAB);
    this.defaultTabIndex = normalizeHomeTab(savedTab);
    this.currentTabIndex = this.defaultTabIndex;
    this.sortAscending = this.settingsManager.getBoolean(KEY_GAME_LIST_SORT_ASCENDING);
  }

  private normalizeGameNameSource(source: string): string {
    return source === 'filename' ? 'filename' : 'metadata';
  }

  private normalizeCoverSize(size: number, isGrid: boolean): number {
    if (size !== size) {
      return isGrid ? GRID_COVER_BASE : LIST_COVER_BASE;
    }
    const min = isGrid ? GRID_COVER_SIZE_MIN : LIST_COVER_SIZE_MIN;
    const max = isGrid ? GRID_COVER_SIZE_MAX : LIST_COVER_SIZE_MAX;
    return Math.round(Math.max(min, Math.min(max, size)));
  }

  private normalizeCoverRadius(radius: number): number {
    if (radius !== radius) {
      return COVER_RADIUS_DEFAULT;
    }
    return Math.max(0, Math.min(COVER_RADIUS_MAX, radius));
  }

  private refreshLayoutSetting(): void {
    const savedLayout = this.settingsManager.getString(KEY_GAME_LIST_LAYOUT);
    const nextLayout: LayoutType = savedLayout === 'list' ? 'list' : 'grid';
    if (nextLayout !== this.layoutType) {
      this.layoutType = nextLayout;
    }
  }

  private refreshGameNameSourceSetting(): void {
    const nextSource = this.normalizeGameNameSource(this.settingsManager.getString(KEY_GAME_NAME_SOURCE));
    if (nextSource === this.gameNameSource) {
      return;
    }
    this.gameNameSource = nextSource;
    this.refreshHomeDataSources();
    this.refreshWidgetData().catch((error: Error) => {
      console.error(`[AzaharIndex] refresh widget after name source change failed: ${error.message}`);
    });
  }

  private refreshCoverScaleSettings(): void {
    const nextGridSize = this.normalizeCoverSize(this.settingsManager.getNumber(KEY_GRID_SIZE), true);
    if (nextGridSize !== this.gridSize) {
      AppStorage.setOrCreate('gridSize', nextGridSize);
    }
    const nextListSize = this.normalizeCoverSize(this.settingsManager.getNumber(KEY_LIST_SIZE), false);
    if (nextListSize !== this.listSize) {
      AppStorage.setOrCreate('listSize', nextListSize);
    }
    const nextCoverRadius = this.normalizeCoverRadius(this.settingsManager.getNumber(KEY_COVER_CORNER_RADIUS));
    if (nextCoverRadius !== this.coverCornerRadius) {
      AppStorage.setOrCreate('coverCornerRadius', nextCoverRadius);
    }
  }

  private refreshSortSetting(): void {
    const next = this.settingsManager.getBoolean(KEY_GAME_LIST_SORT_ASCENDING);
    if (next === this.sortAscending) {
      return;
    }
    this.sortAscending = next;
    this.refreshHomeDataSources();
  }

  private onGridSizeChange(): void {
    if (this.layoutType !== 'grid') {
      return;
    }
    this.notifyCardScaleChanged();
  }

  private onListSizeChange(): void {
    if (this.layoutType !== 'list') {
      return;
    }
    this.notifyCardScaleChanged();
  }

  private notifyCardScaleChanged(): void {
    this.notifyDataSourceItemsChanged(this.recentGamesDataSource);
    this.notifyDataSourceItemsChanged(this.favoritesGamesDataSource);
    this.notifyDataSourceItemsChanged(this.allGamesDataSource);
  }

  private notifyDataSourceItemsChanged(dataSource: AzaharGameCardDataSource): void {
    for (let i = 0; i < dataSource.size(); i++) {
      dataSource.notifyItemChange(i);
    }
  }

  private persistHomeString(key: string, value: string): void {
    this.settingsManager.setString(key, value).catch((error: Error) => {
      console.error(`[AzaharIndex] persist ${key} failed: ${error.message}`);
    });
  }

  private persistHomeNumber(key: string, value: number): void {
    this.settingsManager.setNumber(key, value).catch((error: Error) => {
      console.error(`[AzaharIndex] persist ${key} failed: ${error.message}`);
    });
  }

  private persistHomeBoolean(key: string, value: boolean): void {
    this.settingsManager.setBoolean(key, value).catch((error: Error) => {
      console.error(`[AzaharIndex] persist ${key} failed: ${error.message}`);
    });
  }

  private async initializeTheme(): Promise<void> {
    await this.themeManager.initialize(this.context);
    this.themeColors = this.themeManager.getCurrentColors();
    this.appearanceMode = this.themeManager.getColorMode();
    this.currentThemeId = this.themeManager.getCurrentTheme().id;
    if (!this.themeChangeListener) {
      this.themeChangeListener = (theme: AzaharTheme) => {
        this.themeColors = this.themeManager.getCurrentColors();
        this.appearanceMode = this.themeManager.getColorMode();
        this.currentThemeId = theme.id;
        // 同步桌面卡片的主题色（空态渐变 + cell 占位渐变）
        this.refreshWidgetData().catch(() => {});
      };
      this.themeManager.addListener(this.themeChangeListener);
    }
  }

  private restoreGlobalWallpaper(): void {
    const savedWallpaperUri = this.settingsManager.getString(GLOBAL_WALLPAPER_URI_KEY);
    if (!savedWallpaperUri.startsWith('file://')) {
      AppStorage.setOrCreate('globalWallpaperUri', '');
      AppStorage.setOrCreate('globalWallpaperVersion', Date.now());
      return;
    }

    const savedWallpaperPath = savedWallpaperUri.substring('file://'.length);
    try {
      if (fileIo.accessSync(savedWallpaperPath)) {
        AppStorage.setOrCreate('globalWallpaperUri', savedWallpaperUri);
        AppStorage.setOrCreate('globalWallpaperVersion', Date.now());
        return;
      }
    } catch (_error) {
      console.warn(`Index: operation failed: ${(_error as Error)?.message}`);
    }
    AppStorage.setOrCreate('globalWallpaperUri', '');
    AppStorage.setOrCreate('globalWallpaperVersion', Date.now());
  }

  private initializeWebUploadListeners(): void {
    this.webUploadInfo = this.webUploadServer.getServerInfo();
    if (!this.webUploadStatusListener) {
      this.webUploadStatusListener = (info: ServerInfo) => {
        this.webUploadInfo = info;
      };
      this.webUploadServer.addStatusListener(this.webUploadStatusListener);
    }
    if (!this.webUploadCompleteListener) {
      this.webUploadCompleteListener = (_filename: string, _size: number) => {
        this.scanAllGames();
      };
      this.webUploadServer.addUploadCompleteListener(this.webUploadCompleteListener);
    }
  }

  private async initializeDownloadDir(): Promise<void> {
    this.isLoading = true;
    try {
      const path = await this.downloadDirManager.initDownloadDirectory();
      if (!path) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showWarningToast(I18n.t('download_dir_not_set_cannot_scan'));
        return;
      }
      this.downloadDirPath = path;
      this.gameManager.ensureLibraryDirectories(path);
      if (!this.initializeNativeRuntime(path)) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('native_init_failed'));
        return;
      }
      await this.gameManager.initialize(this.context);
      await this.gameConfigManager.initialize(this.context);
      this.recentGames = this.gameManager.getRecentGames();
      this.refreshPlayStats();
      this.syncInsertedCartridgeFlags();
      this.refreshGameIcons(this.recentGames);
      this.refreshGameCovers(this.recentGames);
      this.refreshHomeDataSources();
      await this.scanAllGames();
    } catch (error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('init_download_dir_failed_fmt', 'error', JSON.stringify(error)));
    } finally {
      this.isLoading = false;
    }
  }

  private async scanAllGames(): Promise<void> {
    if (!this.downloadDirPath) {
      return;
    }

    this.isScanning = true;
    this.scanProgress = '';
    try {
      this.allGames = await this.gameManager.scanDirectory(this.downloadDirPath, (done: number, total: number) => {
        this.scanProgress = `${done} / ${total}`;
      });
      this.refreshPlayStats();
      this.syncInsertedCartridgeFlags();
      this.refreshHomeDataSources();
      this.refreshGameIcons(this.allGames);
      this.refreshGameCovers(this.allGames);
      CoverManager.getInstance().checkAllCovers(this.allGames).catch((error: Error) => {
        console.error(`[AzaharIndex] load covers failed: ${error.message}`);
      });
      await this.refreshWidgetData();
    } catch (error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('scan_failed_fmt', 'error', JSON.stringify(error)));
    } finally {
      this.isScanning = false;
    }
  }

  private refreshGameLibrary(): void {
    if (this.isScanning || !this.downloadDirPath) {
      return;
    }
    this.scanAllGames();
  }

  private async selectRomFile(): Promise<void> {
    const selectedUri = await this.selectFileFromDownload(this.gameManager.getInstallableSuffixFilters());
    if (selectedUri) {
      await this.persistAndOpen(selectedUri);
    }
  }

  private async openDownloadDir(): Promise<void> {
    const result: OpenFolderResult = await this.openDownloadFolder(this.gameManager.getInstallableSuffixFilters());
    if (result.selectedUri) {
      await this.persistAndOpen(result.selectedUri);
    } else {
      showInfoToast(result.message);
    }
  }

  private async selectFileFromDownload(fileSuffixFilters: string[]): Promise<string> {
    if (!this.downloadDirPath) {
      await this.initializeDownloadDir();
      if (!this.downloadDirPath) {
        return '';
      }
    }
    const result: OpenFolderResult = await this.selectFromDownloadFolder(fileSuffixFilters);
    if (!result.selectedUri) {
      if (!result.success) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(result.message);
      }
      return '';
    }
    const selectedPath = FileManagerHelper.pathFromUri(result.selectedUri);
    if (!this.isInsideDownloadDir(selectedPath)) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('select_file_in_download'));
      return '';
    }
    return result.selectedUri;
  }

  private async openDownloadFolder(fileSuffixFilters?: string[]): Promise<OpenFolderResult> {
    const downloadDirUri = this.downloadDirManager.getDownloadDirUri();
    if (downloadDirUri) {
      return this.fileManagerHelper.openFolder(this.context, downloadDirUri, fileSuffixFilters);
    }
    return this.fileManagerHelper.openFolderByPath(this.context, this.downloadDirPath, fileSuffixFilters);
  }

  private async selectFromDownloadFolder(fileSuffixFilters?: string[]): Promise<OpenFolderResult> {
    const downloadDirUri = this.downloadDirManager.getDownloadDirUri();
    if (downloadDirUri) {
      return this.fileManagerHelper.selectFileInFolder(this.context, downloadDirUri, fileSuffixFilters);
    }
    return this.fileManagerHelper.selectFileInFolder(this.context, this.downloadDirPath, fileSuffixFilters);
  }

  private isInsideDownloadDir(path: string): boolean {
    if (!this.downloadDirPath || !path) {
      return false;
    }
    return path === this.downloadDirPath || path.startsWith(`${this.downloadDirPath}/`);
  }

  private async persistAndOpen(uri: string): Promise<void> {
    const path = FileManagerHelper.pathFromUri(uri);
    if (!this.isInsideDownloadDir(path)) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('select_3ds_app_in_download'));
      return;
    }
    await this.openGame(path, uri);
  }

  private async openGame(path: string, uri: string = ''): Promise<void> {
    if (!path) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('select_3ds_app'));
      return;
    }

    if (path.startsWith('file://')) {
      await this.persistAndOpen(path);
      return;
    }

    if (this.gameManager.isCiaPath(path)) {
      await this.installCiaAndLaunch(path);
      return;
    }

    if (this.gameManager.isInstalledTitlePath(path)) {
      const metadata = AzaharNative.getGameMetadata(path);
      if (!metadata.titleId || metadata.encrypted) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(metadata.encrypted ? I18n.t('content_encrypted') :
          I18n.t('load_error_unsupported_format'));
        return;
      }
    }

    if (!this.isInsideDownloadDir(path)) {
      await this.uriManager.activatePermissionForPath(path);
    }
    const appInfo = AzaharNative.getAppInfo(path);
    if (!appInfo.supported) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('unsupported_format_fmt', 'format', appInfo.extension || 'unknown'));
      return;
    }

    await this.gameManager.addToRecentGames(uri, path);
    this.recentGames = this.gameManager.getRecentGames();
    this.refreshPlayStats();
    this.syncInsertedCartridgeFlags();
    this.refreshHomeDataSources();
    this.refreshGameIcons(this.recentGames);
    this.refreshGameCovers(this.recentGames);
    await this.refreshWidgetData();
    this.soundEffectManager.play(SoundEffect.CONFIRM);
    await BackgroundMusicManager.getInstance().pauseForGame();

    router.pushUrl({
      url: 'pages/GameView',
      params: { romPath: path }
    }).catch((error: Error) => {
      BackgroundMusicManager.getInstance().resumeFromGame();
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('open_failed_fmt', 'error', error.message));
    });
  }

  private describeCIAInstallStatus(status: AzaharCIAInstallStatus): string {
    switch (status) {
      case AzaharCIAInstallStatus.Success:
        return I18n.t('cia_install_success');
      case AzaharCIAInstallStatus.ErrorEncrypted:
        return I18n.t('cia_install_encrypted');
      case AzaharCIAInstallStatus.ErrorInvalid:
        return I18n.t('cia_install_invalid');
      case AzaharCIAInstallStatus.ErrorAborted:
        return I18n.t('cia_install_aborted');
      case AzaharCIAInstallStatus.ErrorFileNotFound:
        return I18n.t('cia_install_file_not_found');
      case AzaharCIAInstallStatus.ErrorFailedToOpenFile:
        return I18n.t('cia_install_open_failed');
      default:
        return I18n.t('cia_install_failed');
    }
  }

  /**
   * 点击 .cia 对用户透明：静默安装后直接启动安装产物，安装过程不需要用户感知。
   * 找不到安装产物（多内容包、已卸载残留 key 等）时退回原有「安装成功」提示。
   */
  private async installCiaAndLaunch(path: string): Promise<void> {
    if (!this.ensureNativeRuntime()) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('native_init_failed'));
      return;
    }

    const titleId = normalizeTitleId(AzaharNative.getGameMetadata(path).titleId);
    this.isScanning = true;
    this.scanProgress = I18n.t('cia_installing');
    try {
      const status = await this.gameManager.installCiaFile(path);
      if (status !== AzaharCIAInstallStatus.Success) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(this.describeCIAInstallStatus(status));
        return;
      }

      await this.scanAllGames();
      const installedGame = titleId
        ? this.allGames.find((game: GameInfo) =>
            game.installed && normalizeTitleId(game.titleId) === titleId)
        : undefined;
      if (!installedGame) {
        this.soundEffectManager.play(SoundEffect.CONFIRM);
        showSuccessToast(this.describeCIAInstallStatus(status));
        return;
      }

      this.isScanning = false;
      this.scanProgress = '';
      await this.openGame(installedGame.path, installedGame.uri);
    } catch (error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('cia_install_failed_fmt', 'error', JSON.stringify(error)));
    } finally {
      this.isScanning = false;
      this.scanProgress = '';
    }
  }

  private openGameDetailsWithFlash(game: GameInfo): void {
    if (this.openingGamePath) {
      return;
    }
    this.soundEffectManager.play(SoundEffect.DECIDE);
    this.openingGamePath = game.path;
    if (this.pendingOpenTimer) {
      clearTimeout(this.pendingOpenTimer);
    }
    this.pendingOpenTimer = setTimeout(() => {
      this.openingGamePath = '';
      this.pendingOpenTimer = 0;
      this.navigateToGameConfig(game, GameDetailsTab.DETAILS);
    }, AZAHAR_CARTRIDGE_FLASH_TOTAL_DURATION_MS);
  }

  private navigateToGameConfig(game: GameInfo, defaultTab: GameDetailsTab): void {
    router.pushUrl({
      url: 'pages/settings/GameConfigSettings',
      params: {
        romPath: game.path,
        gameName: game.name,
        titleId: game.titleId,
        extdataId: game.extdataId,
        favorite: this.gameManager.isFavorite(game),
        productCode: game.productCode,
        installed: game.installed,
        defaultTab
      }
    }).catch((error: Error) => {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('open_details_failed_fmt', 'error', error.message));
    });
  }

  private ensureDirectory(path: string): void {
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
    } catch (_error) {
      try {
        fileIo.mkdirSync(path, true);
      } catch (error) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.tf1('create_dir_failed_fmt', 'error', (error as Error).message));
      }
    }
  }

  @Builder
  private buildLoadingDialog(): void {
    AzaharLoadingDialog({
      text: this.isScanning
        ? I18n.tf1('scanning_games_fmt', 'progress', this.scanProgress)
        : I18n.t('initializing_game_library')
    })
  }

  private updateLoadingMask(): void {
    this.showLoadingMask = this.isLoading || this.isScanning;
  }

  private getGameDisplayName(game: GameInfo): string {
    return this.gameManager.getDisplayName(game);
  }

  private getGameSubtitle(game: GameInfo): string {
    const parts: string[] = [];
    const secondary = game.publisher || game.regions || formatLastPlayed(game.lastPlayed);
    if (secondary) {
      parts.push(secondary);
    }
    const playTime = formatPlayTimeSummary(game.playTimeMs);
    if (playTime) {
      parts.push(playTime);
    }
    return parts.join(' · ');
  }

  private refreshPlayStats(): void {
    this.recentGames = this.gameManager.refreshPlayStats(this.recentGames);
    this.allGames = this.gameManager.refreshPlayStats(this.allGames);
  }

  private onPlayStatsVersionChange(): void {
    this.refreshPlayStats();
  }

  private getGameModel(game: GameInfo): AzaharGameCardModel {
    const displayName = this.getGameDisplayName(game);
    const subtitle = this.getGameSubtitle(game);
    let model = this.gameCardModelCache.get(game.path);
    if (!model) {
      model = new AzaharGameCardModel(game, displayName, subtitle);
      this.gameCardModelCache.set(game.path, model);
      return model;
    }
    model.gameInfo = game;
    model.updateDisplay(displayName, subtitle);
    return model;
  }

  private getFilteredRecentGames(): GameInfo[] {
    // 最近游玩保持 addToRecentGames 的 unshift 顺序（最新在前），不参与名称排序
    return this.filterGames(this.recentGames);
  }

  private getFilteredFavoriteGames(): GameInfo[] {
    // 收藏保持收藏时间倒序（getFavoriteGames 已按 favoriteTitleIds 插入序排好），不参与名称排序
    return this.filterGames(this.gameManager.getFavoriteGames(this.allGames));
  }

  private refreshGameIcons(games: GameInfo[]): void {
    const pendingGames = games.filter((game: GameInfo) => {
      const model = this.getGameModel(game);
      return !model.gameIcon;
    }).slice(0, 80);

    for (const game of pendingGames) {
      this.gameManager.getGameIcon(game.path).then((icon: image.PixelMap | null) => {
        if (icon) {
          const model = this.getGameModel(game);
          model.gameIcon = icon;
          this.notifyArtworkChanged(game.path);
          if (!model.coverColor) {
            this.updateCoverColor(model, icon);
          }
        }
      }).catch((error: Error) => {
        console.error(`[AzaharIndex] load icon failed: ${error.message}`);
      });
    }
  }

  private refreshGameCovers(games: GameInfo[]): void {
    if (!this.downloadDirPath) {
      return;
    }
    const pendingGames = games.filter((game: GameInfo) => {
      const model = this.getGameModel(game);
      return !model.coverImage;
    }).slice(0, 80);

    for (const game of pendingGames) {
      this.gameManager.getGameCover(game, this.downloadDirPath).then((cover: image.PixelMap | null) => {
        if (cover) {
          const model = this.getGameModel(game);
          model.coverImage = cover;
          this.notifyArtworkChanged(game.path);
          this.updateCoverColor(model, cover);
        }
      }).catch((error: Error) => {
        console.error(`[AzaharIndex] load cover failed: ${error.message}`);
      });
    }
  }

  /** 注册在线封面下载完成回调：封面到位后精准刷新对应卡片的封面图与主题色 */
  private initializeCoverListener(): void {
    if (this.coverChangeListener) {
      return;
    }
    this.coverChangeListener = (path: string) => {
      const model = this.gameCardModelCache.get(path);
      if (!model) {
        return;
      }
      // 先失效按 path 的封面缓存：画质回退可能缓存过另一画质的兜底图，
      // covers/<id>/ 本地文件要能替换它（本地封面 > 包体 icon）
      this.gameManager.clearGameCoverCache(path);
      this.gameManager.getGameCover(model.gameInfo, this.downloadDirPath).then((cover: image.PixelMap | null) => {
        if (cover) {
          model.coverImage = cover;
          this.notifyArtworkChanged(path);
          this.updateCoverColor(model, cover);
        }
      }).catch((error: Error) => {
        console.error(`[AzaharIndex] update cover failed: ${error.message}`);
      });
    };
    CoverManager.getInstance().addCoverChangeCallback(this.coverChangeListener);
  }

  private updateCoverColor(model: AzaharGameCardModel, source: image.PixelMap): void {
    extractDominantColor(source).then((color: string | null) => {
      if (color) {
        model.coverColor = color;
      }
    }).catch((_err: Error) => {
    });
  }

  private notifyArtworkChanged(path: string): void {
    const recentIndex = this.recentGamesDataSource.indexOfPath(path);
    if (recentIndex >= 0) {
      this.recentGamesDataSource.notifyItemChange(recentIndex);
    }
    const favoritesIndex = this.favoritesGamesDataSource.indexOfPath(path);
    if (favoritesIndex >= 0) {
      this.favoritesGamesDataSource.notifyItemChange(favoritesIndex);
    }
    const allIndex = this.allGamesDataSource.indexOfPath(path);
    if (allIndex >= 0) {
      this.allGamesDataSource.notifyItemChange(allIndex);
    }
  }

  private syncFavoriteFlags(): void {
    const syncList = (games: GameInfo[]): GameInfo[] => {
      return games.map((game: GameInfo) => {
        game.favorite = this.gameManager.isFavorite(game);
        return game;
      });
    };
    this.recentGames = syncList(this.recentGames);
    this.allGames = syncList(this.allGames);
    this.gameCardModelCache.forEach((model: AzaharGameCardModel) => {
      model.gameInfo.favorite = this.gameManager.isFavorite(model.gameInfo);
    });
  }

  private syncInsertedCartridgeFlags(): void {
    this.insertedCartridgePath = this.settingsManager.getString(KEY_INSERTED_CARTRIDGE);
    const syncList = (games: GameInfo[]): GameInfo[] => {
      return games.map((game: GameInfo) => {
        game.inserted = game.insertable && this.insertedCartridgePath.length > 0 &&
          game.path === this.insertedCartridgePath;
        return game;
      });
    };
    this.recentGames = syncList(this.recentGames);
    this.allGames = syncList(this.allGames);
    this.gameCardModelCache.forEach((model: AzaharGameCardModel) => {
      model.gameInfo.inserted = model.gameInfo.insertable &&
        this.insertedCartridgePath.length > 0 && model.gameInfo.path === this.insertedCartridgePath;
    });
  }

  private onCoverSettingsVersionChange(): void {
    this.gameManager.clearGameCoverCache();
    this.gameCardModelCache.forEach((model: AzaharGameCardModel) => {
      model.coverImage = undefined;
      model.coverColor = '';
      this.notifyArtworkChanged(model.gameInfo.path);
      if (model.gameIcon) {
        this.updateCoverColor(model, model.gameIcon);
      }
    });
    this.refreshGameCovers(this.recentGames);
    this.refreshGameCovers(this.allGames);
    CoverManager.getInstance().checkAllCovers(this.allGames).catch((error: Error) => {
      console.error(`[AzaharIndex] reload covers failed: ${error.message}`);
    });
    this.refreshWidgetData().catch((error: Error) => {
      console.error(`[AzaharIndex] refresh widget after cover change failed: ${error.message}`);
    });
  }

  private async refreshWidgetData(): Promise<void> {
    await WidgetService.refresh(this.context, this.gameManager, this.allGames, this.downloadDirPath);
  }

  private onPendingGamePathChange(): void {
    this.processPendingWidgetLaunch();
  }

  private onGameLibraryRefreshVersionChange(): void {
    if (this.downloadDirPath && !this.isScanning) {
      this.scanAllGames();
    }
  }

  /**
   * 处理桌面卡片点击启动游戏。
   * 冷启动时 onPageShow 可能早于初始化完成；未就绪时保留 pendingGamePath，等初始化完成后再处理。
   * 同一游戏已在运行时跳过重新加载、直接恢复已有会话；
   * 不同游戏则先弹回首页销毁旧会话，再启动新游戏，避免在运行中的 GameView 上叠加新页面。
   */
  private processPendingWidgetLaunch(): void {
    const pendingPath = LaunchParams.fromCard && LaunchParams.gamePath
      ? LaunchParams.gamePath
      : AppStorage.get<string>('pendingGamePath');
    if (!pendingPath || !this.isInitialized) {
      return;
    }
    this.consumePendingWidgetLaunch();

    // 上一次换游戏还在等旧会话销毁：只更新待启动路径，销毁完成后启动最新的
    if (this.widgetRelaunchWaiting) {
      this.pendingWidgetRelaunchPath = pendingPath;
      return;
    }

    if (AppStorage.get<boolean>('gameViewActive')) {
      const activeRomPath = AppStorage.get<string>('activeGameRomPath') ?? '';
      if (activeRomPath === pendingPath) {
        this.resumeRunningGameView();
      } else {
        this.relaunchRunningGameView(pendingPath);
      }
      return;
    }

    this.launchWidgetGame(pendingPath);
  }

  private consumePendingWidgetLaunch(): void {
    LaunchParams.gamePath = '';
    LaunchParams.fromCard = false;
    AppStorage.set('pendingGamePath', '');
  }

  /**
   * 同一游戏已在运行：弹回被设置等子页面覆盖的 GameView，并请求其关闭覆盖层、恢复模拟。
   */
  private resumeRunningGameView(): void {
    try {
      const state = router.getState();
      if (state.name !== 'GameView' && !`${state.path}${state.name}`.endsWith('GameView')) {
        router.back({ url: 'pages/GameView' });
      }
    } catch (error) {
      console.warn(`[AzaharIndex] pop back to GameView failed: ${(error as Error).message}`);
    }
    AppStorage.set('widgetResumeRequest', Date.now());
    console.info('[AzaharIndex] widget tap: game already running, resuming session');
  }

  /**
   * 不同游戏：弹回首页触发旧 GameView 销毁（aboutToDisappear 清理原生会话），
   * 待会话销毁完成后再走正常启动流程。连续点击不同卡片时以最新的路径为准。
   */
  private relaunchRunningGameView(pendingPath: string): void {
    this.pendingWidgetRelaunchPath = pendingPath;
    if (this.widgetRelaunchWaiting) {
      return;
    }
    try {
      const state = router.getState();
      if (state.name !== 'Index' && !`${state.path}${state.name}`.endsWith('pages/Index')) {
        router.back({ url: 'pages/Index' });
      }
    } catch (error) {
      console.warn(`[AzaharIndex] pop back to Index failed: ${(error as Error).message}`);
    }
    this.widgetRelaunchWaiting = true;
    this.launchAfterGameViewTeardown(40);
  }

  private launchAfterGameViewTeardown(attemptsLeft: number): void {
    if (AppStorage.get<boolean>('gameViewActive') && attemptsLeft > 0) {
      setTimeout(() => this.launchAfterGameViewTeardown(attemptsLeft - 1), 50);
      return;
    }
    this.widgetRelaunchWaiting = false;
    const pendingPath = this.pendingWidgetRelaunchPath;
    this.pendingWidgetRelaunchPath = '';
    if (!pendingPath) {
      return;
    }
    if (attemptsLeft <= 0) {
      console.warn('[AzaharIndex] timed out waiting for GameView teardown, launching anyway');
    }
    this.launchWidgetGame(pendingPath);
  }

  /**
   * 从桌面卡片启动游戏：带上已知的 uri（若有）帮助权限激活与最近列表匹配。
   */
  private launchWidgetGame(path: string): void {
    const knownGame = this.findGameByPath(path);
    this.openGame(path, knownGame?.uri ?? '').catch((error: Error) => {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('widget_launch_failed_fmt', 'error', error.message));
    });
  }

  private findGameByPath(path: string): GameInfo | undefined {
    return this.recentGames.find((game: GameInfo) => game.path === path) ||
      this.allGames.find((game: GameInfo) => game.path === path);
  }

  private getFilteredAllGames(): GameInfo[] {
    return this.sortGames(this.filterGames(this.allGames));
  }

  private filterGames(games: GameInfo[]): GameInfo[] {
    const query = this.searchQuery.trim().toLowerCase();
    if (!query) {
      return games;
    }
    return games.filter((game: GameInfo) => {
      return this.getGameDisplayName(game).toLowerCase().includes(query) ||
        game.name.toLowerCase().includes(query) ||
        game.fileName.toLowerCase().includes(query) ||
        game.path.toLowerCase().includes(query) ||
        game.titleId.toLowerCase().includes(query) ||
        game.publisher.toLowerCase().includes(query) ||
        game.regions.toLowerCase().includes(query);
    });
  }

  private sortGames(games: GameInfo[]): GameInfo[] {
    const sorted = games.slice();
    const direction = this.sortAscending ? 1 : -1;
    sorted.sort((a: GameInfo, b: GameInfo) => direction * a.name.localeCompare(b.name));
    return sorted;
  }

  private getGameModels(games: GameInfo[]): AzaharGameCardModel[] {
    return games.map((game: GameInfo) => this.getGameModel(game));
  }

  private refreshHomeDataSources(): void {
    const recentModels = this.getGameModels(this.getFilteredRecentGames());
    const favoriteModels = this.getGameModels(this.getFilteredFavoriteGames());
    const allModels = this.getGameModels(this.getFilteredAllGames());
    this.recentVisibleCount = recentModels.length;
    this.favoritesVisibleCount = favoriteModels.length;
    this.allVisibleCount = allModels.length;
    this.recentGamesDataSource.reloadAll(recentModels);
    this.favoritesGamesDataSource.reloadAll(favoriteModels);
    this.allGamesDataSource.reloadAll(allModels);
    if (!this.isActionBarCollapsed()) {
      this.actionBarOffsetX = this.getActionBarExpandedOffset();
    }
  }

  private setSearchQuery(value: string): void {
    if (this.searchQuery === value) {
      return;
    }
    this.searchQuery = value;
    this.refreshHomeDataSources();
  }

  private getActionBarBottomMargin(): number {
    return Math.max(8, this.safeAreaBottomVp);
  }

  // miniBarStyle/applyMiniBarStyle 仅 HdsTabs 宽度 <600vp 生效（HdsTabs 文档）；
  // ≥600vp 迷你栏恒为展开态、收起动效无效，此时让工具栏常驻展开——不收起、
  // 图标不置透明、不做手动 translate（系统对展开组整体底部居中）
  private isActionBarNarrow(): boolean {
    return this.screenWidth < 600;
  }

  private isActionBarCollapsed(tab: HomeTab = this.currentTabIndex): boolean {
    if (!this.isActionBarNarrow()) {
      return false;
    }
    if (tab === HomeTab.ALL) {
      return this.allActionBarCollapsed;
    }
    if (tab === HomeTab.RECENT) {
      return this.recentActionBarCollapsed;
    }
    return false;
  }

  private setActionBarCollapsed(collapsed: boolean, tab: HomeTab = this.currentTabIndex): void {
    if (tab === HomeTab.ALL) {
      this.allActionBarCollapsed = collapsed;
    } else if (tab === HomeTab.RECENT) {
      this.recentActionBarCollapsed = collapsed;
    }
  }

  private getActionTabsController(tab: HomeTab = this.currentTabIndex): HdsTabsController {
    return tab === HomeTab.RECENT ? this.recentActionTabsController : this.allActionTabsController;
  }

  private resetActionBarScrollState(tab: HomeTab): void {
    if (tab === HomeTab.ALL) {
      this.allActionBarScrollAccum = 0;
      this.allActionBarScrollDirection = 0;
    } else if (tab === HomeTab.RECENT) {
      this.recentActionBarScrollAccum = 0;
      this.recentActionBarScrollDirection = 0;
    }
  }

  private getActionBarWidth(tab: HomeTab = this.currentTabIndex): number {
    return this.buildToolBarItems(tab).length * ACTION_BAR_ITEM_WIDTH + ACTION_BAR_CONTENT_PADDING;
  }

  private getActionBarExpandedOffset(tab: HomeTab = this.currentTabIndex): number {
    if (!this.isActionBarNarrow()) {
      return 0;
    }
    // 用组件实测宽度（onAreaChange）：自由多窗/分屏下窗口宽≠整块屏幕宽。
    // <600vp 时 barSideMargin 默认 16vp（HdsTabs 文档分档：600-840→24，>840→32）
    const centeredOffset = (this.screenWidth - this.getActionBarWidth(tab)) / 2 - ACTION_BAR_DEFAULT_INSET;
    return Math.max(0, centeredOffset);
  }

  /**
   * 首页列表滚动驱动底部操作栏收起为小圆钮/展开回完整工具栏。
   * scrollOffset 为每帧偏移增量（vp）：内容上移为正触发收起，
   * 反向滑动为负触发展开；方向反转时清零累计，需同向累计超过阈值才切换，避免边界抖动。
   * 收藏页不展示操作栏，其滚动不参与累计。
   */
  private onHomeCollectionScrollDelta(deltaY: number): void {
    if (this.currentTabIndex === HomeTab.FAVORITES || !this.isActionBarNarrow()) {
      return;
    }
    const isAllTab = this.currentTabIndex === HomeTab.ALL;
    let scrollDirection = isAllTab ? this.allActionBarScrollDirection : this.recentActionBarScrollDirection;
    let scrollAccum = isAllTab ? this.allActionBarScrollAccum : this.recentActionBarScrollAccum;
    const direction = deltaY > 0 ? 1 : -1;
    if (direction !== scrollDirection) {
      scrollDirection = direction;
      scrollAccum = 0;
    }
    scrollAccum += Math.abs(deltaY);
    if (isAllTab) {
      this.allActionBarScrollDirection = scrollDirection;
      this.allActionBarScrollAccum = scrollAccum;
    } else {
      this.recentActionBarScrollDirection = scrollDirection;
      this.recentActionBarScrollAccum = scrollAccum;
    }
    if (scrollAccum < ACTION_BAR_SCROLL_THRESHOLD) {
      return;
    }
    if (isAllTab) {
      this.allActionBarScrollAccum = 0;
    } else {
      this.recentActionBarScrollAccum = 0;
    }
    if (direction > 0) {
      this.collapseActionBar();
    } else {
      this.expandActionBar();
    }
  }

  /** 滚动时在完整 Tab 栏与居中的迷你箭头之间切换。 */
  private collapseActionBar(): void {
    if (this.isActionBarCollapsed()) {
      return;
    }
    this.setActionBarCollapsed(true);
    this.getActionTabsController().applyMiniBarStyle(HdsBarStyle.EXPAND);
  }

  private expandActionBar(): void {
    if (!this.isActionBarCollapsed()) {
      this.actionBarOffsetX = this.getActionBarExpandedOffset();
      return;
    }
    this.setActionBarCollapsed(false);
    this.actionBarOffsetX = this.getActionBarExpandedOffset();
    this.getActionTabsController().applyMiniBarStyle(HdsBarStyle.COLLAPSE);
  }

  private applyHomeLayout(layout: LayoutType): void {
    if (layout === this.layoutType) {
      return;
    }
    this.layoutType = layout;
    this.persistHomeString('game_list_layout', layout);
  }

  private applyCoverSize(size: number, persist: boolean): void {
    const isGrid = this.layoutType === 'grid';
    const next = this.normalizeCoverSize(size, isGrid);
    AppStorage.setOrCreate(isGrid ? 'gridSize' : 'listSize', next);
    if (persist) {
      this.persistHomeNumber(isGrid ? 'grid_size' : 'list_size', next);
    }
  }

  private applyCoverCornerRadius(radius: number, persist: boolean): void {
    const next = this.normalizeCoverRadius(radius);
    AppStorage.setOrCreate('coverCornerRadius', next);
    if (persist) {
      this.persistHomeNumber('cover_corner_radius', next);
    }
  }

  private applyGameNameSource(source: string): void {
    const next = this.normalizeGameNameSource(source);
    if (next === this.gameNameSource) {
      return;
    }
    this.gameNameSource = next;
    this.refreshHomeDataSources();
    this.persistHomeString('game_name_source', next);
    this.refreshWidgetData().catch((error: Error) => {
      console.error(`[AzaharIndex] refresh widget after name source change failed: ${error.message}`);
    });
  }

  private applyAppearanceMode(index: number): void {
    const next: AzaharColorMode = index === 1 ? 'light' : (index === 2 ? 'dark' : 'auto');
    if (next === this.appearanceMode) {
      return;
    }
    this.appearanceMode = next;
    this.themeManager.setColorMode(next).catch((error: Error) => {
      console.error(`[AzaharIndex] apply appearance mode failed: ${error.message}`);
    });
  }

  private applyTheme(themeId: string): void {
    if (themeId === this.currentThemeId) {
      return;
    }
    this.currentThemeId = themeId;
    this.themeManager.setTheme(themeId).catch((error: Error) => {
      console.error(`[AzaharIndex] apply theme failed: ${error.message}`);
    });
  }

  private getWebUploadTargetPath(): string {
    return this.downloadDirPath ? `${this.downloadDirPath}/roms` : '';
  }

  private async openWebUploadPanel(): Promise<void> {
    if (!this.downloadDirPath) {
      await this.initializeDownloadDir();
    }
    if (!this.downloadDirPath) {
      return;
    }
    this.ensureDirectory(this.getWebUploadTargetPath());
    this.showWebUploadPanel = true;
  }

  private openHowToGetGamesPanel(): void {
    this.showHowToGetGamesPanel = true;
  }

  private showClearRecentGamesDialog(): void {
    this.getUIContext().showAlertDialog({
      title: I18n.t('clear_history'),
      message: I18n.t('clear_history_confirm'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: I18n.t('clear_history_ok'),
        fontColor: TEXT_DANGER,
        action: () => {
          this.soundEffectManager.play(SoundEffect.CONFIRM);
          this.clearAllRecentGames();
        }
      },
      secondaryButton: {
        value: I18n.t('cancel'),
        fontColor: controlAccentOf(this.themeColors),
        action: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
        }
      },
      cancel: () => {
        this.soundEffectManager.play(SoundEffect.BACK);
      }
    });
  }

  private async clearAllRecentGames(): Promise<void> {
    await this.gameManager.clearRecentGames();
    this.recentGames = [];
    this.refreshHomeDataSources();
    await this.refreshWidgetData();
  }

  private closeWebUploadPanel(): void {
    this.showWebUploadPanel = false;
    this.webUploadInfo = this.webUploadServer.getServerInfo();
  }

  private buildToolBarItems(tab: HomeTab = this.currentTabIndex): ActionBarItem[] {
    const kind = tab === HomeTab.RECENT ? 'recent' : 'all';
    const items: ActionBarItem[] = [];
    if (kind === 'all') {
      items.push({
        label: I18n.t('refresh'),
        icon: $r('sys.symbol.arrow_clockwise'),
        enabled: true,
        action: () => {
          this.refreshGameLibrary();
        }
      });
      items.push({
        label: this.webUploadInfo.status === ServerStatus.RUNNING ? I18n.t('uploading') : I18n.t('upload'),
        icon: $r('sys.symbol.upload'),
        enabled: true,
        action: () => {
          this.openWebUploadPanel();
        }
      });
      items.push({
        label: I18n.t('help'),
        icon: $r('sys.symbol.questionmark_circle'),
        enabled: true,
        action: () => {
          this.openHowToGetGamesPanel();
        }
      });
    } else {
      items.push({
        label: I18n.t('load_game'),
        icon: $r('sys.symbol.doc'),
        enabled: !this.isLoading,
        action: () => {
          this.selectRomFile();
        }
      });
      if (this.getFilteredRecentGames().length > 0) {
        items.push({
          label: I18n.t('clear_history'),
          icon: $r('sys.symbol.trash'),
          enabled: true,
          action: () => {
            this.showClearRecentGamesDialog();
          }
        });
      }
    }
    return items;
  }

  /** 迷你栏只作为 HDS 的状态触发器，箭头叠加在原生迷你按钮上。 */
  @Builder
  private ActionBarMiniBar() {
    Blank()
  }

  @Builder
  private ActionBarCollapseOverlay() {
    Row() {
      Row() {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(22)
          .fontColor([TEXT_PRIMARY])
      }
      .width(ACTION_BAR_MINI_WIDTH)
      .height(ACTION_BAR_MINI_WIDTH)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(ACTION_BAR_MINI_WIDTH)
    .translate({ x: this.actionBarOffsetX })
    .justifyContent(FlexAlign.Start)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16 })
    .margin({ bottom: this.getActionBarBottomMargin() })
    .opacity(this.isActionBarCollapsed() ? 1 : 0)
    .animation({ duration: 250, curve: Curve.EaseInOut })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  private getCurrentCollectionScroller(): Scroller {
    if (this.currentTabIndex === HomeTab.RECENT) {
      return this.recentGamesScroller;
    }
    if (this.currentTabIndex === HomeTab.FAVORITES) {
      return this.favoritesScroller;
    }
    return this.allGamesScroller;
  }


  @Builder
  private SearchTitleBuilder() {
    HomeTitleControls({
      part: 'search',
      themeColors: this.themeColors,
      currentTabIndex: $currentTabIndex,
      titleBarWidthVp: this.screenWidth,
      searchQuery: this.searchQuery,
      soundEffectManager: this.soundEffectManager,
      setSearchQuery: (value: string) => {
        this.setSearchQuery(value);
      }
    })
  }

  @Builder
  private HomeTitleSectionBuilder() {
    HomeTitleControls({
      part: 'title',
      themeColors: this.themeColors,
      currentTabIndex: $currentTabIndex,
      titleBarWidthVp: this.screenWidth,
      soundEffectManager: this.soundEffectManager
    })
  }

  @Builder
  private HomeSegmentBarBuilder() {
    HomeTitleControls({
      part: 'segment',
      themeColors: this.themeColors,
      currentTabIndex: $currentTabIndex,
      allVisibleCount: this.allVisibleCount,
      recentVisibleCount: this.recentVisibleCount,
      favoritesVisibleCount: this.favoritesVisibleCount,
      soundEffectManager: this.soundEffectManager
    })
  }

  @Builder
  private ActionBarTabsBuilder(tab: HomeTab) {
    HdsTabs({ controller: this.getActionTabsController(tab) }) {
      ForEach(this.buildToolBarItems(tab), (item: ActionBarItem) => {
        TabContent() {
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier(item.icon)
            .fontColor(this.isActionBarCollapsed(tab)
              ? [Color.Transparent]
              : (item.enabled ? [TEXT_PRIMARY] : [TEXT_DISABLED]))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE),
          selected: new SymbolGlyphModifier(item.icon)
            .fontColor(this.isActionBarCollapsed(tab)
              ? [Color.Transparent]
              : (item.enabled ? [TEXT_PRIMARY] : [TEXT_DISABLED]))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        }, item.label).labelStyle({
          selectedColor: this.isActionBarCollapsed(tab)
            ? Color.Transparent
            : (item.enabled ? TEXT_PRIMARY : TEXT_DISABLED),
          unselectedColor: this.isActionBarCollapsed(tab)
            ? Color.Transparent
            : (item.enabled ? TEXT_PRIMARY : TEXT_DISABLED)
        }))
      }, (item: ActionBarItem) => `${item.label}:${item.enabled}`)
    }
    .id(tab === HomeTab.RECENT ? 'recentActionBar' : 'allActionBar')
    .vertical(false)
    .scrollable(false)
    .animationDuration(0)
    .barPosition(BarPosition.End)
    .barOverlap(true)
    .barFloatingStyle({
      barWidth: {
        smallWidth: this.getActionBarWidth(tab),
        mediumWidth: this.getActionBarWidth(tab),
        largeWidth: this.getActionBarWidth(tab)
      },
      barBottomMargin: this.getActionBarBottomMargin(),
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      },
      // ≥600vp 时迷你栏恒为展开态且无法控制，不配置它——页签栏单独显示
      miniBar: this.isActionBarNarrow() ? {
        miniBarBuilder: () => this.ActionBarMiniBar(),
        enableMiniBarBackground: false,
        miniBarWidth: {
          smallWidth: ACTION_BAR_MINI_WIDTH,
          mediumWidth: ACTION_BAR_MINI_WIDTH,
          largeWidth: ACTION_BAR_MINI_WIDTH
        },
        onBarStyleChange: (miniBarStyle: HdsBarStyle) => {
          if (this.currentTabIndex === tab) {
            this.setActionBarCollapsed(miniBarStyle === HdsBarStyle.EXPAND, tab);
          }
        },
        onTabBarAnimationStart: (style: HdsBarStyle) => {
          if (this.currentTabIndex !== tab) {
            return;
          }
          const targetOffset = style === HdsBarStyle.EXPAND ? 0 : this.getActionBarExpandedOffset(tab);
          animateTo({ duration: 250, curve: Curve.EaseInOut }, () => {
            this.actionBarOffsetX = targetOffset;
          });
        }
      } : undefined
    })
    .onContentWillChange(() => true)
    .onTabBarClick((index: number) => {
      const items = this.buildToolBarItems(tab);
      if (index >= 0 && index < items.length && items[index].enabled) {
        this.soundEffectManager.play(SoundEffect.DECIDE);
        items[index].action();
      }
    })
    .height(130)
    .translate({ x: this.actionBarOffsetX })
    .onAppear(() => {
      if (this.currentTabIndex === tab) {
        this.actionBarOffsetX = this.getActionBarExpandedOffset(tab);
        if (this.isActionBarNarrow()) {
          this.getActionTabsController(tab).applyMiniBarStyle(
            this.isActionBarCollapsed(tab) ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE);
        }
      }
    })
    .hitTestBehavior(HitTestMode.Transparent)
    this.ActionBarCollapseOverlay()
  }

  build() {
    Stack() {
      if (this.globalWallpaperUri) {
        GlobalWallpaper()
      } else {
        FloatTilesBackground({ themeColors: this.themeColors })
      }

      HdsNavigation() {
        Stack({ alignContent: Alignment.Bottom }) {
          Column() {
            Tabs({ barPosition: BarPosition.Start, index: this.currentTabIndex }) {
              TabContent() {
                HomeGameCollection({
                  dataSource: this.recentGamesDataSource,
                  scroller: this.recentGamesScroller,
                  isEmpty: this.getFilteredRecentGames().length === 0,
                  emptyTitle: I18n.t('empty_recent_title'),
                  emptyDesc: I18n.t('empty_recent_desc'),
                  showDir: false,
                  downloadDirPath: this.downloadDirPath,
                  layoutType: this.layoutType,
                  openingGamePath: this.openingGamePath,
                  collectionScrollSourceId: this.collectionScrollSourceId,
                  themeColors: this.themeColors,
                  soundEffectManager: this.soundEffectManager,
                  screenWidth: this.screenWidth,
                  openGame: (path: string, uri: string) => { this.openGame(path, uri); },
                  openGameDetailsWithFlash: (game: GameInfo) => { this.openGameDetailsWithFlash(game); },
                  initializeDownloadDir: () => { this.initializeDownloadDir(); },
                  openDownloadDir: () => { this.openDownloadDir(); },
                  onScrollDelta: (deltaY: number) => { this.onHomeCollectionScrollDelta(deltaY); }
                })
              }

              TabContent() {
                HomeGameCollection({
                  dataSource: this.favoritesGamesDataSource,
                  scroller: this.favoritesScroller,
                  isEmpty: this.getFilteredFavoriteGames().length === 0,
                  emptyTitle: I18n.t('empty_favorites_title'),
                  emptyDesc: I18n.t('empty_favorites_desc'),
                  showDir: false,
                  downloadDirPath: this.downloadDirPath,
                  layoutType: this.layoutType,
                  openingGamePath: this.openingGamePath,
                  collectionScrollSourceId: this.collectionScrollSourceId,
                  themeColors: this.themeColors,
                  soundEffectManager: this.soundEffectManager,
                  screenWidth: this.screenWidth,
                  openGame: (path: string, uri: string) => { this.openGame(path, uri); },
                  openGameDetailsWithFlash: (game: GameInfo) => { this.openGameDetailsWithFlash(game); },
                  initializeDownloadDir: () => { this.initializeDownloadDir(); },
                  openDownloadDir: () => { this.openDownloadDir(); },
                  onScrollDelta: (deltaY: number) => { this.onHomeCollectionScrollDelta(deltaY); }
                })
              }

              TabContent() {
                HomeGameCollection({
                  dataSource: this.allGamesDataSource,
                  scroller: this.allGamesScroller,
                  isEmpty: this.getFilteredAllGames().length === 0,
                  emptyTitle: I18n.t('empty_all_title'),
                  emptyDesc: this.downloadDirPath ? I18n.t('empty_all_desc') : I18n.t('download_dir_not_set_yet'),
                  showDir: true,
                  downloadDirPath: this.downloadDirPath,
                  layoutType: this.layoutType,
                  openingGamePath: this.openingGamePath,
                  collectionScrollSourceId: this.collectionScrollSourceId,
                  themeColors: this.themeColors,
                  soundEffectManager: this.soundEffectManager,
                  screenWidth: this.screenWidth,
                  openGame: (path: string, uri: string) => { this.openGame(path, uri); },
                  openGameDetailsWithFlash: (game: GameInfo) => { this.openGameDetailsWithFlash(game); },
                  initializeDownloadDir: () => { this.initializeDownloadDir(); },
                  openDownloadDir: () => { this.openDownloadDir(); },
                  onScrollDelta: (deltaY: number) => { this.onHomeCollectionScrollDelta(deltaY); }
                })
              }
            }
            .layoutWeight(1)
            .barHeight(0)
            .onChange((index: number) => {
              if (index !== this.currentTabIndex) {
                this.soundEffectManager.play(SoundEffect.SELECT);
                this.currentTabIndex = normalizeHomeTab(index);
                this.getCurrentCollectionScroller().scrollEdge(Edge.Top);
                this.resetActionBarScrollState(this.currentTabIndex);
                this.actionBarOffsetX = this.isActionBarCollapsed()
                  ? 0
                  : this.getActionBarExpandedOffset();
                if (this.currentTabIndex !== HomeTab.FAVORITES && this.isActionBarNarrow()) {
                  this.getActionTabsController().applyMiniBarStyle(
                    this.isActionBarCollapsed() ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE);
                  const targetTab = this.currentTabIndex;
                  setTimeout(() => {
                    if (this.currentTabIndex === targetTab && !this.isActionBarCollapsed(targetTab)) {
                      this.actionBarOffsetX = this.getActionBarExpandedOffset();
                    }
                  }, 0);
                }
              }
            })
          }
          .width('100%')
          .height('100%')

          if (this.currentTabIndex === HomeTab.RECENT) {
            this.ActionBarTabsBuilder(HomeTab.RECENT)
          } else if (this.currentTabIndex === HomeTab.ALL) {
            this.ActionBarTabsBuilder(HomeTab.ALL)
          }
        }
        .width('100%')
        .height('100%')
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
      }
      .mode(NavigationMode.Stack)
      .hideBackButton(!this.isSearchMode)
      .titleMode(HdsNavigationTitleMode.MINI)
      .bindToScrollable([this.getCurrentCollectionScroller()])
      .dynamicHideTitleBar({
        hideBottomBuilder: true,
        mode: HideMode.SCROLL_UP_TO
      })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .titleBar({
        content: {
          title: undefined,
          backIcon: this.isSearchMode ? {
            icon: navBackIconModifier(),
            action: () => {
              this.soundEffectManager.play(SoundEffect.BACK);
              this.closeSearchMode();
            }
          } : undefined,
          menu: this.isSearchMode ? undefined : {
            value: [
              {
                content: {
                  icon: $r('sys.symbol.magnifyingglass'),
                  label: I18n.t('search'),
                  action: () => {
                    this.soundEffectManager.play(SoundEffect.DECIDE);
                    this.isSearchMode = true;
                  }
                }
              },
              {
                content: {
                  icon: $r('sys.symbol.slider_horizontal_2'),
                  label: I18n.t('view_options'),
                  action: () => {
                    this.soundEffectManager.play(SoundEffect.DECIDE);
                    this.showViewOptionsSheet = true;
                  }
                }
              },
              {
                content: {
                  icon: $r('sys.symbol.dot_grid_2x2'),
                  label: I18n.t('settings'),
                  action: () => {
                    this.soundEffectManager.play(SoundEffect.DECIDE);
                    router.pushUrl({ url: 'pages/Settings' });
                  }
                }
              }
            ],
            maxCount: 3
          },
          stackBuilder: this.isSearchMode ? () => {
            this.SearchTitleBuilder()
          } : () => {
            this.HomeTitleSectionBuilder()
          },
          bottomBuilder: {
            builder: () => {
              this.HomeSegmentBarBuilder()
            },
            height: SEGMENT_BAR_HEIGHT,
            showType: BottomBuilderShowType.DIRECTLY_SHOW
          }
        },
        style: {
          scrollEffectOpts: {
            scrollEffectType: ScrollEffectType.GRADIENT_BLUR
          },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        },
        avoidLayoutSafeArea: true,
        enableComponentSafeArea: false
      })

      Column()
        .bindContentCover($$this.showLoadingMask, this.buildLoadingDialog(), {
          modalTransition: ModalTransition.NONE
        })

      HomeSheets({
        themeColors: this.themeColors,
        appearanceMode: this.appearanceMode,
        layoutType: this.layoutType,
        coverCornerRadius: this.coverCornerRadius,
        currentThemeId: this.currentThemeId,
        downloadDirPath: this.downloadDirPath,
        showViewOptionsSheet: $showViewOptionsSheet,
        showHowToGetGamesPanel: $showHowToGetGamesPanel,
        showWebUploadPanel: $showWebUploadPanel,
        soundEffectManager: this.soundEffectManager,
        applyTheme: (id: string) => { this.applyTheme(id); },
        applyAppearanceMode: (index: number) => { this.applyAppearanceMode(index); },
        applyHomeLayout: (type: LayoutType) => { this.applyHomeLayout(type); },
        applyCoverSize: (size: number, persist: boolean) => { this.applyCoverSize(size, persist); },
        applyCoverCornerRadius: (radius: number, persist: boolean) => { this.applyCoverCornerRadius(radius, persist); },
        getWebUploadTargetPath: (): string => this.getWebUploadTargetPath(),
        closeWebUploadPanel: () => { this.closeWebUploadPanel(); },
        scanAllGames: () => { this.scanAllGames(); }
      })
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const width = Number(newArea.width);
      const height = Number(newArea.height);
      if (width > 0 && height > 0 && (width !== this.screenWidth || height !== this.screenHeight)) {
        this.screenWidth = width;
        this.screenHeight = height;
        if (!this.isActionBarCollapsed()) {
          this.actionBarOffsetX = this.getActionBarExpandedOffset();
        }
        this.updateBottomRoundedCornerInsets();
      }
    })
  }
}

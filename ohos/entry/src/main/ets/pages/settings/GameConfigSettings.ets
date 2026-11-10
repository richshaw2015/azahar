import { ComponentContent, ComposeListItem, router, display, TabSegmentButtonV2, SegmentButtonV2Items, ColorMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { AzaharNavPage } from '../../components/common/AzaharNavPage';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { controlThemeOf, immersiveMaterial, controlAccentOf } from '../../components/common/AzaharControls';
import { KEY_INSERTED_CARTRIDGE, SettingOption } from '../../types/SettingsTypes';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { GlobalWallpaper } from '../../components/common/GlobalWallpaper';
import { SelectSettingItem } from '../../components/settings/SelectSettingItem';
import { GameConfigCheatsTab } from '../../components/settings/gameconfig/GameConfigCheatsTab';
import { GameConfigConfigTab } from '../../components/settings/gameconfig/GameConfigConfigTab';
import { GameConfigDetailsTab } from '../../components/settings/gameconfig/GameConfigDetailsTab';
import {
  GameConfigFilesTab,
  GAME_DIR_PATTERN_DLC,
  GAME_DIR_PATTERN_MODS,
  GAME_DIR_PATTERN_SAVE,
  GAME_DIR_PATTERN_TEXTURES,
  GAME_DIR_PATTERN_UPDATE,
  GAME_DIR_SDMC_ROOT_PREFIX
} from '../../components/settings/gameconfig/GameConfigFilesTab';
import { TextInputSettingItem } from '../../components/settings/TextInputSettingItem';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider } from '../../components/settings/SettingsList';
import { FloatTilesBackground } from '../../components/theme/FloatTilesBackground';
import {
  AzaharCheatInfo,
  AzaharGameMetadata,
  AzaharNative,
  AzaharTitleContentKind,
  AzaharTitleContentStatus
} from '../../types/AzaharNative';
import { GameDetailsTab } from '../../types/GameDetailsTab';
import { AzaharTheme, AzaharThemeColors } from '../../types/ThemeTypes';
import { CheatsSeed } from '../../utils/CheatsSeed';
import { DownloadDirManager } from '../../utils/DownloadDirManager';
import { FileManagerHelper } from '../../utils/FileManagerHelper';
import { formatFileSize } from '../../utils/FileSizeFormatter';
import { AzaharGameConfig, GameConfigManager } from '../../utils/GameConfigManager';
import { GameInfo, GameManager } from '../../utils/GameManager';
import { formatLastPlayed, formatPlayTime, normalizeTitleId, PlayTimeManager } from '../../utils/PlayTimeManager';
import { COVER_ASPECT_RATIO } from '../../components/game/AzaharCartridgeItem';
import { gamepadBackHandler } from '../../utils/GamepadUIHelper';
import { I18n } from '../../utils/I18nManager';
import { PAGE_TRANSITION_DURATION } from '../../utils/PageTransitionHelper';
import { SettingsManager } from '../../utils/SettingsManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { ThemeManager } from '../../utils/ThemeManager';
import { initToastHelper, showErrorToast, showInfoToast, showSuccessToast, showWarningToast } from '../../utils/ToastHelper';
import { WallpaperProcessor } from '../../utils/WallpaperProcessor';
import { LayoutConfigManager } from '../../utils/LayoutConfigManager';
import {
  BUTTON_ICON_SM,
  CARD_BORDER_COLOR,
  FONT_SIZE_PAGE_TITLE,
  NAV_TITLE_SCROLL_SPACE,
  RADIUS_MD,
  RADIUS_SM,
  SETTING_ITEM_PADDING,
  TEXT_DANGER,
  TEXT_DISABLED,
  TEXT_ON_ACCENT,
  TEXT_PRIMARY,
  TEXT_SECONDARY,
  SURFACE_CARD,
  MENU_ITEM_DIVIDER,
  SEGMENT_BAR_HEIGHT,
  SEGMENT_BUTTON_MIN_HEIGHT,
  SEGMENT_ITEM_MIN_HEIGHT,
  SEGMENT_ITEM_PADDING,
  SEGMENT_SYMBOL_FONT_SIZE,
  titleBarButtonAvoidVp
} from '../../types/UIConstants';

interface GameConfigRouterParams {
  romPath?: string;
  gameName?: string;
  titleId?: string;
  extdataId?: string;
  favorite?: boolean;
  productCode?: string;
  installed?: boolean;
  defaultTab?: GameDetailsTab;
}

interface ContentUninstallResult {
  failed: number;
  appFailed: boolean;
}

interface MoreMenuItemOption {
  label: string;
  action: () => void;
  danger?: boolean;
}

interface MoreActionsMenuParams {
  groups: MoreMenuItemOption[][];
}

// 标题栏"更多"图标携带的组件 id：promptAction.openMenu 用它把自定义菜单锚定到该图标（HDS 官方用法）
const MORE_MENU_TARGET_ID: string = 'game_config_more_menu';

/**
 * 更多操作菜单内容：MenuItemGroup 分组 + 发丝分隔线，与 bindMenu 对号流派同一形态。
 * 经 ComponentContent 每次打开时按当前状态全新构建，条件项/动态标签在构建期求值。
 */
@Builder
function MoreActionsMenu(params: MoreActionsMenuParams) {
  Menu() {
    ForEach(params.groups, (group: MoreMenuItemOption[], groupIndex: number) => {
      MenuItemGroup() {
        ForEach(group, (item: MoreMenuItemOption) => {
          MenuItem({ content: item.label })
            .onClick(() => {
              SoundEffectManager.getInstance().play(item.danger ? SoundEffect.CONFIRM : SoundEffect.DECIDE);
              item.action();
            })
        }, (item: MoreMenuItemOption) => item.label)
      }
    }, (_group: MoreMenuItemOption[], groupIndex: number) => `${groupIndex}`)
  }
  .fontColor($r('sys.color.ohos_id_color_text_primary'))
  .menuItemDivider(MENU_ITEM_DIVIDER)
  .menuItemGroupDivider(MENU_ITEM_DIVIDER)
}

const TEXT_MUTED: Resource = TEXT_DISABLED;

@Entry
@Component
struct GameConfigSettings {
  private detailsScroller: Scroller = new Scroller();
  private configScroller: Scroller = new Scroller();
  private filesScroller: Scroller = new Scroller();
  private cheatsScroller: Scroller = new Scroller();
  @State private romPath: string = '';
  @State private baseGameName: string = '';
  @State private titleId: string = '';
  @State private extdataId: string = '';
  @State private publisher: string = '';
  @State private productCode: string = '';
  @State private shortTitle: string = '';
  @State private longTitle: string = '';
  @State private installed: boolean = false;
  @State private fileType: string = '';
  @State private encrypted: boolean = false;
  @State private insertable: boolean = false;
  @State private insertedCartridgePath: string = '';
  @State private systemTitle: boolean = false;
  @State private lastPlayed: number = 0;
  @State private playCount: number = 0;
  @State private playTimeMs: number = 0;
  @State private favorite: boolean = false;
  @State private romSize: number = -1;
  @State private icon: image.PixelMap | undefined = undefined;
  // 标题栏图标：只取包体 Icon（不随封面导入/清除变化），进页加载一次即可
  @State private packageIcon: image.PixelMap | null = null;
  @State private currentTab: GameDetailsTab = GameDetailsTab.DETAILS;
  @State private downloadDirPath: string = '';
  @State private downloadDirUri: string = '';
  @State private config: AzaharGameConfig = GameConfigManager.getInstance().getConfig('');
  @State private editNameValue: string = '';
  // 文件 Tab 目录存在性（对齐 Android Open 菜单置灰规则），init/懒初始化下载目录后刷新
  @State private saveDirExists: boolean = false;
  @State private updateDirExists: boolean = false;
  @State private dlcDirExists: boolean = false;
  @State private extdataDirExists: boolean = false;
  @State private themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();
  // 标题栏实测宽度（vp）：驱动 stackBuilder 内容按 HDS 分档避让两端按钮
  @State private titleBarWidthVp: number = 0;
  @StorageLink('globalWallpaperUri') globalWallpaperUri: string = '';
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;
  // 游玩统计写入时自增，触发本页按 PlayTimeManager 重新取值
  @StorageLink('playStatsVersion') @Watch('onPlayStatsVersionChange') playStatsVersion: number = 0;
  @StorageLink('layoutPickerResult') @Watch('onLayoutPickerResult') layoutPickerResult: string = '__unset__';

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private downloadDirManager: DownloadDirManager = DownloadDirManager.getInstance();
  private fileManagerHelper: FileManagerHelper = FileManagerHelper.getInstance();
  private gameManager: GameManager = GameManager.getInstance();
  private playTimeManager: PlayTimeManager = PlayTimeManager.getInstance();
  private configManager: GameConfigManager = GameConfigManager.getInstance();
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private themeManager: ThemeManager = ThemeManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private themeChangeListener: ((theme: AzaharTheme) => void) | null = null;

  async aboutToAppear(): Promise<void> {
    initToastHelper(this.getUIContext());
    // 先取显示宽度做避让初值，再由标题内容的 onAreaChange 用实测宽度修正（覆盖多窗/分屏）
    try {
      const d = display.getDefaultDisplaySync();
      this.titleBarWidthVp = Math.round(d.width / (d.densityPixels || 1));
    } catch (_e) {
      this.titleBarWidthVp = 0;
    }
    await this.soundEffectManager.initialize(this.context);
    await this.initializePage();
  }

  aboutToDisappear(): void {
    if (this.themeChangeListener) {
      this.themeManager.removeListener(this.themeChangeListener);
      this.themeChangeListener = null;
    }
  }

  private async initializePage(): Promise<void> {
    FileManagerHelper.initAppName(this.context);
    const params = router.getParams() as GameConfigRouterParams | undefined;
    this.romPath = params?.romPath || '';
    this.baseGameName = params?.gameName || this.getFileName(this.romPath);
    this.titleId = params?.titleId || '';
    this.extdataId = params?.extdataId || '';
    this.favorite = params?.favorite || false;
    this.productCode = params?.productCode || '';
    this.installed = params?.installed || false;
    if (params?.defaultTab !== undefined) {
      this.currentTab = params.defaultTab;
    }

    // 用列表页已加载的封面/图标缓存做首帧种子（内存 Map，无需 initialize）：命中时首帧直接显示，
    // 避免蓝色占位块闪烁；未命中仍由下方 loadIcon/loadPackageIcon 异步加载兜底
    this.icon = this.gameManager.getCachedCover(this.romPath) ?? this.gameManager.getCachedIcon(this.romPath) ?? undefined;
    this.packageIcon = this.gameManager.getCachedIcon(this.romPath);

    await this.settingsManager.initialize(this.context);
    await this.themeManager.initialize(this.context);
    await this.downloadDirManager.initialize(this.context);
    await this.gameManager.initialize(this.context);
    await this.configManager.initialize(this.context);
    await this.playTimeManager.init(this.context);
    // 布局名查询依赖内存中的 layouts 列表，须先 init（幂等），否则 layoutDescription 恒回落"使用全局布局"
    await LayoutConfigManager.getInstance().init(this.context);
    this.downloadDirPath = this.downloadDirManager.getDownloadDirPath();
    this.downloadDirUri = this.downloadDirManager.getDownloadDirUri();
    this.config = this.configManager.getConfig(this.romPath);
    this.editNameValue = this.config.customName;
    this.insertedCartridgePath = this.settingsManager.getString(KEY_INSERTED_CARTRIDGE);

    this.themeColors = this.themeManager.getCurrentColors();
    this.themeChangeListener = (_theme: AzaharTheme) => {
      this.themeColors = this.themeManager.getCurrentColors();
    };
    this.themeManager.addListener(this.themeChangeListener);

    this.loadMetadata();
    this.favorite = this.gameManager.isFavoriteTitle(this.titleId);
    this.refreshPlayStats();
    this.loadIcon();
    this.loadPackageIcon();
    this.refreshFileInfo();
    // 须在 loadMetadata 之后：titleId/extdataId 可能被元数据覆盖，目录存在性依赖最终值
    this.refreshDirExistence();
    // 内置金手指播种与 GameView 启动同一策略：已存在（含用户自定义）或未收录则跳过
    CheatsSeed.getInstance().ensureSeed(this.context, this.downloadDirPath, this.titleId);
  }

  private loadMetadata(): void {
    if (!this.romPath) {
      return;
    }
    try {
      const metadata: AzaharGameMetadata = AzaharNative.getGameMetadata(this.romPath);
      this.titleId = metadata.titleId || this.titleId;
      this.extdataId = metadata.extdataId || this.extdataId;
      this.baseGameName = metadata.longTitle || metadata.shortTitle || this.baseGameName;
      this.publisher = metadata.publisher;
      this.shortTitle = metadata.shortTitle || '';
      this.longTitle = metadata.longTitle || '';
      this.productCode = metadata.productCode || this.productCode;
      this.fileType = metadata.fileType;
      this.encrypted = metadata.encrypted;
      this.insertable = metadata.insertable;
      this.systemTitle = metadata.systemTitle;
    } catch (_error) {
      console.warn(`load game metadata failed: ${(_error as Error)?.message}`);
    }
  }

  private loadIcon(): void {
    if (!this.romPath) {
      return;
    }
    this.gameManager.getGameCover(this.currentGame(), this.downloadDirPath).then((cover: image.PixelMap | null) => {
      if (cover) {
        this.icon = cover;
        return;
      }
      this.gameManager.getGameIcon(this.romPath).then((icon: image.PixelMap | null) => {
        if (icon) {
          this.icon = icon;
        }
      }).catch((_error: Error) => {
      });
    }).catch((_error: Error) => {
    });
  }

  private loadPackageIcon(): void {
    if (!this.romPath) {
      return;
    }
    this.gameManager.getGameIcon(this.romPath).then((icon: image.PixelMap | null) => {
      if (icon) {
        this.packageIcon = icon;
      }
    }).catch((_error: Error) => {
      // 装饰性图标：取不到时标题只显示文字，与 loadIcon 同一降级策略
    });
  }

  private refreshFileInfo(): void {
    try {
      if (fileIo.accessSync(this.romPath)) {
        this.romSize = fileIo.statSync(this.romPath).size;
      }
    } catch (_error) {
      this.romSize = -1;
    }
  }

  private displayName(): string {
    return this.gameManager.getDisplayName(this.currentGame()) || this.getFileName(this.romPath);
  }

  private currentGame(): GameInfo {
    return {
      uri: '',
      path: this.romPath,
      name: this.baseGameName,
      fileName: this.getFileName(this.romPath),
      extension: '',
      titleId: this.titleId,
      shortTitle: this.shortTitle,
      longTitle: this.longTitle,
      publisher: this.publisher,
      regions: '',
      productCode: this.productCode,
      extdataId: this.extdataId,
      fileType: this.fileType,
      encrypted: this.encrypted,
      insertable: this.insertable,
      inserted: false,
      systemTitle: this.systemTitle,
      visible: true,
      hasIcon: !!this.icon,
      installed: this.installed,
      mediaType: 0,
      lastPlayed: this.lastPlayed,
      playCount: this.playCount,
      playTimeMs: this.playTimeMs,
      favorite: this.favorite
    };
  }

  private getFileName(path: string): string {
    if (!path) {
      return '';
    }
    const slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  private getParentPath(path: string): string {
    const slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    return slash > 0 ? path.substring(0, slash) : '';
  }

  // 文件 Tab「应用」行描述：ROM 所在目录的显示路径（对齐 Android Open Application Folder）
  private appDirDisplayPath(): string {
    const parent = this.getParentPath(this.romPath);
    return parent ? FileManagerHelper.getDisplayPath(parent) : '';
  }

  private playTimeText(): string {
    return this.playTimeMs > 0 ? formatPlayTime(this.playTimeMs) : I18n.t('not_recorded');
  }

  private refreshPlayStats(): void {
    const stats = this.playTimeManager.getStats(this.getNormalizedTitleId(), this.romPath);
    this.playTimeMs = stats?.totalPlayTimeMs ?? 0;
    this.lastPlayed = stats?.lastPlayed ?? 0;
    this.playCount = stats?.playCount ?? 0;
  }

  private onPlayStatsVersionChange(): void {
    this.refreshPlayStats();
  }

  private onLayoutPickerResult(): void {
    if (this.layoutPickerResult === '__unset__' || !this.romPath) {
      return;
    }
    const selectedId = this.layoutPickerResult;
    this.layoutPickerResult = '__unset__';
    void this.updateConfig((config: AzaharGameConfig) => { config.layoutId = selectedId; });
  }

  private layoutDescription(): string {
    if (!this.config.layoutId) {
      return I18n.t('use_global_layout');
    }
    const layout = LayoutConfigManager.getInstance().getLayoutById(this.config.layoutId);
    // 与布局选择器列表同口径：查到布局显示其名字（空名回落"未命名布局"），查不到才算跟随全局
    return layout ? (layout.name || I18n.t('unnamed_layout')) : I18n.t('use_global_layout');
  }

  private async updateConfig(updater: (config: AzaharGameConfig) => void): Promise<void> {
    this.config = await this.configManager.updateConfig(this.romPath, (config: AzaharGameConfig) => {
      updater(config);
      return config;
    });
  }

  private resetGameConfig(): void {
    this.openConfirmDialog(
      I18n.t('game_config_reset_title'),
      I18n.tf1('game_config_reset_message_fmt', 'name', this.displayName()),
      I18n.t('restore'),
      () => {
        this.performResetGameConfig();
      }
    );
  }

  private async performResetGameConfig(): Promise<void> {
    await this.configManager.resetConfig(this.romPath);
    this.config = this.configManager.getConfig(this.romPath);
    this.editNameValue = '';
    this.soundEffectManager.play(SoundEffect.CONFIRM);
    showSuccessToast(I18n.t('game_config_global_restored'));
  }

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

  private numOptions(values: number[], suffix: string): SettingOption[] {
    return this.rawOptions(values, values.map((value: number): string => `${value}${suffix}`));
  }

  private triOptions(): SettingOption[] {
    return this.rawOptions([1, 0], [I18n.t('on'), I18n.t('off')]);
  }

  private async openRomFolder(): Promise<void> {
    const folder = this.getParentPath(this.romPath);
    if (!folder) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('game_config_rom_dir_not_found'));
      return;
    }
    const relativePath = this.getDownloadRelativePath(folder);
    const folderUri = relativePath ? this.getDownloadFolderUri(relativePath) : '';
    const result = await this.fileManagerHelper.openFolder(this.context, folderUri || folder);
    if (!result.success) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(result.message);
    }
  }

  private getDownloadRelativePath(path: string): string {
    if (!this.downloadDirPath || !path.startsWith(`${this.downloadDirPath}/`)) {
      return '';
    }
    return path.substring(this.downloadDirPath.length + 1);
  }

  private async ensureDownloadDir(): Promise<boolean> {
    if (this.downloadDirPath) {
      return true;
    }

    const path = await this.downloadDirManager.initDownloadDirectory();
    if (!path) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('download_dir_not_set_short'));
      return false;
    }
    this.downloadDirPath = path;
    this.downloadDirUri = this.downloadDirManager.getDownloadDirUri();
    this.gameManager.ensureLibraryDirectories(path);
    this.refreshDirExistence();
    return true;
  }

  // 对齐 Android Open 菜单：模拟器管理的 sdmc/extdata 目录不存在时报错（等价安卓置灰），
  // load/ 下的纹理/mods 目录允许自动创建（createIfMissing，对应安卓 folderUriHelper 的 create 参数）
  private async openDownloadFolder(relativePath: string, label: string, createIfMissing: boolean): Promise<void> {
    if (!await this.ensureDownloadDir()) {
      return;
    }
    const targetPath = `${this.downloadDirPath}/${relativePath}`;
    if (createIfMissing) {
      this.ensureDirectory(targetPath);
    } else if (!this.pathExists(targetPath)) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.tf1('game_config_label_not_exists_fmt', 'label', label));
      return;
    }
    const targetUri = this.getDownloadFolderUri(relativePath);
    const result = await this.fileManagerHelper.openFolder(this.context, targetUri || targetPath);
    if (!result.success) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(result.message);
    }
  }

  private getNormalizedTitleId(): string {
    return normalizeTitleId(this.titleId);
  }

  private getLowerTitleId(): string {
    return this.getNormalizedTitleId().toLowerCase();
  }

  private getLowerExtdataId(): string {
    return this.extdataId.trim().toLowerCase();
  }

  private resolveTitleRelativePath(pattern: string): string {
    const lowerTitleId = this.getLowerTitleId();
    if (lowerTitleId.length !== 16) {
      return '';
    }
    const high = lowerTitleId.substring(0, 8);
    const low = lowerTitleId.substring(8);
    return pattern
      .replace('{high}', high)
      .replace('{low}', low)
      .replace('{titleId}', this.getNormalizedTitleId());
  }

  private resolveExtdataRelativePath(): string {
    const lowerExtdataId = this.getLowerExtdataId();
    if (lowerExtdataId.length !== 16) {
      return '';
    }
    const high = lowerExtdataId.substring(0, 8);
    const low = lowerExtdataId.substring(8);
    return `${GAME_DIR_SDMC_ROOT_PREFIX}extdata/${high}/${low}`;
  }

  // 文件 Tab 副标题：剥掉 sdmc 根前缀——save/update/dlc/extdata 共用此前缀，
  // 完整相对路径在副标题截断后各行无区别；load/ 下的纹理/mods 是短路径不受影响
  private dirDisplayPath(relativePath: string): string {
    if (!relativePath) {
      return '';
    }
    return relativePath.startsWith(GAME_DIR_SDMC_ROOT_PREFIX)
      ? relativePath.substring(GAME_DIR_SDMC_ROOT_PREFIX.length)
      : relativePath;
  }

  private async openTitleFolder(pattern: string, label: string, createIfMissing: boolean): Promise<void> {
    const relativePath = this.resolveTitleRelativePath(pattern);
    if (!relativePath) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('game_config_no_valid_title_id'));
      return;
    }
    await this.openDownloadFolder(relativePath, label, createIfMissing);
  }

  private async openExtdataFolder(): Promise<void> {
    const relativePath = this.resolveExtdataRelativePath();
    if (!relativePath) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('game_config_no_extdata_id'));
      return;
    }
    await this.openDownloadFolder(relativePath, I18n.t('dir_extdata'), false);
  }

  private getOpenGLShaderCachePaths(titleId: string): string[] {
    if (!this.downloadDirPath || !titleId) {
      return [];
    }
    return [
      `${this.context.cacheDir}/shaders/opengl/precompiled/separable/${titleId}.bin`,
      `${this.context.cacheDir}/shaders/opengl/precompiled/conventional/${titleId}.bin`,
      `${this.context.cacheDir}/shaders/opengl/transferable/${titleId}.bin`
    ];
  }

  private getVulkanShaderCachePaths(titleId: string): string[] {
    if (!this.downloadDirPath || !titleId) {
      return [];
    }
    const paths: string[] = [
      `${this.context.cacheDir}/shaders/vulkan/transferable/${titleId}_vs.vkch`,
      `${this.context.cacheDir}/shaders/vulkan/transferable/${titleId}_fs.vkch`,
      `${this.context.cacheDir}/shaders/vulkan/transferable/${titleId}_gs.vkch`,
      `${this.context.cacheDir}/shaders/vulkan/transferable/${titleId}_pl.vkch`
    ];
    const pipelineDir = `${this.context.cacheDir}/shaders/vulkan/pipeline`;
    try {
      const entries = fileIo.listFileSync(pipelineDir);
      entries.forEach((entry: string) => {
        if (entry.toUpperCase().startsWith(titleId)) {
          paths.push(`${pipelineDir}/${entry}`);
        }
      });
    } catch (_error) {
      console.warn(`GameConfig: operation failed: ${(_error as Error)?.message}`);
    }
    return paths;
  }

  private countExistingFiles(paths: string[]): number {
    let count = 0;
    paths.forEach((path: string) => {
      try {
        if (fileIo.accessSync(path)) {
          count += 1;
        }
      } catch (_error) {
        console.warn(`GameConfig: operation failed: ${(_error as Error)?.message}`);
      }
    });
    return count;
  }

  private deleteExistingFiles(paths: string[]): number {
    let count = 0;
    paths.forEach((path: string) => {
      try {
        if (fileIo.accessSync(path)) {
          fileIo.unlinkSync(path);
          count += 1;
        }
      } catch (_error) {
        console.warn(`GameConfig: operation failed: ${(_error as Error)?.message}`);
      }
    });
    return count;
  }

  // 清除着色器缓存：OpenGL/Vulkan 两个后端的缓存一起删，无需选择后端
  private clearShaderCache(): void {
    const titleId = this.getNormalizedTitleId();
    if (!titleId) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('cheat_no_available_title_id'));
      return;
    }
    const paths = this.getOpenGLShaderCachePaths(titleId).concat(this.getVulkanShaderCachePaths(titleId));
    const existingCount = this.countExistingFiles(paths);
    if (existingCount === 0) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('game_config_shader_cache_not_found_fmt'));
      return;
    }

    this.openConfirmDialog(
      I18n.t('clear_shader_cache'),
      I18n.tf2('game_config_delete_shader_cache_message_fmt', 'titleId', titleId, 'count', existingCount),
      I18n.t('delete'),
      () => {
        const deleted = this.deleteExistingFiles(paths);
        if (deleted > 0) {
          this.soundEffectManager.play(SoundEffect.CONFIRM);
          showSuccessToast(I18n.tf1('game_config_shader_cache_deleted_fmt', 'count', deleted));
        } else {
          this.soundEffectManager.play(SoundEffect.FAIL);
          showWarningToast(I18n.t('game_config_shader_cache_none_deleted_fmt'));
        }
      }
    );
  }

  private getDownloadFolderUri(relativePath: string): string {
    if (!this.downloadDirUri) {
      return '';
    }
    const base = this.downloadDirUri.endsWith('/') ? this.downloadDirUri.slice(0, -1) : this.downloadDirUri;
    return `${base}/${relativePath}`;
  }

  private pathExists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (_error) {
      return false;
    }
  }

  private downloadPathExists(relativePath: string): boolean {
    return relativePath.length > 0 && this.downloadDirPath.length > 0 &&
      this.pathExists(`${this.downloadDirPath}/${relativePath}`);
  }

  // 对齐 Android Open 菜单：应用/存档/更新/DLC/ExtraData 仅在目录真实存在时可打开
  private refreshDirExistence(): void {
    this.saveDirExists = this.downloadPathExists(this.resolveTitleRelativePath(GAME_DIR_PATTERN_SAVE));
    this.updateDirExists = this.downloadPathExists(this.resolveTitleRelativePath(GAME_DIR_PATTERN_UPDATE));
    this.dlcDirExists = this.downloadPathExists(this.resolveTitleRelativePath(GAME_DIR_PATTERN_DLC));
    this.extdataDirExists = this.downloadPathExists(this.resolveExtdataRelativePath());
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

  // 对齐 NDS：移出最近是低危操作，不弹确认直接执行 + toast
  private async removeFromRecent(): Promise<void> {
    await this.gameManager.removeFromRecentGames(this.romPath);
    this.soundEffectManager.play(SoundEffect.CONFIRM);
    showSuccessToast(I18n.t('removed_from_recent'));
  }

  private async toggleFavorite(): Promise<void> {
    if (!this.titleId) {
      showWarningToast(I18n.t('favorite_no_title_id'));
      return;
    }
    const nextFavorite = !this.favorite;
    const changed = await this.gameManager.setFavoriteTitle(this.titleId, nextFavorite, this.romPath);
    if (!changed) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('favorite_update_failed'));
      return;
    }
    this.favorite = nextFavorite;
    this.soundEffectManager.play(nextFavorite ? SoundEffect.TOGGLE_ON : SoundEffect.TOGGLE_OFF);
    showSuccessToast(I18n.t(nextFavorite ? 'added_to_favorites' : 'removed_from_favorites'));
  }

  // NCCH product_code（如 CTR-P-A22J）的四位唯一码段，对齐 NDS 的 4 字符 Game ID
  private gameCode(): string {
    const dash = this.productCode.lastIndexOf('-');
    const code = (dash >= 0 ? this.productCode.substring(dash + 1) : this.productCode).trim();
    return code;
  }

  // product code 第四位为区域码（J=日版 E=美版 P=欧版…），对齐 NDS 的国旗展示
  private regionFlag(code: string): string {
    switch (code.length >= 4 ? code.charAt(3) : '') {
      case 'J': return '🇯🇵';
      case 'E': return '🇺🇸';
      case 'P': return '🇪🇺';
      case 'D': return '🇩🇪';
      case 'F': return '🇫🇷';
      case 'I': return '🇮🇹';
      case 'S': return '🇪🇸';
      case 'K': return '🇰🇷';
      case 'C': return '🇨🇳';
      case 'T': return '🇹🇼';
      case 'U': return '🇦🇺';
      default: return '🌐';
    }
  }

  private gameIdRegion(): string {
    const code = this.gameCode();
    if (!code) {
      return I18n.t('not_provided');
    }
    return `${code}  ${this.regionFlag(code)}`;
  }

  private isInsertedCartridge(): boolean {
    return this.insertable && this.insertedCartridgePath.length > 0 &&
      this.insertedCartridgePath === this.romPath;
  }

  private async toggleInsertedCartridge(): Promise<void> {
    if (!this.insertable) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('cartridge_not_insertable'));
      return;
    }
    const nextPath = this.isInsertedCartridge() ? '' : this.romPath;
    await this.settingsManager.setString(KEY_INSERTED_CARTRIDGE, nextPath);
    AzaharNative.applyConfig();
    this.insertedCartridgePath = nextPath;
    this.soundEffectManager.play(nextPath ? SoundEffect.TOGGLE_ON : SoundEffect.TOGGLE_OFF);
    showSuccessToast(nextPath ? I18n.t('cartridge_inserted_next_launch') : I18n.t('cartridge_ejected_next_launch'));
  }

  private launchGame(): void {
    router.pushUrl({
      url: 'pages/GameView',
      params: { romPath: this.romPath }
    }).catch((error: Error) => {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('game_start_failed_fmt', 'status', error.message));
    });
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

  private showMoreActions(): void {
    this.soundEffectManager.play(SoundEffect.DECIDE);
    const groups = this.buildMoreMenuGroups();
    const uiContext = this.getUIContext();
    const contentNode = new ComponentContent<MoreActionsMenuParams>(
      uiContext,
      wrapBuilder(MoreActionsMenu),
      { groups: groups }
    );
    uiContext.getPromptAction().openMenu(contentNode, { id: MORE_MENU_TARGET_ID }, {
      placement: Placement.BottomRight,
      systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK),
      onDisappear: () => {
        contentNode.dispose();
      }
    }).catch((error: Error) => {
      console.warn(`[GameConfig] openMenu failed: ${error.message}`);
      contentNode.dispose();
      this.showMoreActionsSheet(groups);
    });
  }

  // openMenu 失败时的降级：ActionSheet 是菜单类弹层的系统兜底方案
  private showMoreActionsSheet(groups: MoreMenuItemOption[][]): void {
    const sheets: Array<SheetInfo> = [];
    groups.forEach((group: MoreMenuItemOption[]) => {
      group.forEach((item: MoreMenuItemOption) => {
        sheets.push({
          title: item.label,
          action: () => {
            item.action();
          }
        });
      });
    });
    this.getUIContext().showActionSheet({
      title: this.displayName(),
      message: '',
      autoCancel: true,
      sheets: sheets,
      systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
    });
  }

  // 选项分组对齐 NDS：壁纸/收藏 → 3DS 特有功能 → 维护（清缓存）→ 游玩记录 → 卸载/删除
  // 封面导入/清除不进菜单：文件 Tab 已有相同操作行
  private buildMoreMenuGroups(): MoreMenuItemOption[][] {
    const groups: MoreMenuItemOption[][] = [];

    const libraryGroup: MoreMenuItemOption[] = [
      {
        label: I18n.t('set_as_wallpaper'),
        action: () => {
          this.setAsWallpaper();
        }
      }
    ];
    if (this.titleId.length > 0) {
      libraryGroup.push({
        label: this.favorite ? I18n.t('remove_from_favorites') : I18n.t('add_to_favorites'),
        action: () => {
          this.toggleFavorite();
        }
      });
    }
    groups.push(libraryGroup);

    const featureGroup: MoreMenuItemOption[] = [];
    if (this.insertable) {
      featureGroup.push({
        label: this.isInsertedCartridge() ? I18n.t('eject_cartridge') : I18n.t('insert_cartridge'),
        action: () => {
          this.toggleInsertedCartridge();
        }
      });
    }
    if (featureGroup.length > 0) {
      groups.push(featureGroup);
    }

    // 维护操作独立成组：清缓存是排障动作，不属于库管理，也不属于危险操作
    const maintenanceGroup: MoreMenuItemOption[] = [];
    if (this.titleId.length > 0) {
      maintenanceGroup.push({
        label: I18n.t('clear_shader_cache'),
        action: () => {
          this.clearShaderCache();
        }
      });
    }
    if (maintenanceGroup.length > 0) {
      groups.push(maintenanceGroup);
    }

    const recordGroup: MoreMenuItemOption[] = [];
    if (this.isInRecentList()) {
      recordGroup.push({
        label: I18n.t('remove_from_recent'),
        action: () => {
          this.removeFromRecent();
        }
      });
    }
    if (recordGroup.length > 0) {
      groups.push(recordGroup);
    }

    const dangerGroup: MoreMenuItemOption[] = [];
    // 对齐 Android 卸载菜单：更新/DLC 仅在对应 content 目录真实存在时显示，打开菜单时实时判断
    if (this.downloadPathExists(this.resolveTitleRelativePath(GAME_DIR_PATTERN_UPDATE))) {
      dangerGroup.push({
        label: I18n.t('uninstall_update'),
        danger: true,
        action: () => {
          this.confirmUninstallContent(AzaharTitleContentKind.Update, I18n.t('update'));
        }
      });
    }
    if (this.downloadPathExists(this.resolveTitleRelativePath(GAME_DIR_PATTERN_DLC))) {
      dangerGroup.push({
        label: I18n.t('uninstall_dlc'),
        danger: true,
        action: () => {
          this.confirmUninstallContent(AzaharTitleContentKind.DLC, I18n.t('dlc'));
        }
      });
    }
    if (!this.systemTitle) {
      dangerGroup.push({
        label: this.isInstalledGame() ? I18n.t('uninstall_game') : I18n.t('delete_game'),
        danger: true,
        action: () => {
          this.deleteGame();
        }
      });
    }
    if (dangerGroup.length > 0) {
      groups.push(dangerGroup);
    }

    return groups;
  }

  private isInRecentList(): boolean {
    return this.gameManager.getRecentGames().some((game: GameInfo) => game.path === this.romPath);
  }

  private isInstalledGame(): boolean {
    return this.installed || this.gameManager.isInstalledTitlePath(this.romPath);
  }

  // 对齐 NDS：防重入，避免连点触发重复的应用壁纸流程
  private isSettingWallpaper: boolean = false;

  private async setAsWallpaper(): Promise<void> {
    if (this.isSettingWallpaper) {
      return;
    }
    this.isSettingWallpaper = true;
    try {
      const cover = await this.gameManager.getGameCover(this.currentGame(), this.downloadDirPath);
      if (!cover) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showWarningToast(I18n.t('no_cover_available'));
        return;
      }
      await WallpaperProcessor.applyPixelMapAsWallpaper(cover, this.context);
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      showSuccessToast(I18n.t('settings_custom_wallpaper_set'));
    } catch (error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('settings_wallpaper_failed_fmt', 'error', (error as Error).message));
    } finally {
      this.isSettingWallpaper = false;
    }
  }

  private deleteGame(): void {
    // 对齐 NDS：确认消息附带文件路径，让用户确认删的是哪个文件
    // 已安装标题走"卸载"语义（内容即本体），文件型游戏走"删除"语义（删 ROM 文件）
    const installedGame = this.isInstalledGame();
    this.openConfirmDialog(
      installedGame ? I18n.t('uninstall_game') : I18n.t('delete_game'),
      `${I18n.tf1(installedGame ? 'uninstall_game_confirm_fmt' : 'delete_game_confirm_fmt', 'name', this.displayName())}\n\n${FileManagerHelper.getDisplayPath(this.romPath)}`,
      installedGame ? I18n.t('uninstall') : I18n.t('delete'),
      () => {
        this.performDeleteGame();
      }
    );
  }

  // native 侧应用/更新/DLC 是三个独立 program，删除游戏时需逐个卸载；状态查询失败按保守处理（视为应用卸载失败）。
  // forceApplication：已安装标题的内容路径即游戏本体，即使状态查询漏报也要兜底尝试卸载应用
  private uninstallInstalledContents(titleId: string, forceApplication: boolean): ContentUninstallResult {
    let status: AzaharTitleContentStatus;
    try {
      status = AzaharNative.getTitleContentStatus(titleId);
    } catch (_error) {
      return { failed: 1, appFailed: true };
    }
    const kinds: AzaharTitleContentKind[] = [];
    if (status.applicationInstalled || forceApplication) {
      kinds.push(AzaharTitleContentKind.Application);
    }
    if (status.updateInstalled) {
      kinds.push(AzaharTitleContentKind.Update);
    }
    if (status.dlcInstalled) {
      kinds.push(AzaharTitleContentKind.DLC);
    }
    let failed = 0;
    let appFailed = false;
    kinds.forEach((kind: AzaharTitleContentKind) => {
      let ok = false;
      try {
        ok = AzaharNative.uninstallTitleContent(titleId, kind);
      } catch (_error) {
        ok = false;
      }
      if (!ok) {
        failed += 1;
        if (kind === AzaharTitleContentKind.Application) {
          appFailed = true;
        }
      }
    });
    return { failed: failed, appFailed: appFailed };
  }

  // 单项卸载更新/DLC：对齐 Android 卸载菜单的分项入口；只删已安装内容，存档保留
  private confirmUninstallContent(kind: AzaharTitleContentKind, label: string): void {
    const titleId = this.getNormalizedTitleId();
    if (!titleId) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('game_config_no_valid_title_id'));
      return;
    }
    this.openConfirmDialog(
      I18n.tf1('game_config_uninstall_title_fmt', 'label', label),
      I18n.tf2('game_config_uninstall_message_fmt', 'name', this.displayName(), 'label', label),
      I18n.t('uninstall'),
      () => {
        this.performUninstallContent(kind, label);
      }
    );
  }

  private performUninstallContent(kind: AzaharTitleContentKind, label: string): void {
    const titleId = this.getNormalizedTitleId();
    if (!titleId) {
      return;
    }
    let ok = false;
    try {
      ok = AzaharNative.uninstallTitleContent(titleId, kind);
    } catch (_error) {
      ok = false;
    }
    if (ok) {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      showSuccessToast(I18n.tf1('game_config_uninstalled_fmt', 'label', label));
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('game_config_uninstall_failed_fmt', 'label', label));
    }
    this.refreshDirExistence();
  }

  private async performDeleteGame(): Promise<void> {
    const normalizedTitleId = this.getNormalizedTitleId();
    const installedGame = this.isInstalledGame();
    // 已安装内容（应用/更新/DLC）随删除一并卸载，避免更新/DLC 残留为孤儿数据；
    // 文件游戏同样处理：否则 CIA 内容会让游戏以"已安装"形态残留在库中
    const uninstallResult: ContentUninstallResult = normalizedTitleId ?
      this.uninstallInstalledContents(normalizedTitleId, installedGame) : { failed: 0, appFailed: false };

    if (installedGame && uninstallResult.appFailed) {
      // 已安装标题：内容即游戏本体，应用卸载失败则中止，避免游戏残留在库中
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('game_config_uninstall_failed_fmt', 'label', I18n.t('application')));
      return;
    }

    // 已安装标题没有独立 rom 文件（内容即本体）；文件游戏删除 rom 本体
    let fileDeleted = installedGame;
    if (!installedGame) {
      try {
        fileIo.unlinkSync(this.romPath);
        fileDeleted = true;
      } catch (_error) {
        // 无写权限的来源（外部导入等）：降级为只移出最近记录，对齐 NDS
        fileDeleted = false;
      }
    }

    // 同 titleId 的 .cia 安装源一并删除：扫描会静默自动安装，不删会残留无法重装的僵尸文件
    let cleanupFailed = uninstallResult.failed;
    if (normalizedTitleId && this.downloadDirPath) {
      cleanupFailed += this.gameManager.deleteCiaFilesForTitle(this.downloadDirPath, normalizedTitleId).failed;
    }

    await this.afterGameRemoved(fileDeleted, cleanupFailed > 0);
  }

  private async afterGameRemoved(deleted: boolean, cleanupFailed: boolean = false): Promise<void> {
    await this.gameManager.removeFromRecentGames(this.romPath);
    if (deleted) {
      const normalizedTitleId = this.getNormalizedTitleId();
      if (normalizedTitleId) {
        await this.gameManager.setFavoriteTitle(normalizedTitleId, false);
        this.favorite = false;
      }
      // 通知首页重扫游戏库
      AppStorage.setOrCreate('gameLibraryRefreshVersion', Date.now());
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      if (cleanupFailed) {
        showWarningToast(I18n.t('game_cleanup_failed'));
      } else {
        showSuccessToast(I18n.t('game_deleted'));
      }
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showInfoToast(cleanupFailed ?
        I18n.t('game_cleanup_failed') : I18n.t('remove_external_game_toast'));
    }
    router.back();
  }

  // 标题区内容：与暂停菜单 MenuHeader 同款——包体 Icon（非封面）+ 标题；stackBuilder 叠层覆盖
  // 整条标题栏，左右按 titleBarButtonAvoidVp 避让返回键/菜单键热区（HDS 内间距随宽度分档，
  // 宽屏下固定 64 会让内容贴上按钮）
  @Builder
  private GameTitleContent() {
    Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
      if (this.packageIcon) {
        Image(this.packageIcon)
          .width(30)
          .height(30)
          .objectFit(ImageFit.Cover)
          .borderRadius(RADIUS_SM)
      }
      Text(this.displayName())
        .fontSize($r('sys.float.ohos_id_text_size_sub_title1'))
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_PRIMARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: titleBarButtonAvoidVp(this.titleBarWidthVp, 'start'),
      right: titleBarButtonAvoidVp(this.titleBarWidthVp, 'end')
    })
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const width = Number(newArea.width);
      if (width > 0 && width !== this.titleBarWidthVp) {
        this.titleBarWidthVp = width;
      }
    })
  }

  @Builder
  SegmentBar() {
    Row() {
      TabSegmentButtonV2({
        items: new SegmentButtonV2Items([
          { text: I18n.t('details'), symbol: $r('sys.symbol.info_circle') },
          { text: I18n.t('config'), symbol: $r('sys.symbol.slider_horizontal_2') },
          { text: I18n.t('cheats'), symbol: $r('sys.symbol.hand_raised_fingers_spread') },
          { text: I18n.t('files'), symbol: $r('sys.symbol.folder') }
        ]),
        selectedIndex: this.currentTab,
        itemMinHeight: SEGMENT_ITEM_MIN_HEIGHT,
        itemPadding: SEGMENT_ITEM_PADDING,
        buttonMinHeight: SEGMENT_BUTTON_MIN_HEIGHT,
        itemSymbolFontSize: SEGMENT_SYMBOL_FONT_SIZE,
        backgroundSystemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true),
        itemSelectedFontColor: ColorMetrics.resourceColor(controlAccentOf(this.themeColors)),
        itemSelectedSymbolFontColor: ColorMetrics.resourceColor(controlAccentOf(this.themeColors)),
        itemSelectedBackgroundColor: ColorMetrics.resourceColor($r('sys.color.ohos_id_color_button_normal')),
        enableStateAnimation: true,
        onItemClicked: (index: number) => {
          if (index !== this.currentTab) {
            this.soundEffectManager.play(SoundEffect.SELECT);
          }
          this.currentTab = index;
        }
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end') })
  }

  build() {
    Stack() {
      if (this.globalWallpaperUri) {
        GlobalWallpaper()
      } else {
        FloatTilesBackground({
          themeColors: this.themeColors,
          isPlaying: false
        })
      }

      AzaharNavPage({
        title: this.displayName(),
        // 标题区自定义内容：包体 Icon + 游戏名，与暂停菜单 MenuHeader 同款
        titleBuilder: () => {
          this.GameTitleContent();
        },
        scrollers: [this.detailsScroller, this.configScroller, this.filesScroller, this.cheatsScroller],
        onBack: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
          router.back();
        },
        menuItems: [
          {
            icon: $r('sys.symbol.dot_grid_2x2'),
            componentId: MORE_MENU_TARGET_ID,
            action: () => {
              this.showMoreActions();
            }
          }
        ],
        bottomBuilder: () => {
          this.SegmentBar();
        },
        bottomBuilderHeight: SEGMENT_BAR_HEIGHT
      }) {
        Tabs({ barPosition: BarPosition.Start, index: this.currentTab }) {
          TabContent() {
            GameConfigDetailsTab({
              scroller: this.detailsScroller,
              topSpace: NAV_TITLE_SCROLL_SPACE + SEGMENT_BAR_HEIGHT,
              icon: this.$icon,
              displayNameText: this.displayName(),
              gameIdRegionText: this.gameIdRegion(),
              playTimeText: this.playTimeText(),
              titleId: this.titleId,
              publisher: this.publisher,
              romPath: this.romPath,
              romSize: this.romSize,
              lastPlayed: this.lastPlayed,
              playCount: this.playCount,
              themeColors: this.themeColors,
              soundEffectManager: this.soundEffectManager,
              launchGame: () => {
                this.launchGame();
              }
            })
          }

          TabContent() {
            GameConfigConfigTab({
              scroller: this.configScroller,
              topSpace: NAV_TITLE_SCROLL_SPACE + SEGMENT_BAR_HEIGHT,
              titleId: this.titleId,
              config: this.config,
              baseGameName: this.baseGameName,
              displayName: this.displayName(),
              layoutDescription: this.layoutDescription(),
              editNameValue: $editNameValue,
              soundEffectManager: this.soundEffectManager,
              updateConfig: (updater: (config: AzaharGameConfig) => void) => {
                this.updateConfig(updater);
              },
              resetGameConfig: () => {
                this.resetGameConfig();
              },
              openLayoutPicker: () => {
                this.layoutPickerResult = '__unset__';
                router.pushUrl({
                  url: 'pages/settings/LayoutsSettings',
                  params: { selectMode: true, currentLayoutId: this.config.layoutId }
                });
              }
            })
          }

          TabContent() {
            GameConfigCheatsTab({
              scroller: this.cheatsScroller,
              topSpace: NAV_TITLE_SCROLL_SPACE + SEGMENT_BAR_HEIGHT,
              titleId: this.titleId,
              themeColors: this.themeColors,
              soundEffectManager: this.soundEffectManager
            })
          }

          TabContent() {
            GameConfigFilesTab({
              scroller: this.filesScroller,
              topSpace: NAV_TITLE_SCROLL_SPACE + SEGMENT_BAR_HEIGHT,
              titleId: this.titleId,
              appDirDisplayPath: this.appDirDisplayPath(),
              saveDirExists: this.saveDirExists,
              updateDirExists: this.updateDirExists,
              dlcDirExists: this.dlcDirExists,
              extdataDirExists: this.extdataDirExists,
              saveDirDisplayPath: this.dirDisplayPath(this.resolveTitleRelativePath(GAME_DIR_PATTERN_SAVE)),
              updateDirDisplayPath: this.dirDisplayPath(this.resolveTitleRelativePath(GAME_DIR_PATTERN_UPDATE)),
              dlcDirDisplayPath: this.dirDisplayPath(this.resolveTitleRelativePath(GAME_DIR_PATTERN_DLC)),
              extdataDirDisplayPath: this.dirDisplayPath(this.resolveExtdataRelativePath()),
              textureDirDisplayPath: this.dirDisplayPath(this.resolveTitleRelativePath(GAME_DIR_PATTERN_TEXTURES)),
              modsDirDisplayPath: this.dirDisplayPath(this.resolveTitleRelativePath(GAME_DIR_PATTERN_MODS)),
              soundEffectManager: this.soundEffectManager,
              openAppFolder: () => {
                this.openRomFolder();
              },
              openTitleFolder: (pattern: string, label: string, createIfMissing: boolean) => {
                this.openTitleFolder(pattern, label, createIfMissing);
              },
              openExtdataFolder: () => {
                this.openExtdataFolder();
              }
            })
          }
        }
        .width('100%')
        .height('100%')
        .barHeight(0)
        .onChange((index: number) => {
          if (index !== this.currentTab) {
            this.soundEffectManager.play(SoundEffect.SELECT);
          }
          this.currentTab = index;
        })
      }
    }
    .width('100%')
    .height('100%')
    .onKeyEvent(gamepadBackHandler())
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
    PageTransitionEnter({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
  }
}

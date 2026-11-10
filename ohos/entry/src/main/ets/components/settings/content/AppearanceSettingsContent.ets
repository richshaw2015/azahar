import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { AppIconSelector } from '../AppIconSelector';
import { ButtonSettingItem } from '../ButtonSettingItem';
import { SelectSettingItem } from '../SelectSettingItem';
import { SliderSettingItem } from '../SliderSettingItem';
import { ThemeSelector } from '../ThemeSelector';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { GLOBAL_WALLPAPER_URI_KEY, KEY_COVER_CORNER_RADIUS, KEY_DEFAULT_TAB, KEY_GAME_LIST_LAYOUT, KEY_GAME_LIST_SORT_ASCENDING, KEY_GAME_NAME_SOURCE, KEY_GRID_SIZE, KEY_LIST_SIZE, SettingOption } from '../../../types/SettingsTypes';
import { HomeTab, normalizeHomeTab } from '../../../types/HomeTab';
import { COVER_RADIUS_DEFAULT, COVER_RADIUS_MAX, GRID_COVER_BASE, GRID_COVER_SIZE_MAX, GRID_COVER_SIZE_MIN, LIST_COVER_BASE, LIST_COVER_SIZE_MAX, LIST_COVER_SIZE_MIN } from '../../../types/UIConstants';
import { AzaharColorMode, AzaharTheme, AzaharThemeColors } from '../../../types/ThemeTypes';
import { AppIconManager } from '../../../utils/AppIconManager';
import { AppLanguage, I18n } from '../../../utils/I18nManager';
import { SettingsManager } from '../../../utils/SettingsManager';
import { SoundEffect, SoundEffectManager } from '../../../utils/SoundEffectManager';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { showErrorToast } from '../../../utils/ToastHelper';
import { WallpaperPickResult, WallpaperProcessor } from '../../../utils/WallpaperProcessor';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';

AppStorage.setOrCreate('globalWallpaperUri', '');
AppStorage.setOrCreate('globalWallpaperVersion', 0);
AppStorage.setOrCreate('gridSize', GRID_COVER_BASE);
AppStorage.setOrCreate('listSize', LIST_COVER_BASE);
AppStorage.setOrCreate('coverCornerRadius', COVER_RADIUS_DEFAULT);

@Component
export struct AppearanceSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  @State currentThemeId: string = '';
  @State appLanguage: AppLanguage = 'system';
  @State appearanceMode: string = 'auto';
  @State isSelectingWallpaper: boolean = false;
  @State homeDefaultTab: number = HomeTab.RECENT;
  @State homeListLayout: string = 'grid';
  @State homeGridSize: number = GRID_COVER_BASE;
  @State homeListSize: number = LIST_COVER_BASE;
  @State homeCoverRadius: number = COVER_RADIUS_DEFAULT;
  @State gameNameSource: string = 'metadata';
  @State sortAscending: boolean = true;
  @State appIconSupported: boolean = false;
  @StorageLink('globalWallpaperUri') wallpaperUri: string = '';
  scroller?: Scroller;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private themeManager: ThemeManager = ThemeManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private themeChangeListener: ((theme: AzaharTheme) => void) | null = null;

  async aboutToAppear(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    await this.themeManager.initialize(this.context);
    await this.soundEffectManager.initialize(this.context);
    this.appIconSupported = AppIconManager.getInstance().isAlternateIconSupported();
    this.refreshState();
    if (!this.themeChangeListener) {
      this.themeChangeListener = (_theme: AzaharTheme) => {
        this.currentThemeId = this.themeManager.getCurrentTheme().id;
      };
      this.themeManager.addListener(this.themeChangeListener);
    }
  }

  aboutToDisappear(): void {
    if (this.themeChangeListener) {
      this.themeManager.removeListener(this.themeChangeListener);
      this.themeChangeListener = null;
    }
  }

  private refreshState(): void {
    this.currentThemeId = this.themeManager.getCurrentTheme().id;
    this.appLanguage = I18n.getLanguage();
    this.appearanceMode = this.themeManager.getColorMode();
    this.wallpaperUri = this.settingsManager.getString(GLOBAL_WALLPAPER_URI_KEY);
    const savedTab = this.settingsManager.getNumber(KEY_DEFAULT_TAB);
    this.homeDefaultTab = normalizeHomeTab(savedTab);
    this.homeListLayout = this.settingsManager.getString(KEY_GAME_LIST_LAYOUT) === 'list' ? 'list' : 'grid';
    this.homeGridSize = this.normalizeCoverSize(this.settingsManager.getNumber(KEY_GRID_SIZE), true);
    this.homeListSize = this.normalizeCoverSize(this.settingsManager.getNumber(KEY_LIST_SIZE), false);
    this.homeCoverRadius = this.normalizeCoverRadius(this.settingsManager.getNumber(KEY_COVER_CORNER_RADIUS));
    this.gameNameSource = this.settingsManager.getString(KEY_GAME_NAME_SOURCE) === 'filename' ? 'filename' : 'metadata';
    this.sortAscending = this.settingsManager.getBoolean(KEY_GAME_LIST_SORT_ASCENDING);
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

  private getHomeCoverSize(): number {
    return this.homeListLayout === 'grid' ? this.homeGridSize : this.homeListSize;
  }

  private getDefaultTabOptions(): SettingOption[] {
    return [
      { value: HomeTab.RECENT, label: I18n.t('recent') },
      { value: HomeTab.FAVORITES, label: I18n.t('favorites') },
      { value: HomeTab.ALL, label: I18n.t('all') }
    ];
  }

  private getLanguageOptions(): SettingOption[] {
    return [
      { value: 'system', label: I18n.t('language_follow_system') },
      { value: 'zh', label: I18n.t('language_option_zh') },
      { value: 'en', label: I18n.t('language_option_en') }
    ];
  }

  private getAppearanceModeOptions(): SettingOption[] {
    return [
      { value: 'auto', label: I18n.t('appearance_mode_auto') },
      { value: 'light', label: I18n.t('appearance_mode_light') },
      { value: 'dark', label: I18n.t('appearance_mode_dark') }
    ];
  }

  private getGameListLayoutOptions(): SettingOption[] {
    return [
      { value: 'list', label: I18n.t('list') },
      { value: 'grid', label: I18n.t('grid') }
    ];
  }

  private getGameNameSourceOptions(): SettingOption[] {
    return [
      { value: 'metadata', label: I18n.t('game_name_source_metadata') },
      { value: 'filename', label: I18n.t('game_name_source_filename') }
    ];
  }

  private getSortOrderOptions(): SettingOption[] {
    return [
      { value: 'asc', label: I18n.t('sort_ascending') },
      { value: 'desc', label: I18n.t('sort_descending') }
    ];
  }

  private findOptionIndex(options: SettingOption[], value: string | number): number {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === value) {
        return i;
      }
    }
    return 0;
  }

  private async onLanguageChange(index: number, value: string | number): Promise<void> {
    const next = value as AppLanguage;
    if (next === this.appLanguage) {
      return;
    }
    this.appLanguage = next;
    await I18n.setLanguage(next);
    // I18n.t() 在 build 时求值，字符串已烘焙进已渲染页面；
    // 无需重启进程——重建整个页面栈让全部 UI 以新语言重渲染
    router.clear();
    router.replaceUrl({ url: 'pages/Index' }).catch((error: Error) => {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(error.message);
    });
  }

  private async onAppearanceModeChange(index: number, value: string | number): Promise<void> {
    const next = typeof value === 'string' ? value : 'auto';
    this.appearanceMode = next;
    await this.themeManager.setColorMode(next as AzaharColorMode);
  }

  private async onHomeDefaultTabChange(index: number, value: string | number): Promise<void> {
    const next = typeof value === 'number' ? value : HomeTab.RECENT;
    this.homeDefaultTab = normalizeHomeTab(next);
    await this.settingsManager.setNumber(KEY_DEFAULT_TAB, this.homeDefaultTab);
  }

  private async onHomeListLayoutChange(index: number, value: string | number): Promise<void> {
    this.homeListLayout = value === 'list' ? 'list' : 'grid';
    await this.settingsManager.setString(KEY_GAME_LIST_LAYOUT, this.homeListLayout);
  }

  private async onHomeCoverSizeChange(sizeVp: number): Promise<void> {
    const isGrid = this.homeListLayout === 'grid';
    const next = this.normalizeCoverSize(sizeVp, isGrid);
    if (isGrid) {
      this.homeGridSize = next;
    } else {
      this.homeListSize = next;
    }
    AppStorage.setOrCreate(isGrid ? 'gridSize' : 'listSize', next);
    await this.settingsManager.setNumber(isGrid ? 'grid_size' : 'list_size', next);
  }

  private async onHomeCoverRadiusChange(value: number): Promise<void> {
    const next = this.normalizeCoverRadius(value);
    this.homeCoverRadius = next;
    AppStorage.setOrCreate('coverCornerRadius', next);
    await this.settingsManager.setNumber(KEY_COVER_CORNER_RADIUS, next);
  }

  private async onSortOrderChange(index: number, value: string | number): Promise<void> {
    this.sortAscending = value !== 'desc';
    await this.settingsManager.setBoolean(KEY_GAME_LIST_SORT_ASCENDING, this.sortAscending);
  }

  private async onGameNameSourceChange(index: number, value: string | number): Promise<void> {
    this.gameNameSource = value === 'filename' ? 'filename' : 'metadata';
    await this.settingsManager.setString(KEY_GAME_NAME_SOURCE, this.gameNameSource);
  }

  private async selectWallpaper(): Promise<void> {
    if (this.isSelectingWallpaper) {
      return;
    }
    this.isSelectingWallpaper = true;
    try {
      const result: WallpaperPickResult = await WallpaperProcessor.pickCustomWallpaper(this.context);
      if (result.success) {
        this.wallpaperUri = `file://${result.filePath}`;
      } else if (!result.cancelled) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('settings_wallpaper_failed'));
      }
    } finally {
      this.isSelectingWallpaper = false;
    }
  }

  private async clearWallpaper(): Promise<void> {
    await WallpaperProcessor.clearWallpaper(this.context);
    this.wallpaperUri = '';
  }

  @Builder
  SectionHeader(title: string) {
    SettingsSectionHeader({ title })
  }

  @Builder
  WallpaperRow() {
    ButtonSettingItem({
      title: I18n.t('settings_home_wallpaper'),
      description: this.wallpaperUri ? I18n.t('settings_custom_wallpaper_set') : I18n.t('settings_wallpaper_uses_theme'),
      disabled: this.isSelectingWallpaper,
      showArrow: false,
      onItemClick: () => {
        this.selectWallpaper();
      }
    })
  }

  @Builder
  ClearWallpaperRow() {
    ButtonSettingItem({
      title: I18n.t('settings_clear_wallpaper'),
      showArrow: false,
      onItemClick: () => {
        this.clearWallpaper();
      }
    })
  }

  build() {
    SettingsList({ scroller: this.scroller }) {
      ListItem() {
        this.SectionHeader(I18n.t('theme'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        // 外观模式与主题色卡同属主题分组，合并为一个项，中间不留分割线
        ListItem() {
          Column() {
            SelectSettingItem({
              title: I18n.t('settings_appearance_mode'),
              options: this.getAppearanceModeOptions(),
              selectedIndex: this.findOptionIndex(this.getAppearanceModeOptions(), this.appearanceMode),
              onSelect: (index: number, value: string | number) => {
                this.onAppearanceModeChange(index, value);
              }
            })
            ThemeSelector({
              selectedThemeId: this.currentThemeId,
              onThemeChange: (themeId: string) => {
                this.themeManager.setTheme(themeId).then(() => {
                  this.currentThemeId = themeId;
                });
              }
            })
          }
        }
        // 应用图标样式选择（仅在系统支持备用图标时显示，API 26+）
        if (this.appIconSupported) {
          ListItem() {
            AppIconSelector()
          }
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('home'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          SelectSettingItem({
            title: I18n.t('settings_default_tab'),
            options: this.getDefaultTabOptions(),
            selectedIndex: this.findOptionIndex(this.getDefaultTabOptions(), this.homeDefaultTab),
            onSelect: (index: number, value: string | number) => {
              this.onHomeDefaultTabChange(index, value);
            }
          })
        }
        ListItem() {
          SelectSettingItem({
            title: I18n.t('settings_game_list_layout'),
            options: this.getGameListLayoutOptions(),
            selectedIndex: this.findOptionIndex(this.getGameListLayoutOptions(), this.homeListLayout),
            onSelect: (index: number, value: string | number) => {
              this.onHomeListLayoutChange(index, value);
            }
          })
        }
        ListItem() {
          SliderSettingItem({
            title: I18n.t('cover_size'),
            value: this.getHomeCoverSize(),
            min: this.homeListLayout === 'grid' ? GRID_COVER_SIZE_MIN : LIST_COVER_SIZE_MIN,
            max: this.homeListLayout === 'grid' ? GRID_COVER_SIZE_MAX : LIST_COVER_SIZE_MAX,
            step: 1,
            continuous: false,
            formatValue: (value: number) => `${value.toFixed(0)}`,
            onChange: (value: number) => {
              this.onHomeCoverSizeChange(value);
            }
          })
        }
        ListItem() {
          SliderSettingItem({
            title: I18n.t('cover_corner_radius'),
            value: this.homeCoverRadius,
            min: 0,
            max: COVER_RADIUS_MAX,
            step: 1,
            continuous: false,
            formatValue: (value: number) => `${value.toFixed(0)}%`,
            onChange: (value: number) => {
              this.onHomeCoverRadiusChange(value);
            }
          })
        }
        ListItem() {
          SelectSettingItem({
            title: I18n.t('game_name_source'),
            options: this.getGameNameSourceOptions(),
            selectedIndex: this.findOptionIndex(this.getGameNameSourceOptions(), this.gameNameSource),
            onSelect: (index: number, value: string | number) => {
              this.onGameNameSourceChange(index, value);
            }
          })
        }
        ListItem() {
          SelectSettingItem({
            title: I18n.t('settings_game_sort_order'),
            options: this.getSortOrderOptions(),
            selectedIndex: this.sortAscending ? 0 : 1,
            onSelect: (index: number, value: string | number) => {
              this.onSortOrderChange(index, value);
            }
          })
        }
        ListItem() {
          this.WallpaperRow()
        }
        if (this.wallpaperUri) {
          ListItem() {
            this.ClearWallpaperRow()
          }
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('language'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          SelectSettingItem({
            title: I18n.t('settings_app_language'),
            options: this.getLanguageOptions(),
            selectedIndex: this.findOptionIndex(this.getLanguageOptions(), this.appLanguage),
            onSelect: (index: number, value: string | number) => {
              this.onLanguageChange(index, value);
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
    }
  }
}

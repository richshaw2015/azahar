import { common, ConfigurationConstant, systemConfiguration } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  AZAHAR_COLOR_MODES,
  AZAHAR_THEMES,
  AzaharColorMode,
  AzaharTheme,
  AzaharThemeColors,
  AzaharThemeId
} from '../types/ThemeTypes';

const PREFERENCES_NAME: string = 'azahar_theme';
const KEY_THEME_ID: string = 'theme_id';
const KEY_COLOR_MODE: string = 'color_mode';
const VALID_THEME_IDS: string[] = AZAHAR_THEMES.map((theme: AzaharTheme) => theme.id);
const LEGACY_THEME_IDS: Record<string, string> = {
  'sky_blue': 'cobalt_blue',
  'mangosteen': 'violet', 'pearl_pink': 'orange',
  'flame_red': 'orange'
};

/** 当前生效的色板在 AppStorage 中的键；UI 组件用 @StorageProp 订阅实现换肤实时刷新。 */
export const THEME_COLORS_STORAGE_KEY: string = 'azaharThemeColors';

export class ThemeManager {
  private static instance: ThemeManager | null = null;
  private prefs: preferences.Preferences | null = null;
  private initialized: boolean = false;
  private currentThemeId: string = AzaharThemeId.Orange;
  private listeners: Set<(theme: AzaharTheme) => void> = new Set();
  private appContext: common.ApplicationContext | null = null;
  private colorMode: AzaharColorMode = 'auto';
  private systemDark: boolean = false;
  private configListenerRegistered: boolean = false;

  static getInstance(): ThemeManager {
    if (!ThemeManager.instance) {
      ThemeManager.instance = new ThemeManager();
    }
    return ThemeManager.instance;
  }

  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }

    this.appContext = context.getApplicationContext();
    this.prefs = await preferences.getPreferences(context, PREFERENCES_NAME);
    const stored = await this.prefs.get(KEY_THEME_ID, AzaharThemeId.Orange) as string;
    const migrated: string = LEGACY_THEME_IDS[stored] ?? stored;
    this.currentThemeId = VALID_THEME_IDS.includes(migrated) ? migrated : AzaharThemeId.Orange;
    const storedMode = await this.prefs.get(KEY_COLOR_MODE, 'auto') as string;
    this.colorMode = AZAHAR_COLOR_MODES.includes(storedMode as AzaharColorMode)
      ? storedMode as AzaharColorMode : 'auto';
    this.systemDark = context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    Environment.envProp('colorMode', ColorMode.LIGHT);
    this.registerConfigListener();
    AppStorage.setOrCreate(THEME_COLORS_STORAGE_KEY, this.getCurrentColors());
    this.initialized = true;
  }

  getCurrentTheme(): AzaharTheme {
    return AZAHAR_THEMES.find((theme: AzaharTheme) => theme.id === this.currentThemeId) ?? AZAHAR_THEMES[0];
  }

  getCurrentColors(): AzaharThemeColors {
    const theme = this.getCurrentTheme();
    if (this.isDarkModeEffective() && theme.darkColors) {
      return theme.darkColors;
    }
    return theme.colors;
  }

  getControlAccent(): string {
    const colors = this.getCurrentColors();
    return colors.controlAccent ?? colors.accent;
  }

  getAllThemes(): AzaharTheme[] {
    return [...AZAHAR_THEMES];
  }

  async setTheme(themeId: string): Promise<void> {
    if (!VALID_THEME_IDS.includes(themeId) || this.currentThemeId === themeId) {
      return;
    }

    this.currentThemeId = themeId;
    if (this.prefs) {
      await this.prefs.put(KEY_THEME_ID, themeId);
      await this.prefs.flush();
    }
    this.notifyListeners();
  }

  getColorMode(): AzaharColorMode {
    return this.colorMode;
  }

  isDarkModeEffective(): boolean {
    if (this.colorMode === 'dark') {
      return true;
    }
    if (this.colorMode === 'light') {
      return false;
    }
    return this.systemDark;
  }

  async setColorMode(mode: AzaharColorMode): Promise<void> {
    if (!AZAHAR_COLOR_MODES.includes(mode) || mode === this.colorMode) {
      return;
    }

    this.colorMode = mode;
    this.applyColorMode();
    if (this.prefs) {
      await this.prefs.put(KEY_COLOR_MODE, mode);
      await this.prefs.flush();
    }
    this.notifyListeners();
  }

  /** 按持久化的模式应用一次，须在主窗口创建（loadContent）后调用。 */
  applyColorMode(): void {
    if (!this.appContext) {
      return;
    }
    let target = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (this.colorMode === 'light') {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (this.colorMode === 'dark') {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    try {
      this.appContext.setColorMode(target);
    } catch (error) {
      console.warn(`ThemeManager: setColorMode failed: ${(error as Error).message}`);
    }
  }

  /** 系统配置变化时同步系统深浅色；仅自动模式下需要刷新自定义主题色。 */
  onSystemColorModeChanged(mode: ConfigurationConstant.ColorMode): void {
    const dark = mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    if (dark === this.systemDark) {
      return;
    }
    this.systemDark = dark;
    if (this.colorMode === 'auto') {
      this.notifyListeners();
    }
  }

  private registerConfigListener(): void {
    if (!this.appContext || this.configListenerRegistered) {
      return;
    }
    try {
      const callback: systemConfiguration.UpdatedCallback = {
        onColorModeUpdated: (mode: ConfigurationConstant.ColorMode) => {
          this.onSystemColorModeChanged(mode);
        }
      };
      this.appContext.onSystemConfigurationUpdated(callback);
      this.configListenerRegistered = true;
    } catch (error) {
      console.error(`ThemeManager: register config listener failed, system color-mode sync disabled: ${(error as Error).message}`);
    }
  }

  addListener(listener: (theme: AzaharTheme) => void): void {
    this.listeners.add(listener);
  }

  removeListener(listener: (theme: AzaharTheme) => void): void {
    this.listeners.delete(listener);
  }

  private notifyListeners(): void {
    AppStorage.setOrCreate(THEME_COLORS_STORAGE_KEY, this.getCurrentColors());
    const theme = this.getCurrentTheme();
    this.listeners.forEach((listener: (theme: AzaharTheme) => void) => {
      try {
        listener(theme);
      } catch (error) {
        // 单个监听者异常不应阻断其余通知，但需保留诊断信息
        console.error(`ThemeManager: theme listener threw: ${(error as Error).message}`);
      }
    });
  }
}

import { preferences } from '@kit.ArkData';
import { i18n, resourceManager } from '@kit.LocalizationKit';
import { PREFERENCES_NAME } from '../types/SettingsTypes';

export type AppLanguage = 'system' | 'zh' | 'en';

export const APP_LANGUAGE_KEY: string = 'app_language';

const APP_LANGUAGE_DEFAULT: AppLanguage = 'system';

/** 语言代码 → resourceManager locale 限定词 */
const LOCALE_MAP: Record<string, string> = {
  'zh': 'zh_CN',
  'en': 'en_US'
};

class I18nManagerClass {
  private static instance: I18nManagerClass | null = null;
  private resMgr: resourceManager.ResourceManager | null = null;
  private overrideResMgr: resourceManager.ResourceManager | null = null;
  private context: Context | null = null;
  private currentLang: AppLanguage = APP_LANGUAGE_DEFAULT;

  private constructor() {}

  static getInstance(): I18nManagerClass {
    if (!I18nManagerClass.instance) {
      I18nManagerClass.instance = new I18nManagerClass();
    }
    return I18nManagerClass.instance;
  }

  async init(context?: Context): Promise<void> {
    if (context) {
      this.context = context;
      this.resMgr = context.resourceManager;
    }
    // 读取用户语言偏好（此时 SettingsManager 尚未初始化，直接读 prefs）
    if (this.context) {
      try {
        const prefs = await preferences.getPreferences(this.context, PREFERENCES_NAME);
        const stored = await prefs.get(APP_LANGUAGE_KEY, APP_LANGUAGE_DEFAULT) as string;
        if (stored === 'zh' || stored === 'en' || stored === 'system') {
          this.currentLang = stored;
        }
      } catch (error) {
        console.warn(`I18nManager: load language preference failed: ${(error as Error).message}`);
      }
      this.rebuildOverride();
    }
  }

  setContext(context: Context): void {
    this.context = context;
    this.resMgr = context.resourceManager;
    if (!this.overrideResMgr) {
      this.rebuildOverride();
    }
  }

  getLanguage(): AppLanguage {
    return this.currentLang;
  }

  /** Intl.* 用的 BCP47 locale tag；与 LOCALE_MAP（resMgr 用的下划线格式）分开定义 */
  getLocaleTag(): string {
    if (this.currentLang === 'zh') {
      return 'zh-CN';
    }
    if (this.currentLang === 'en') {
      return 'en-US';
    }
    try {
      return i18n.System.getSystemLocale();
    } catch (error) {
      console.warn(`[I18nManager] getSystemLocale failed: ${(error as Error).message}`);
      return 'en-US';
    }
  }

  async setLanguage(lang: AppLanguage): Promise<void> {
    if (this.currentLang === lang) {
      return;
    }
    this.currentLang = lang;
    this.rebuildOverride();
    if (this.context) {
      try {
        const prefs = await preferences.getPreferences(this.context, PREFERENCES_NAME);
        await prefs.put(APP_LANGUAGE_KEY, lang);
        await prefs.flush();
      } catch (error) {
        console.warn(`I18nManager: save language preference failed: ${(error as Error).message}`);
      }
    }
  }

  t(key: string, fallback: string = ''): string {
    const mgr = this.overrideResMgr ?? this.resMgr;
    if (mgr) {
      try {
        return mgr.getStringByNameSync(key);
      } catch (_error) {
        // 资源缺失时回退到 fallback 文本（正常路径）
      }
    }
    return fallback || key;
  }

  tf1(key: string, k1: string, v1: string | number, fallback: string = ''): string {
    return this.t(key, fallback).replace(`\${${k1}}`, String(v1));
  }

  tf2(
    key: string,
    k1: string,
    v1: string | number,
    k2: string,
    v2: string | number,
    fallback: string = ''
  ): string {
    return this.t(key, fallback)
      .replace(`\${${k1}}`, String(v1))
      .replace(`\${${k2}}`, String(v2));
  }

  tf3(
    key: string,
    k1: string,
    v1: string | number,
    k2: string,
    v2: string | number,
    k3: string,
    v3: string | number,
    fallback: string = ''
  ): string {
    return this.t(key, fallback)
      .replace(`\${${k1}}`, String(v1))
      .replace(`\${${k2}}`, String(v2))
      .replace(`\${${k3}}`, String(v3));
  }

  /** system 时使用跟随系统的基础 resMgr；zh/en 时构建带 locale 覆盖的 resMgr */
  private rebuildOverride(): void {
    if (!this.resMgr || this.currentLang === 'system') {
      this.overrideResMgr = null;
      return;
    }
    try {
      const overrideCfg = this.resMgr.getOverrideConfiguration();
      overrideCfg.locale = LOCALE_MAP[this.currentLang];
      this.overrideResMgr = this.resMgr.getOverrideResourceManager(overrideCfg);
    } catch (_error) {
      this.overrideResMgr = null;
    }
  }
}

export const I18n = I18nManagerClass.getInstance();

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AzaharConfigValue, AzaharNative } from '../types/AzaharNative';
import { KEY_CPU_CORE_MODE } from '../types/SettingsTypes';
import {
  PREFERENCES_NAME,
  SettingDefinition,
  SettingType,
  SettingValue,
  getDefaultSettingValue,
  getSettingDefinition,
  getSettingDefinitions
} from '../types/SettingsTypes';

export class SettingsManager {
  private static instance: SettingsManager | null = null;
  private prefs: preferences.Preferences | null = null;
  private cache: Map<string, SettingValue> = new Map();
  private initialized: boolean = false;

  static getInstance(): SettingsManager {
    if (!SettingsManager.instance) {
      SettingsManager.instance = new SettingsManager();
    }
    return SettingsManager.instance;
  }

  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }

    this.prefs = await preferences.getPreferences(context, PREFERENCES_NAME);
    await this.loadAll();
    this.initialized = true;
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  getBoolean(key: string): boolean {
    const value = this.cache.get(key) ?? getDefaultSettingValue(key);
    return typeof value === 'boolean' ? value : Boolean(value);
  }

  getNumber(key: string): number {
    const value = this.cache.get(key) ?? getDefaultSettingValue(key);
    return typeof value === 'number' ? value : Number(value);
  }

  getString(key: string): string {
    const value = this.cache.get(key) ?? getDefaultSettingValue(key);
    return typeof value === 'string' ? value : '';
  }

  getStringArray(key: string): string[] {
    const value = this.cache.get(key) ?? getDefaultSettingValue(key);
    return Array.isArray(value) ? value : [];
  }

  getSync<T>(key: string, defaultValue: T): T {
    if (this.cache.has(key)) {
      return this.cache.get(key) as T;
    }
    const definedValue = getDefaultSettingValue(key);
    if (definedValue === '') {
      return defaultValue;
    }
    return definedValue as T;
  }

  async setValue(key: string, value: SettingValue): Promise<void> {
    this.cache.set(key, value);
    // 暂存表先更新：调用方不 await setValue 时，紧随的 applyConfig 仍能读到新值
    const definition = getSettingDefinition(key);
    if (definition?.nativeKey && (typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string')) {
      AzaharNative.setConfig(definition.nativeKey, value as AzaharConfigValue);
    }
    await this.persistValue(key, value);
  }

  async setBoolean(key: string, value: boolean): Promise<void> {
    await this.setValue(key, value);
  }

  async setNumber(key: string, value: number): Promise<void> {
    await this.setValue(key, value);
  }

  async setString(key: string, value: string): Promise<void> {
    await this.setValue(key, value);
  }

  // cpu_core_mode：0=动态重编译(JIT) 1=快速解释器 3=普通解释器；-1=未选择
  //（2=IR 解释器已废弃，老值直接按未选择处理）
  // 未选择时按设备能力推导：JIT 设备默认 JIT，其余默认快速解释器
  getCpuCoreMode(deviceType: string): number {
    const stored = this.getNumber(KEY_CPU_CORE_MODE);
    const jitCapable = AzaharNative.isJitSupported(deviceType);
    if (stored === 1 || stored === 3 || stored === 0 && jitCapable) {
      return stored;
    }
    return jitCapable ? 0 : 1;
  }

  async setCpuCoreMode(mode: number): Promise<void> {
    await this.setNumber(KEY_CPU_CORE_MODE, mode);
  }

  getTabletJitUserEnabled(deviceType: string): boolean {
    return this.getCpuCoreMode(deviceType) === 0;
  }

  // 恢复默认：清空 azahar_settings 偏好与内存缓存，后续 getter 全部回落到 SettingsTypes 默认值；
  // 等价于 Android 端删除 config.ini。主题/目录/游戏配置在独立 prefs 文件中，不受影响。
  async resetAll(): Promise<void> {
    this.cache.clear();
    if (this.prefs) {
      await this.prefs.clear();
      await this.prefs.flush();
    }
  }

  // 全量推送：仅用于初始化/恢复默认等需要重建暂存表的场景。
  // 单项变更不要走这里——会用全局值冲掉游戏会话中 applyNativeOverrides 暂存的单游戏覆盖，
  // 应改用 setValue（已含 setConfig）+ AzaharNative.applyConfig()。
  syncNativeSettings(deviceType: string): void {
    this.syncCpuCoreMode(deviceType);
    const definitions = getSettingDefinitions();
    definitions.forEach((definition: SettingDefinition) => {
      if (!definition.nativeKey) {
        return;
      }
      const key = definition.key;
      const value = this.cache.get(key) ?? definition.defaultValue;
      if (typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') {
        AzaharNative.setConfig(definition.nativeKey, value as AzaharConfigValue);
      }
    });
    AzaharNative.applyConfig();
  }

  // cpu_core_mode 的派生推送：仅更新设备 JIT 掩码与 cpu_core_mode 暂存，不重推全量 nativeKey
  syncCpuCoreMode(deviceType: string): void {
    const cpuCoreMode = this.getCpuCoreMode(deviceType);
    AzaharNative.updateDeviceProfile(deviceType, cpuCoreMode === 0);
    AzaharNative.setConfig('cpu_core_mode', cpuCoreMode);
    AzaharNative.applyConfig();
  }

  private async loadAll(): Promise<void> {
    const definitions = getSettingDefinitions();
    for (let i = 0; i < definitions.length; i++) {
      const definition = definitions[i];
      const key = definition.key;
      const value = await this.loadValue(key, definition.type, definition.defaultValue);
      this.cache.set(key, value);
    }
  }

  private async loadValue(key: string, type: SettingType, defaultValue: SettingValue): Promise<SettingValue> {
    if (!this.prefs) {
      return defaultValue;
    }

    const stored = await this.prefs.get(key, this.serializeDefault(type, defaultValue));
    if (type === SettingType.StringArray) {
      try {
        return JSON.parse(stored as string) as string[];
      } catch (_error) {
        return defaultValue;
      }
    }
    return stored as SettingValue;
  }

  private async persistValue(key: string, value: SettingValue): Promise<void> {
    if (!this.prefs) {
      return;
    }
    if (Array.isArray(value)) {
      await this.prefs.put(key, JSON.stringify(value));
    } else {
      await this.prefs.put(key, value);
    }
    await this.prefs.flush();
  }

  private serializeDefault(type: SettingType, value: SettingValue): boolean | number | string {
    if (type === SettingType.StringArray) {
      return JSON.stringify(value);
    }
    if (typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') {
      return value;
    }
    return '';
  }
}

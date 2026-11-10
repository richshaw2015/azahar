/**
 * AppIconManager - 应用图标管理器
 *
 * 封装 API 26+ 的备用图标（alternateIcons）能力：
 * - 运行时检测系统是否支持 bundleManager.setAlternateIcon
 * - 设置 / 查询当前启用的备用图标
 * - 将用户选择的图标样式持久化到本地偏好
 *
 * 说明：setAlternateIcon / getAlternateIcons 自 API 26.0.0 起可用，
 * 低版本系统上接口不存在，通过 typeof 探测决定设置项是否显示。
 * 对应的备用图标在 AppScope/app.json5 的 alternateIcons 标签中声明。
 */

import { bundleManager } from '@kit.AbilityKit';
import { SettingsManager } from './SettingsManager';
import { KEY_APP_ICON_STYLE } from '../types/SettingsTypes';

const TAG = 'Azahar_AppIconManager';

/** AppStorage 联动键：AppIconView 通过它响应式刷新 */
const APP_ICON_STYLE_STORAGE_KEY = 'appIconStyle';

/** 一个可选的图标样式 */
export interface AppIconStyle {
  /** 传给 setAlternateIcon 的 name；空串表示恢复 app.json5 中的默认图标 */
  alternateName: string;
  /** 样式名称的 i18n key */
  nameKey: string;
  /** 前景图资源（AppScope media，预览用） */
  foreground: Resource;
  /** 背景图资源（AppScope media，预览用） */
  background: Resource;
  /** 256px 小图：小尺寸显示时用，省去 1024px 解码开销 */
  foregroundSmall: Resource;
  backgroundSmall: Resource;
}

/** 全部可选样式：默认图标 + app.json5 alternateIcons 中声明的三个备用图标 */
export const APP_ICON_STYLES: AppIconStyle[] = [
  {
    alternateName: '',
    nameKey: 'app_icon_style_default',
    foreground: $r('app.media.foreground'),
    background: $r('app.media.background'),
    foregroundSmall: $r('app.media.foreground_small'),
    backgroundSmall: $r('app.media.background_small')
  },
  {
    alternateName: 'icon_style2',
    nameKey: 'app_icon_style_alt1',
    foreground: $r('app.media.foreground2'),
    background: $r('app.media.background'),
    foregroundSmall: $r('app.media.foreground2_small'),
    backgroundSmall: $r('app.media.background_small')
  },
  {
    alternateName: 'icon_style3',
    nameKey: 'app_icon_style_alt2',
    foreground: $r('app.media.foreground3'),
    background: $r('app.media.background'),
    foregroundSmall: $r('app.media.foreground3_small'),
    backgroundSmall: $r('app.media.background_small')
  },
  {
    alternateName: 'icon_style4',
    nameKey: 'app_icon_style_alt3',
    foreground: $r('app.media.foreground4'),
    background: $r('app.media.background'),
    foregroundSmall: $r('app.media.foreground4_small'),
    backgroundSmall: $r('app.media.background_small')
  }
];

/** 按备用图标名称解析样式；未知名称回落到默认样式（index 0） */
export function resolveAppIconStyle(alternateName: string): AppIconStyle {
  const found = APP_ICON_STYLES.find((style: AppIconStyle) => style.alternateName === alternateName);
  return found ?? APP_ICON_STYLES[0];
}

export class AppIconManager {
  private static instance: AppIconManager | null = null;

  private constructor() {}

  static getInstance(): AppIconManager {
    if (!AppIconManager.instance) {
      AppIconManager.instance = new AppIconManager();
    }
    return AppIconManager.instance;
  }

  /**
   * 当前系统是否支持运行时切换备用图标（API 26+）。
   * 通过探测接口是否存在来判断，不支持时设置项整体隐藏。
   */
  isAlternateIconSupported(): boolean {
    try {
      return typeof bundleManager.setAlternateIcon === 'function' &&
        typeof bundleManager.getAlternateIcons === 'function';
    } catch (_e) {
      return false;
    }
  }

  /**
   * 应用一个图标样式。alternateName 为空串时恢复默认图标。
   * 成功返回 true，失败返回 false（调用方决定如何提示）。
   */
  async applyStyle(alternateName: string): Promise<boolean> {
    if (!this.isAlternateIconSupported()) {
      return false;
    }
    try {
      await bundleManager.setAlternateIcon(alternateName);
      await this.setSavedStyle(alternateName);
      AppStorage.setOrCreate(APP_ICON_STYLE_STORAGE_KEY, alternateName);
      return true;
    } catch (err) {
      console.error(`[${TAG}] setAlternateIcon failed: ${(err as Error).message}`);
      return false;
    }
  }

  /**
   * 查询当前生效的图标样式。优先读系统状态（getAlternateIcons 的 enabled 标记），
   * 接口不可用时回落到本地偏好。
   */
  async getCurrentStyle(): Promise<string> {
    if (this.isAlternateIconSupported()) {
      try {
        const icons = await bundleManager.getAlternateIcons();
        const enabled = icons.find((icon) => icon.enabled);
        // 未启用任何备用图标时即为默认图标
        return enabled?.iconName ?? '';
      } catch (err) {
        console.warn(`[${TAG}] getAlternateIcons failed: ${(err as Error).message}`);
      }
    }
    return this.getSavedStyle();
  }

  /**
   * 把当前生效的样式写入 AppStorage，供 AppIconView 响应式刷新。
   * 页面显示时调用一次即可，切换动作本身已在 applyStyle 中直接写入。
   */
  async refreshStyleProp(): Promise<void> {
    AppStorage.setOrCreate(APP_ICON_STYLE_STORAGE_KEY, await this.getCurrentStyle());
  }

  getSavedStyle(): string {
    return SettingsManager.getInstance().getString(KEY_APP_ICON_STYLE);
  }

  private async setSavedStyle(alternateName: string): Promise<void> {
    await SettingsManager.getInstance().setString(KEY_APP_ICON_STYLE, alternateName);
  }
}

import { AzaharThemeColors } from '../../types/ThemeTypes';
import { CustomTheme } from '@kit.ArkUI';
import uiMaterial from '@ohos.arkui.uiMaterial';

// ===== 通用样式助手 =====
// 按钮/图标一律用系统 Button + SymbolGlyph 内联书写，不再提供自定义组件封装。

export function controlAccentOf(colors: AzaharThemeColors): string {
  return colors.controlAccent ?? colors.accent;
}

function accentWithAlpha(hexColor: string, alpha: number): string {
  const alphaHex = Math.round(alpha * 255).toString(16).padStart(2, '0').toUpperCase();
  return '#' + alphaHex + hexColor.substring(hexColor.length - 6);
}

/**
 * 把主题强调色映射到系统组件 token，配合 WithTheme 局部作用域使用。
 * 仅覆盖品牌色系 token，中性交互/文本色保持系统默认。
 * 实测注意：
 * - 只能局部包裹页面内系统组件（Slider/ComposeListItem 的 switch 等已验证可用）；
 *   不能当 CustomDialogController builder 的根节点（进程崩溃），也不能用
 *   ThemeControl.setDefaultTheme 全局注入（会让 HDS 组件走 app_theme_pattern
 *   查找路径渲染失败）；HdsNavigation/SegmentButtonV2 等 pattern 组件用显式颜色属性。
 */
export function controlThemeOf(colors: AzaharThemeColors): CustomTheme {
  const accent = controlAccentOf(colors);
  return {
    colors: {
      brand: accent,
      fontEmphasize: accent,
      iconEmphasize: accent,
      iconSubEmphasize: accentWithAlpha(accent, 0.4),
      backgroundEmphasize: accent,
      compBackgroundEmphasize: accent,
      compEmphasizeSecondary: accentWithAlpha(accent, 0.2),
      compEmphasizeTertiary: accentWithAlpha(accent, 0.1),
      interactiveFocus: accent,
      interactiveActive: accent
    }
  };
}

const immersiveMaterialCache: Map<string, uiMaterial.Material | undefined> = new Map();

/**
 * 沉浸光感材质（API 26+ 的通用 .systemMaterial 属性）。设备不支持时返回 undefined。
 * style: ULTRA_THIN 适合小按钮，THIN/REGULAR 适合卡片面板。
 * interactive=true 开启交互形变反馈（拖拽跟手/按压弹性），用于分段按钮等可交互组件。
 */
export function immersiveMaterial(
  style: uiMaterial.ImmersiveStyle = uiMaterial.ImmersiveStyle.THIN,
  interactive: boolean = false
): uiMaterial.Material | undefined {
  const key = `${style}:${interactive}`;
  if (!immersiveMaterialCache.has(key)) {
    let material: uiMaterial.Material | undefined;
    try {
      if (uiMaterial.isImmersiveMaterialSupported()) {
        material = new uiMaterial.ImmersiveMaterial({ style: style, interactive: interactive });
      }
    } catch (e) {
      material = undefined;
    }
    immersiveMaterialCache.set(key, material);
  }
  return immersiveMaterialCache.get(key);
}

import { AzaharThemeColors } from '../types/ThemeTypes';
import {
  BUTTON_BG_SECONDARY,
  INPUT_BG_INLINE,
  SETTING_ITEM_BG,
  SURFACE_CARD,
  SURFACE_TRACK
} from '../types/UIConstants';
import { ThemeManager } from './ThemeManager';

// ===== 浅色模式主题表面着色 =====
// 各容器表面（页面渐变、列表卡片、次级按钮、输入框、封面占位、卡带外壳等）在浅色模式下
// 把主题 primary 低比例混入白色，得到微着色表面色，让主题氛围贯穿整个界面；
// 深色模式一律回落到原 sys.color/app.color token，与之前的视觉完全一致。
// 例外：弹层/面板底（SHEET_BG/SHEET_BG_GROUPED/SHEET_CARD_BG/PAGE_BG/pause_menu_bg）
// 刻意保持中性灰不着色，与系统观感一致；tint 比例统一在此调参。

/** 把 hex 色按 amount 向白色混合：amount=1 返回原色，0 返回白色。 */
export function mixWithWhite(hex: string, amount: number): string {
  const normalized = hex.startsWith('#') ? hex.slice(1) : hex;
  if (normalized.length !== 6) {
    return '#FFFFFF';
  }
  const channels = [0, 2, 4].map((offset: number) => parseInt(normalized.slice(offset, offset + 2), 16));
  if (channels.some((channel: number) => isNaN(channel))) {
    return '#FFFFFF';
  }
  const toHex = (value: number): string => Math.round(255 + (value - 255) * amount)
    .toString(16).padStart(2, '0');
  return `#${toHex(channels[0])}${toHex(channels[1])}${toHex(channels[2])}`;
}

/** 六位 hex 色追加透明度（0~1），返回 #AARRGGBB。 */
export function colorWithAlpha(hex: string, alpha: number): string {
  const alphaHex = Math.round(alpha * 255).toString(16).padStart(2, '0').toUpperCase();
  return '#' + alphaHex + hex.substring(hex.length - 6);
}

// 各表面的浅色 tint 比例，只分两级：
// 表面级（卡片、卡带外壳、封面占位、选中角标）浅混，元素级（按钮、输入框、轨道、普通角标）略深一档。
const TINT_SURFACE: number = 0.1;
const TINT_ELEMENT: number = 0.14;

function isDark(): boolean {
  return ThemeManager.getInstance().isDarkModeEffective();
}

function tinted(colors: AzaharThemeColors, tint: number, darkFallback: ResourceColor, alpha?: number): ResourceColor {
  if (isDark()) {
    return darkFallback;
  }
  const mixed = mixWithWhite(colors.primary, tint);
  return alpha === undefined ? mixed : colorWithAlpha(mixed, alpha);
}

/** 页面渐变底色：浅色用主题自带的渐变双色，深色保持中性渐变。 */
export function pageGradientOf(colors: AzaharThemeColors): ResourceColor[] {
  if (isDark()) {
    return [$r('app.color.bg_gradient_top'), $r('app.color.bg_gradient_bottom')];
  }
  return [colors.gradientStart, colors.gradientEnd];
}

/** 普通卡片底（原 SURFACE_CARD=card_bg）。 */
export function surfaceCardBgOf(colors: AzaharThemeColors): ResourceColor {
  return tinted(colors, TINT_SURFACE, SURFACE_CARD);
}

/** 设置列表分组卡底（原 SETTING_ITEM_BG=list_card_bg），用于 ListItemGroup CARD。 */
export function listCardBgOf(colors: AzaharThemeColors): ResourceColor {
  return tinted(colors, TINT_SURFACE, SETTING_ITEM_BG);
}

/** 选中项卡片底：使用元素级强调色 tint，深色模式回落到列表卡底。 */
export function selectedCardBgOf(colors: AzaharThemeColors): ResourceColor {
  return tinted(colors, TINT_ELEMENT, SETTING_ITEM_BG);
}

/** 非强调按钮底（原 BUTTON_BG_SECONDARY=button_normal）。 */
export function secondaryButtonBgOf(colors: AzaharThemeColors): ResourceColor {
  return tinted(colors, TINT_ELEMENT, BUTTON_BG_SECONDARY);
}

/** 行内输入框底（原 INPUT_BG_INLINE=text_field_sub_bg）。 */
export function inputBgOf(colors: AzaharThemeColors): ResourceColor {
  return tinted(colors, TINT_ELEMENT, INPUT_BG_INLINE);
}

/** 凹陷轨道/缩略图容器底（原 SURFACE_TRACK=component_normal）。 */
export function trackSurfaceBgOf(colors: AzaharThemeColors): ResourceColor {
  return tinted(colors, TINT_ELEMENT, SURFACE_TRACK);
}

// ===== 封面/卡带元素 =====

/** 封面无图占位底（原 cartridge_art_bg，99 半透明）。 */
export function coverArtBgOf(colors: AzaharThemeColors): ResourceColor {
  return tinted(colors, TINT_SURFACE, $r('app.color.cartridge_art_bg'), 0x99 / 0xFF);
}

/** 封面占位符底（原 cartridge_placeholder，80 半透明）。 */
export function coverPlaceholderBgOf(colors: AzaharThemeColors): ResourceColor {
  return tinted(colors, TINT_SURFACE, $r('app.color.cartridge_placeholder'), 0x80 / 0xFF);
}

/** 瓦片角标底（原 tile_badge_bg，D9 半透明）。 */
export function tileBadgeBgOf(colors: AzaharThemeColors): ResourceColor {
  return tinted(colors, TINT_ELEMENT, $r('app.color.tile_badge_bg'), 0xD9 / 0xFF);
}

/** 选中态瓦片角标底（原 tile_badge_bg_active，EB 半透明）。 */
export function tileBadgeActiveBgOf(colors: AzaharThemeColors): ResourceColor {
  return tinted(colors, TINT_SURFACE, $r('app.color.tile_badge_bg_active'), 0xEB / 0xFF);
}

/** 卡带浅色外壳：拟物塑料感，着色比普通卡片更克制（深色分支由 cover/primary 另行派生，不走这里）。 */
export function cartridgeShellBgOf(colors: AzaharThemeColors): string {
  return mixWithWhite(colors.primary, TINT_SURFACE);
}

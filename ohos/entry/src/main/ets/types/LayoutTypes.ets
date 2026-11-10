/**
 * Azahar - 触屏按键布局类型定义
 *
 * 移植自 NDS 项目的布局系统:
 * - LayoutComponent: 所有可布局的 UI 组件枚举
 * - PositionedLayoutComponent: 带位置信息的组件
 * - ScreenLayout / UILayout / LayoutConfiguration: 布局配置层级
 */
import { I18n } from '../utils/I18nManager';

// ============================================================================
// 基础几何类型
// ============================================================================

export interface LayoutRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

// ============================================================================
// 布局组件枚举
// ============================================================================

export enum LayoutComponent {
  // 屏幕组件（3DS 双屏）
  TOP_SCREEN = 'TOP_SCREEN',
  BOTTOM_SCREEN = 'BOTTOM_SCREEN',
  // 方向键
  DPAD = 'DPAD',
  // 摇杆（主摇杆/C 摇杆，各为一个整体组件）
  STICK = 'STICK',
  CSTICK = 'CSTICK',
  // 主按钮组 (ABXY)
  BUTTONS = 'BUTTONS',
  // 系统按钮
  BUTTON_START = 'BUTTON_START',
  BUTTON_SELECT = 'BUTTON_SELECT',
  BUTTON_HOME = 'BUTTON_HOME',
  BUTTON_L = 'BUTTON_L',
  BUTTON_R = 'BUTTON_R',
  BUTTON_ZL = 'BUTTON_ZL',
  BUTTON_ZR = 'BUTTON_ZR',
  // 功能按钮
  BUTTON_FAST_FORWARD_TOGGLE = 'BUTTON_FAST_FORWARD_TOGGLE',
  BUTTON_SLOW_MOTION_TOGGLE = 'BUTTON_SLOW_MOTION_TOGGLE',
  BUTTON_TOGGLE_SOFT_INPUT = 'BUTTON_TOGGLE_SOFT_INPUT',
  BUTTON_RESET = 'BUTTON_RESET',
  BUTTON_PAUSE = 'BUTTON_PAUSE',
  BUTTON_SWAP_SCREENS = 'BUTTON_SWAP_SCREENS',
  BUTTON_QUICK_SAVE = 'BUTTON_QUICK_SAVE',
  BUTTON_QUICK_LOAD = 'BUTTON_QUICK_LOAD',
  BUTTON_HINGE = 'BUTTON_HINGE',
  BUTTON_MICROPHONE_TOGGLE = 'BUTTON_MICROPHONE_TOGGLE',
  BUTTON_MORE = 'BUTTON_MORE',
  BUTTON_SETTINGS = 'BUTTON_SETTINGS',
  BUTTON_SCREEN_ROTATION = 'BUTTON_SCREEN_ROTATION',
  // 宏按键：按下同时触发一组 3DS 按键（按键集在手柄设置 → 组合按键集配置）
  BUTTON_MACRO = 'BUTTON_MACRO',
}

/** 所有布局组件值列表 */
export const ALL_LAYOUT_COMPONENTS: LayoutComponent[] = [
  LayoutComponent.TOP_SCREEN,
  LayoutComponent.BOTTOM_SCREEN,
  LayoutComponent.DPAD,
  LayoutComponent.BUTTONS,
  LayoutComponent.STICK,
  LayoutComponent.CSTICK,
  LayoutComponent.BUTTON_START,
  LayoutComponent.BUTTON_SELECT,
  LayoutComponent.BUTTON_HOME,
  LayoutComponent.BUTTON_L,
  LayoutComponent.BUTTON_R,
  LayoutComponent.BUTTON_ZL,
  LayoutComponent.BUTTON_ZR,
  LayoutComponent.BUTTON_FAST_FORWARD_TOGGLE,
  LayoutComponent.BUTTON_SLOW_MOTION_TOGGLE,
  LayoutComponent.BUTTON_TOGGLE_SOFT_INPUT,
  LayoutComponent.BUTTON_RESET,
  LayoutComponent.BUTTON_PAUSE,
  LayoutComponent.BUTTON_SWAP_SCREENS,
  LayoutComponent.BUTTON_QUICK_SAVE,
  LayoutComponent.BUTTON_QUICK_LOAD,
  LayoutComponent.BUTTON_HINGE,
  LayoutComponent.BUTTON_MICROPHONE_TOGGLE,
  LayoutComponent.BUTTON_MORE,
  LayoutComponent.BUTTON_MACRO,
  LayoutComponent.BUTTON_SETTINGS,
  LayoutComponent.BUTTON_SCREEN_ROTATION,
];

/** 判断组件是否为屏幕 */
export function isScreenComponent(component: LayoutComponent): boolean {
  return component === LayoutComponent.TOP_SCREEN || component === LayoutComponent.BOTTOM_SCREEN;
}

/** 组件显示名称 */
export function getComponentDisplayName(component: LayoutComponent): string {
  const names: Record<string, string> = {
    'TOP_SCREEN': I18n.t('comp_top_screen'),
    'BOTTOM_SCREEN': I18n.t('comp_bottom_screen'),
    'DPAD': I18n.t('comp_dpad'),
    'BUTTONS': 'ABXY',
    'STICK': I18n.t('comp_stick'),
    'CSTICK': I18n.t('comp_cstick'),
    'BUTTON_START': 'Start',
    'BUTTON_SELECT': 'Select',
    'BUTTON_HOME': 'Home',
    'BUTTON_L': 'L',
    'BUTTON_R': 'R',
    'BUTTON_ZL': 'ZL',
    'BUTTON_ZR': 'ZR',
    'BUTTON_FAST_FORWARD_TOGGLE': I18n.t('comp_fast_forward'),
    'BUTTON_SLOW_MOTION_TOGGLE': I18n.t('comp_slow_motion'),
    'BUTTON_TOGGLE_SOFT_INPUT': I18n.t('comp_toggle_soft_input'),
    'BUTTON_RESET': I18n.t('comp_reset'),
    'BUTTON_PAUSE': I18n.t('comp_pause'),
    'BUTTON_SWAP_SCREENS': I18n.t('comp_swap_screens'),
    'BUTTON_QUICK_SAVE': I18n.t('comp_quick_save'),
    'BUTTON_QUICK_LOAD': I18n.t('comp_quick_load'),
    'BUTTON_HINGE': I18n.t('comp_hinge'),
    'BUTTON_MICROPHONE_TOGGLE': I18n.t('comp_microphone'),
    'BUTTON_MORE': I18n.t('comp_more'),
    'BUTTON_MACRO': I18n.t('comp_macro'),
    'BUTTON_SETTINGS': I18n.t('settings'),
    'BUTTON_SCREEN_ROTATION': I18n.t('comp_screen_rotation'),
  };
  return names[component] ?? component;
}

/** 组件对应的图片资源名 (rawfile) */
export function getComponentImageName(component: LayoutComponent): string {
  const images: Record<string, string> = {
    'DPAD': 'keypad.png',
    'BUTTONS': 'buttons.png',
    'STICK': 'stick_main.png',
    'CSTICK': 'stick_c.png',
    'BUTTON_START': 'button_start.png',
    'BUTTON_SELECT': 'button_select.png',
    'BUTTON_HOME': 'button_home.png',
    'BUTTON_L': 'button_l.png',
    'BUTTON_R': 'button_r.png',
    'BUTTON_ZL': 'button_zl.png',
    'BUTTON_ZR': 'button_zr.png',
    'BUTTON_FAST_FORWARD_TOGGLE': 'button_fast_forward_disabled.png',
    'BUTTON_SLOW_MOTION_TOGGLE': 'button_slow_motion_disabled.png',
    'BUTTON_TOGGLE_SOFT_INPUT': 'ic_touch_enabled.png',
    'BUTTON_RESET': 'button_reset.png',
    'BUTTON_PAUSE': 'button_pause.png',
    'BUTTON_SWAP_SCREENS': 'button_swap_screens.png',
    'BUTTON_QUICK_SAVE': 'button_quick_save.png',
    'BUTTON_QUICK_LOAD': 'button_quick_load.png',
    'BUTTON_HINGE': 'button_toggle_lid.png',
    'BUTTON_MICROPHONE_TOGGLE': 'button_microphone_disabled.png',
    'BUTTON_MORE': 'button_more.png',
    'BUTTON_MACRO': 'button_macro.png',
    'BUTTON_SETTINGS': 'setting.png',
    'BUTTON_SCREEN_ROTATION': 'button_rotation.png',
  };
  return images[component] ?? '';
}

// ============================================================================
// 带位置的布局组件 (对齐 Android PositionedLayoutComponent.kt)
// ============================================================================

export interface PositionedLayoutComponent {
  /** 组件在布局中的位置和尺寸 (vp 单位，相对于视口) */
  rect: LayoutRect;
  /** 组件类型 */
  component: LayoutComponent;
}

// ============================================================================
// UI 布局变体 (对齐 Android UILayoutVariant.kt — 简化版，无 folds/displays)
// ============================================================================

export enum Orientation {
  PORTRAIT = 'PORTRAIT',
  LANDSCAPE = 'LANDSCAPE',
}

/**
 * 布局变体键 (对齐 Android UILayoutVariant)
 * 简化版: 仅 uiSize + orientation (ohos 单屏手机，无折叠/多屏)
 */
export interface UILayoutVariant {
  width: number;
  height: number;
  orientation: Orientation;
}

/** 将 UILayoutVariant 序列化为 Map key 字符串 */
export function variantToKey(v: UILayoutVariant): string {
  return `${v.width}x${v.height}_${v.orientation}`;
}

/** 从 Map key 字符串反序列化 UILayoutVariant */
export function keyToVariant(key: string): UILayoutVariant | null {
  const match = key.match(/^(\d+)x(\d+)_(PORTRAIT|LANDSCAPE)$/);
  if (!match) return null;
  return { width: parseInt(match[1]), height: parseInt(match[2]), orientation: match[3] as Orientation };
}

/**
 * UI 布局 (对齐 Android UILayout — 简化版，单屏)
 * 包含一个变体下的所有组件
 */
export interface UILayout {
  components: PositionedLayoutComponent[];
  /**
   * 该变体内组件矩形是在哪个按键遮罩主题下配置的。
   * 用于换主题时按"相对设计尺寸"换算 L/R、SELECT/START 矩形。
   * 旧数据无此字段，读取时按"来源主题=当前主题"处理（仅重算宽高比）。
   */
  theme?: string;
}

// ============================================================================
// 布局配置 (对齐 Android LayoutConfiguration.kt)
// ============================================================================

export enum LayoutType {
  DEFAULT = 'DEFAULT',
  CUSTOM = 'CUSTOM',
}

export enum LayoutOrientation {
  FOLLOW_SYSTEM = 'FOLLOW_SYSTEM',
  PORTRAIT = 'PORTRAIT',
  LANDSCAPE = 'LANDSCAPE',
}

export interface LayoutConfiguration {
  /** 唯一标识 */
  id: string;
  /** 布局名称 */
  name: string;
  /** 布局类型 */
  type: LayoutType;
  /** 方向 */
  orientation: LayoutOrientation;
  /** 是否使用自定义透明度 */
  useCustomOpacity: boolean;
  /** 自定义透明度 (0-100) */
  opacity: number;
  /** 副屏画面透明度 (0-100) */
  secondaryScreenOpacity: number;
  /**
   * 变体布局映射 (对齐 Android layoutVariants: Map<UILayoutVariant, UILayout>)
   * key = variantToKey(variant), value = UILayout
   */
  layoutVariants: Record<string, UILayout>;
  /** 背景图片 URI (对齐 Android ScreenLayout.backgroundId) */
  backgroundUri?: string;
  /** 背景显示模式 (对齐 Android BackgroundMode) */
  backgroundMode?: BackgroundMode;
  /** 创建时间 */
  createdAt: number;
  /** 更新时间 */
  updatedAt: number;
}

/**
 * 背景显示模式 - 对齐 Android BackgroundMode (6 种)
 */
export enum BackgroundMode {
  STRETCH = 'STRETCH',
  FIT_CENTER = 'FIT_CENTER',
  FIT_TOP = 'FIT_TOP',
  FIT_LEFT = 'FIT_LEFT',
  FIT_BOTTOM = 'FIT_BOTTOM',
  FIT_RIGHT = 'FIT_RIGHT',
}

/** 背景显示模式的显示名称 */
export function getBackgroundModeLabel(mode: BackgroundMode): string {
  switch (mode) {
    case BackgroundMode.STRETCH: return I18n.t('bg_mode_stretch');
    case BackgroundMode.FIT_CENTER: return I18n.t('bg_mode_fit_center');
    case BackgroundMode.FIT_TOP: return I18n.t('bg_mode_fit_top');
    case BackgroundMode.FIT_LEFT: return I18n.t('bg_mode_fit_left');
    case BackgroundMode.FIT_BOTTOM: return I18n.t('bg_mode_fit_bottom');
    case BackgroundMode.FIT_RIGHT: return I18n.t('bg_mode_fit_right');
  }
}

/**
 * 系统主题色背景的特殊 URI 标识
 * 选中后，布局编辑器和游戏内背景显示为当前主题色渐变 + 颗粒感纹理
 * 参考 iPod 项目的 noise texture 实现
 */
export const THEME_COLOR_BG_URI = '__theme_color__';

/**
 * 内置皮肤背景的 URI 前缀。
 * 布局 backgroundUri 形如 'rawfile:themes/drastic/background.png' 时，
 * 渲染方用 $rawfile(去前缀路径) 加载打包素材；其余 URI 仍按用户图片处理。
 */
export const RAWFILE_BG_URI_PREFIX = 'rawfile:';

export function isRawfileBgUri(uri: string | undefined): boolean {
  return !!uri && uri.startsWith(RAWFILE_BG_URI_PREFIX);
}

export function rawfileBgPath(uri: string): string {
  return uri.substring(RAWFILE_BG_URI_PREFIX.length);
}

/**
 * 内置皮肤背景 — 随按键遮罩素材打包，不可删除，显示名复用主题名。
 * 目前 drastic (黑金) / snes (猫爪) 素材包含 background.png。
 */
export interface BuiltinLayoutBackground {
  id: string;
  themeId: string;
  uri: string;
}

export const BUILTIN_BACKGROUNDS: BuiltinLayoutBackground[] = [
  { id: 'builtin_bg_drastic', themeId: 'drastic', uri: RAWFILE_BG_URI_PREFIX + 'themes/drastic/background.png' },
  { id: 'builtin_bg_snes', themeId: 'snes', uri: RAWFILE_BG_URI_PREFIX + 'themes/snes/background.png' },
];

/** 所有背景显示模式 */
export const ALL_BACKGROUND_MODES: BackgroundMode[] = [
  BackgroundMode.STRETCH,
  BackgroundMode.FIT_CENTER,
  BackgroundMode.FIT_TOP,
  BackgroundMode.FIT_LEFT,
  BackgroundMode.FIT_BOTTOM,
  BackgroundMode.FIT_RIGHT,
];

/**
 * 背景数据模型 - 对齐 Android Background(id, name, uri)
 */
export interface LayoutBackground {
  id: string;
  name: string;
  uri: string;
}

/** 序列化的背景列表 */
export interface SerializedBackgrounds {
  backgrounds: LayoutBackground[];
}

// ============================================================================
// 序列化类型 (用于持久化)
// ============================================================================

export interface SerializedLayoutComponent {
  x: number;
  y: number;
  w: number;
  h: number;
  c: string; // component enum value
}

export interface SerializedUILayout {
  components: SerializedLayoutComponent[];
  theme?: string;
}

export interface SerializedLayoutConfig {
  id: string;
  name: string;
  type: string;
  orientation: string;
  useCustomOpacity: boolean;
  opacity: number;
  secondaryScreenOpacity?: number;
  variants?: Record<string, SerializedUILayout>;
  backgroundUri?: string;
  backgroundMode?: string;
  createdAt: number;
  updatedAt: number;
}

/** 序列化 PositionedLayoutComponent */
export function serializeComponent(comp: PositionedLayoutComponent): SerializedLayoutComponent {
  return { x: comp.rect.x, y: comp.rect.y, w: comp.rect.width, h: comp.rect.height, c: comp.component };
}

/** 反序列化 PositionedLayoutComponent */
export function deserializeComponent(data: SerializedLayoutComponent): PositionedLayoutComponent {
  return {
    rect: { x: data.x, y: data.y, width: data.w, height: data.h },
    component: data.c as LayoutComponent,
  };
}

/** 序列化 LayoutConfiguration */
export function serializeLayout(config: LayoutConfiguration): SerializedLayoutConfig {
  const variants: Record<string, SerializedUILayout> = {};
  const keys = Object.keys(config.layoutVariants);
  for (const key of keys) {
    const layout = config.layoutVariants[key];
    variants[key] = { components: layout.components.map(serializeComponent), theme: layout.theme };
  }
  return {
    id: config.id,
    name: config.name,
    type: config.type,
    orientation: config.orientation,
    useCustomOpacity: config.useCustomOpacity,
    opacity: config.opacity,
    secondaryScreenOpacity: config.secondaryScreenOpacity,
    variants: variants,
    backgroundUri: config.backgroundUri,
    backgroundMode: config.backgroundMode,
    createdAt: config.createdAt,
    updatedAt: config.updatedAt,
  };
}

/** 反序列化 LayoutConfiguration */
export function deserializeLayout(data: SerializedLayoutConfig): LayoutConfiguration {
  let layoutVariants: Record<string, UILayout> = {};

  if (data.variants && Object.keys(data.variants).length > 0) {
    const keys = Object.keys(data.variants);
    for (const key of keys) {
      const sv = data.variants[key];
      layoutVariants[key] = {
        components: (sv.components ?? []).map(deserializeComponent),
        theme: sv.theme,
      };
    }
  }

  return {
    id: data.id,
    name: data.name,
    type: (data.type as LayoutType) ?? LayoutType.CUSTOM,
    orientation: (data.orientation as LayoutOrientation) ?? LayoutOrientation.FOLLOW_SYSTEM,
    useCustomOpacity: data.useCustomOpacity ?? false,
    opacity: data.opacity ?? 50,
    secondaryScreenOpacity: data.secondaryScreenOpacity ?? 100,
    layoutVariants: layoutVariants,
    backgroundUri: data.backgroundUri,
    backgroundMode: (data.backgroundMode as BackgroundMode) ?? undefined,
    createdAt: data.createdAt ?? Date.now(),
    updatedAt: data.updatedAt ?? Date.now(),
  };
}

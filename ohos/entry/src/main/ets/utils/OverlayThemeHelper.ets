import { LayoutRect } from '../types/LayoutTypes';

const THEMED_FILES: Set<string> = new Set([
  'button_l.png',
  'button_r.png',
  'button_zl.png',
  'button_zr.png',
  'button_home.png',
  'button_select.png',
  'button_start.png',
  'buttons.png',
  'keypad.png',
  'buttons_A.png',
  'buttons_B.png',
  'buttons_X.png',
  'buttons_Y.png',
  'background.png',
  'button_fast_forward.png',
  'button_fast_forward_disabled.png',
  'button_slow_motion.png',
  'button_slow_motion_disabled.png',
  'button_microphone.png',
  'button_microphone_disabled.png',
  'button_macro.png',
  'button_more.png',
  'button_pause.png',
  'button_quick_load.png',
  'button_quick_save.png',
  'button_reset.png',
  'button_rotation.png',
  'button_swap_screens.png',
  'button_toggle_lid.png',
  'ic_touch_disabled.png',
  'ic_touch_enabled.png',
  'setting.png',
  'stick_main.png',
  'stick_main_range.png',
  'stick_c.png',
  'stick_c_range.png',
]);

export const OVERLAY_THEME_IDS: string[] = ['default', 'drastic', 'snes', 'clear', 'ps'];

export function getOverlayThemeNameKey(themeId: string): string {
  const keys: Record<string, string> = {
    'default': 'overlay_theme_classic',
    'drastic': 'overlay_theme_drastic',
    'snes': 'overlay_theme_snes',
    'clear': 'overlay_theme_crystal',
    'ps': 'overlay_theme_ps',
  };
  return keys[themeId] ?? themeId;
}

export function themedImagePath(filename: string, overlayTheme: string): string {
  if (filename.length === 0) {
    return filename;
  }
  if (THEMED_FILES.has(filename)) {
    return `themes/${overlayTheme}/${filename}`;
  }
  return filename;
}

// ============================================================================
// 主题素材尺寸元数据 — 用于让按钮渲染矩形匹配各主题素材的原生宽高比，
// 避免使用 ImageFit.Contain 时出现的"视觉缩水 + 点击区域过大"问题。
// ============================================================================

interface ThemeAssetMetric {
  w: number;
  h: number;
}

interface ThemeMetrics {
  lr: ThemeAssetMetric; // button_l, button_r
  ss: ThemeAssetMetric; // button_start, button_select
  /**
   * 设计尺寸缩放系数 (默认 1.0)
   * 若某主题素材在设计上就应该比其它主题更大/更小，调它即可。
   * 作用于 designedButtonRect，即"该主题的设计默认尺寸"。
   */
  designScale?: number;
}

const THEME_METRICS: Record<string, ThemeMetrics> = {
  'default': { lr: { w: 174, h: 76 }, ss: { w: 118, h: 62 } },
  'drastic': { lr: { w: 169, h: 80 }, ss: { w: 120, h: 56 } },
  'snes': { lr: { w: 210, h: 88 }, ss: { w: 55, h: 74 } },
  'clear': { lr: { w: 178, h: 60 }, ss: { w: 89, h: 35 } },
  'ps': { lr: { w: 224, h: 68 }, ss: { w: 68, h: 44 } },
};

const FALLBACK_METRIC: ThemeAssetMetric = { w: 1, h: 1 };

export const ACTION_BUTTON_BASE_SIZE: number = 40;
export const CONTROL_EDGE_MARGIN: number = 12;

interface OverlayControlRatios {
  lrWidthToAction: number;
  ssWidthToAction: number;
  dpadVisibleWidthToAction: number;
  abxyClusterToAction: number;
  stickWidthToAction: number;
  cStickWidthToAction: number;
}

const DPAD_VISIBLE_CONTENT_RATIO: number = 0.94;

const THEME_CONTROL_RATIOS: Record<string, OverlayControlRatios> = {
  'default': {
    lrWidthToAction: 2.43,
    ssWidthToAction: 1.65,
    dpadVisibleWidthToAction: 3.29,
    abxyClusterToAction: 3.72,
    stickWidthToAction: 2.06*1.1,
    cStickWidthToAction: 1.03,
  },
  'drastic': {
    lrWidthToAction: 1.64,
    ssWidthToAction: 1.22,
    dpadVisibleWidthToAction: 2.38,
    abxyClusterToAction: 3.60,
    stickWidthToAction: 1.90,
    cStickWidthToAction: 0.95,
  },
  'snes': {
    lrWidthToAction: 1.85,
    ssWidthToAction: 0.56,
    dpadVisibleWidthToAction: 2.69,
    abxyClusterToAction: 4.07,
    stickWidthToAction: 2.15,
    cStickWidthToAction: 1.08,
  },
  'clear': {
    lrWidthToAction: 2.30,
    ssWidthToAction: 0.91,
    dpadVisibleWidthToAction: 3.34,
    abxyClusterToAction: 5.06,
    stickWidthToAction: 2.67,
    cStickWidthToAction: 1.34,
  },
  'ps': {
    lrWidthToAction: 2.55,
    ssWidthToAction: 0.69,
    dpadVisibleWidthToAction: 3.71,
    abxyClusterToAction: 5.62,
    stickWidthToAction: 2.97,
    cStickWidthToAction: 1.48,
  },
};

export interface OverlayControlSizes {
  action: number;
  lrWidth: number;
  lrHeight: number;
  ssWidth: number;
  ssHeight: number;
  dpad: number;
  abxy: number;
  stick: number;
  cStick: number;
}

export function getOverlayControlSizes(
  theme: string = 'default',
  actionBase: number = ACTION_BUTTON_BASE_SIZE,
): OverlayControlSizes {
  const ratios = THEME_CONTROL_RATIOS[theme] ?? THEME_CONTROL_RATIOS.default;
  const metrics = THEME_METRICS[theme] ?? THEME_METRICS.default;
  const action = actionBase;
  const lrWidth = action * ratios.lrWidthToAction;
  const ssWidth = action * ratios.ssWidthToAction;
  return {
    action: action,
    lrWidth: lrWidth,
    lrHeight: lrWidth * metrics.lr.h / metrics.lr.w,
    ssWidth: ssWidth,
    ssHeight: ssWidth * metrics.ss.h / metrics.ss.w,
    dpad: action * ratios.dpadVisibleWidthToAction / DPAD_VISIBLE_CONTENT_RATIO,
    abxy: action * ratios.abxyClusterToAction,
    stick: action * ratios.stickWidthToAction,
    cStick: action * ratios.cStickWidthToAction,
  };
}

export interface ButtonRect {
  width: number;
  height: number;
}

export type ThemedButtonKind = 'lr' | 'ss';

/**
 * 短边相对于 shortBase 的最小比例 — 防止极扁长素材 (如 clear 3:1)
 * 把短边压得太小不利于点击。0.7 表示短边至少为 shortBase 的 70%。
 */
const MIN_SHORT_RATIO = 0.7;

/**
 * 非方形主题的 L/R 在面积守恒计算后仍偏大 (drastic / clear 都是 3:1 上下)，
 * 统一在视觉上再缩小 20%。default 主题 L/R 是 1:1，不受影响。
 */
const NON_SQUARE_LR_SCALE = 0.8;

/**
 * SELECT/START 在垂直方向对齐到 DPad/ABXY 区域里"底部按钮"中心 (B 键 / DOWN 方向键)，
 * 而不是整个簇的几何中心。ABXY 区域中 B 键中心 Y = areaSize × 0.81，
 * DPad 的 DOWN 视觉中心也接近这个位置，统一使用此比例。
 *
 * 公式:  selectStartY = dpadAbxyTopY + largeButtonSize × LOWER_BUTTON_CENTER_RATIO − ssH / 2
 */
export const LOWER_BUTTON_CENTER_RATIO = 0.81;

/**
 * 竖屏 SELECT/START 经横向收缩后高度的最低值 (vp)。
 * drastic 主题素材 128×52 (2.46:1) 在 360 vp 视口下被压到 38×15，太矮难以拖拽。
 * 加这个下限把矩形高度抬到 ~8.6mm，未来更扁的主题也自动受益。
 * 多出来的部分会成为 ImageFit.Contain 的透明 letterbox，视觉上素材尺寸不变。
 */
const MIN_PORTRAIT_SS_HEIGHT = 26;

/**
 * 竖屏下，SELECT/START 需要放进 DPad 和 ABXY 之间的横向空隙里。
 * 当主题矩形比扣除两侧边距后的空隙还宽时，等比缩小宽高以避开两侧簇。
 *
 *   gap = viewportWidth − dpadSize − abxySize − 2 × CONTROL_EDGE_MARGIN
 *   maxSsW = gap − 2 × spacing
 *
 * 若 ssRect.width ≤ maxSsW 直接返回原矩形 (default / snes / clear / ps 均无需收缩)；
 * 否则按比例缩，保持主题素材的宽高比，让 ImageFit.Contain 不会再出现 letterbox 死区。
 * 收缩后高度若低于 MIN_PORTRAIT_SS_HEIGHT，向上兜底为该阈值 — 避免极端比例下点击/拖拽失效。
 */
export function clampSsRectForPortraitGap(
  ssRect: ButtonRect,
  viewportWidth: number,
  dpadSize: number,
  abxySize: number,
  spacing: number,
): ButtonRect {
  const gap = viewportWidth - dpadSize - abxySize - CONTROL_EDGE_MARGIN * 2;
  const maxSsW = gap - spacing * 2;
  if (maxSsW <= 0 || ssRect.width <= maxSsW) {
    return ssRect;
  }
  const scale = maxSsW / ssRect.width;
  const aspectPreservedHeight = ssRect.height * scale;
  return {
    width: maxSsW,
    height: Math.max(MIN_PORTRAIT_SS_HEIGHT, aspectPreservedHeight),
  };
}

/**
 * 根据主题素材的原生宽高比计算按钮渲染矩形。
 *
 * 采用"面积守恒"策略 — 目标矩形面积 ≈ shortBase²，但按素材宽高比拉伸：
 *   shortSide = shortBase / sqrt(ratio)
 *   longSide  = shortSide × ratio  (= shortBase × sqrt(ratio))
 *
 * 这样:
 *   1. 方形素材完全保持原 shortBase × shortBase；
 *   2. 拉长素材视觉宽高比与原图一致，
 *      但总面积接近方形版本，不会出现按钮过大的情况；
 *   3. 短边经 MIN_SHORT_RATIO 兜底，避免极端比例下点击区域过窄。
 *
 * 未知主题时退化为 1:1，保持与旧行为一致。
 */
export function getOverlayButtonRect(
  theme: string,
  kind: ThemedButtonKind,
  shortBase: number,
): ButtonRect {
  const themeMetrics = THEME_METRICS[theme];
  let metric: ThemeAssetMetric;
  if (themeMetrics) {
    metric = kind === 'lr' ? themeMetrics.lr : themeMetrics.ss;
  } else {
    metric = FALLBACK_METRIC;
  }
  // SELECT/START 与 L/R 使用同一像素缩放，保持设计素材间的相对大小
  if (kind === 'ss' && themeMetrics) {
    const lrMetric = themeMetrics.lr;
    const lrRect = getOverlayButtonRect(theme, 'lr', shortBase * STANDARD_BASE.lr / STANDARD_BASE.ss);
    const pxScale = Math.max(lrRect.width, lrRect.height) / Math.max(lrMetric.w, lrMetric.h);
    return { width: metric.w * pxScale, height: metric.h * pxScale };
  }
  const longSide = Math.max(metric.w, metric.h);
  const shortSide = Math.min(metric.w, metric.h);
  const ratio = shortSide > 0 ? longSide / shortSide : 1;
  // 面积守恒下的理想短边 + 最小短边兜底
  const idealShort = shortBase / Math.sqrt(ratio);
  const minShort = shortBase * MIN_SHORT_RATIO;
  let short = Math.max(minShort, idealShort);
  let long = short * ratio;
  // 非方形主题的 L/R 整体再缩 20%，让按钮视觉上不抢占太多空间
  if (kind === 'lr' && ratio > 1) {
    short *= NON_SQUARE_LR_SCALE;
    long *= NON_SQUARE_LR_SCALE;
  }
  if (metric.w >= metric.h) {
    return { width: long, height: short };
  }
  return { width: short, height: long };
}

// ============================================================================
// 主题动态适配 — 自定义布局中 L/R、SELECT/START 按素材宽高比和设计尺寸重算
//
// 已存 rect 的语义被解释为 "中心点 + 相对该主题设计尺寸的缩放倍数"：
//   scale = rectArea / designedArea(来源主题)
//   新 rect = getOverlayButtonRect(目标主题, 标准基准 × scale)
//
// 效果：主题默认尺寸的 rect 映射为另一主题的设计默认尺寸；用户放大 k 倍
// 的矩形在新主题下仍是其设计尺寸的 k 倍 —— 宽高比与"设计相对大小"双跟随。
// ============================================================================

interface StandardBases {
  lr: number;
  ss: number;
}

/** L/R、SELECT/START 的标准短边基准 — 与默认布局/addComponent 使用的基准一致 */
const STANDARD_BASE: StandardBases = { lr: 50, ss: 40 };

/** 组件名 → 主题矩形类型（仅这 4 个组件的宽高比随素材变化） */
const THEME_RECT_KIND: Record<string, ThemedButtonKind> = {
  'BUTTON_L': 'lr',
  'BUTTON_R': 'lr',
  'BUTTON_ZL': 'lr',
  'BUTTON_ZR': 'lr',
  'BUTTON_SELECT': 'ss',
  'BUTTON_START': 'ss',
};

function standardBase(kind: ThemedButtonKind): number {
  return kind === 'lr' ? STANDARD_BASE.lr : STANDARD_BASE.ss;
}

/** 主题该类型按钮的"设计默认矩形" (含 designScale 权重) */
export function designedButtonRect(theme: string, kind: ThemedButtonKind): ButtonRect {
  const bias = THEME_METRICS[theme]?.designScale ?? 1.0;
  return getOverlayButtonRect(theme, kind, standardBase(kind) * bias);
}

/**
 * 将已存按钮矩形归一化到目标主题：保持中心点，按"相对来源主题设计尺寸的倍数"
 * 换算大小，再按目标主题素材宽高比重算 w/h。
 *
 * - 仅处理 BUTTON_L/R/SELECT/START；其他组件返回 null 表示不变。
 * - srcTheme 未知时传 dstTheme（等价于"面积保持、仅重算宽高比"的安全近似）。
 * - 幂等：srcTheme == dstTheme 时尺寸形状都不变。
 * - 返回新对象，不修改入参。
 */
export function normalizeRectToTheme(
  component: string,
  rect: LayoutRect,
  srcTheme: string,
  dstTheme: string,
): LayoutRect | null {
  const kind = THEME_RECT_KIND[component];
  if (!kind) return null;
  const area = rect.width * rect.height;
  if (area <= 0) return null;
  const src = designedButtonRect(srcTheme, kind);
  const srcArea = src.width * src.height;
  if (srcArea <= 0) return null;
  const scale = Math.sqrt(area / srcArea);
  const target = getOverlayButtonRect(dstTheme, kind, standardBase(kind) * scale);
  const cx = rect.x + rect.width / 2;
  const cy = rect.y + rect.height / 2;
  return {
    x: Math.round(cx - target.width / 2),
    y: Math.round(cy - target.height / 2),
    width: Math.round(target.width),
    height: Math.round(target.height),
  };
}

// ============================================================================
// ABXY 每主题按键几何 — 底衬整图 + 独立按键叠加层的定位描述 (实测值)
//
// buttons.png 整图铺底（保留 snes 圆盘、default 点阵环等装饰），
// buttons_X/Y/A/B.png 作为独立叠加层负责按下缩放/染色反馈。每个按键参数：
//   cx, cy — 按键中心在簇图中的归一化坐标（同时用于命中检测圆心，实测）
//   s      — 叠加层渲染边长 / areaSize（实测足迹，确保完全遮盖底衬按键）
//   ccx, ccy — PNG 有效内容中心在自身画布中的归一化位置（独立 PNG 为紧贴
//              内容的小画布，内容中心相对画布中心可能有少量偏移）
//   hr     — 命中圆半径 / areaSize。snes 菱形排布圆心更近、drastic 盘距更近，
//            0.3 的默认半径会导致对向键 (X+B/Y+A) 命中区相交误触，需缩小。
// ============================================================================

export interface AbxyButtonSpec {
  cx: number;
  cy: number;
  s: number;
  ccx: number;
  ccy: number;
}

export interface ThemeAbxy {
  x: AbxyButtonSpec;
  y: AbxyButtonSpec;
  a: AbxyButtonSpec;
  b: AbxyButtonSpec;
  hr: number;
}

const CENTERED = 0.5;

const THEME_ABXY: Record<string, ThemeAbxy> = {
  // 灰盘 + 白色点阵环装饰；盘心十字布局，盘径 ≈0.36
  'default': {
    x: { cx: 0.500, cy: 0.205, s: 0.38, ccx: CENTERED, ccy: 0.515 },
    y: { cx: 0.199, cy: 0.504, s: 0.38, ccx: CENTERED, ccy: 0.515 },
    a: { cx: 0.801, cy: 0.506, s: 0.38, ccx: CENTERED, ccy: 0.515 },
    b: { cx: 0.500, cy: 0.807, s: 0.38, ccx: CENTERED, ccy: 0.515 },
    hr: 0.30,
  },
  // 黑金盘 + 金边 + 外圈光晕 (实心 r≈0.19，光晕到 r≈0.23)；间距较近
  'drastic': {
    x: { cx: 0.498, cy: 0.225, s: 0.42, ccx: CENTERED, ccy: CENTERED },
    y: { cx: 0.225, cy: 0.500, s: 0.42, ccx: CENTERED, ccy: CENTERED },
    a: { cx: 0.775, cy: 0.500, s: 0.42, ccx: CENTERED, ccy: CENTERED },
    b: { cx: 0.500, cy: 0.775, s: 0.42, ccx: CENTERED, ccy: CENTERED },
    hr: 0.27,
  },
  // 紫垫上的非对称菱形排布 (实测): X 上、A 右上、Y 左下、B 下，盘径 ≈0.33
  'snes': {
    x: { cx: 0.441, cy: 0.229, s: 0.37, ccx: 0.496, ccy: CENTERED },
    y: { cx: 0.244, cy: 0.578, s: 0.37, ccx: 0.496, ccy: CENTERED },
    a: { cx: 0.752, cy: 0.408, s: 0.37, ccx: 0.496, ccy: CENTERED },
    b: { cx: 0.547, cy: 0.758, s: 0.37, ccx: 0.496, ccy: CENTERED },
    hr: 0.23,
  },
  // 空心描线环，环心十字布局，环外径 ≈0.38
  'clear': {
    x: { cx: 0.499, cy: 0.188, s: 0.38, ccx: 0.495, ccy: 0.495 },
    y: { cx: 0.188, cy: 0.497, s: 0.38, ccx: 0.495, ccy: 0.495 },
    a: { cx: 0.812, cy: 0.497, s: 0.38, ccx: 0.495, ccy: 0.495 },
    b: { cx: 0.501, cy: 0.812, s: 0.38, ccx: 0.495, ccy: 0.495 },
    hr: 0.30,
  },
  // 半透明玻璃盘 + 彩色符号，盘心十字布局，盘径 ≈0.37
  'ps': {
    x: { cx: 0.500, cy: 0.191, s: 0.37, ccx: CENTERED, ccy: 0.511 },
    y: { cx: 0.186, cy: 0.499, s: 0.37, ccx: CENTERED, ccy: 0.511 },
    a: { cx: 0.814, cy: 0.499, s: 0.37, ccx: CENTERED, ccy: 0.511 },
    b: { cx: 0.500, cy: 0.814, s: 0.37, ccx: CENTERED, ccy: 0.511 },
    hr: 0.30,
  },
};

const FALLBACK_ABXY: ThemeAbxy = {
  x: { cx: 0.499, cy: 0.185, s: 0.40, ccx: CENTERED, ccy: CENTERED },
  y: { cx: 0.190, cy: 0.499, s: 0.40, ccx: CENTERED, ccy: CENTERED },
  a: { cx: 0.814, cy: 0.499, s: 0.40, ccx: CENTERED, ccy: CENTERED },
  b: { cx: 0.499, cy: 0.810, s: 0.40, ccx: CENTERED, ccy: CENTERED },
  hr: 0.30,
};

/** 获取主题的 ABXY 几何描述；未知主题退回旧版硬编码位置 */
export function getThemeAbxy(theme: string): ThemeAbxy {
  return THEME_ABXY[theme] ?? FALLBACK_ABXY;
}

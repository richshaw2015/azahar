/**
 * Azahar - 触屏按键布局配置管理器
 *
 * 移植自 NDS 项目的布局系统:
 * - 生成默认竖屏/横屏布局
 * - 管理布局配置的 CRUD 和持久化
 * - 提供运行时布局查询
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { I18n } from './I18nManager';
import { LayoutComponent, LayoutConfiguration, LayoutType, LayoutOrientation, PositionedLayoutComponent, LayoutRect, isScreenComponent, UILayoutVariant, UILayout, Orientation, variantToKey, keyToVariant, SerializedLayoutConfig, serializeLayout, deserializeLayout, THEME_COLOR_BG_URI,  } from '../types/LayoutTypes';
import {
  ACTION_BUTTON_BASE_SIZE,
  clampSsRectForPortraitGap,
  CONTROL_EDGE_MARGIN,
  getOverlayControlSizes,
  normalizeRectToTheme
} from './OverlayThemeHelper';
import { computePadLayout, PAD_BLOCK_GAP, PadRect, PadSizes, PadVisibility } from './VirtualPadLayout';

const DOMAIN = 0x0000;
const TAG = 'Azahar_LayoutConfigManager';

/** 3DS 上屏宽高比 400:240 = 5:3 */
const TOP_SCREEN_ASPECT = 400 / 240;

/** 3DS 下屏宽高比 320:240 = 4:3 */
const BOTTOM_SCREEN_ASPECT = 320 / 240;

/** 竖屏模式下上下屏之间的默认间距 (vp) */
const DEFAULT_SCREEN_GAP = 8;
const TABLET_CONTROL_MIN_SIDE = 600;
const TABLET_ACTION_BUTTON_SIZE = 44;

/** 持久化 key */
const PREFS_NAME = 'azahar_layouts_v1';
const KEY_LAYOUTS = 'layout_configs';
const KEY_DEFAULT_ID = 'default_layout_id';

/** 默认布局 ID */
const BUILTIN_DEFAULT_ID = '__builtin_default__';

/** 变体尺寸容差: 宽高差异在 5% 内视为同一变体 */
const VARIANT_SIZE_TOLERANCE = 0.05;

/** 宽高比差异上限: 超过 20% 的变体不缩放复用，改用默认布局 */
const MAX_VARIANT_ASPECT_DELTA = Math.log(1.2);

/** findBestVariantKey 的匹配结果 */
interface VariantMatch {
  key: string;
  withinTolerance: boolean;
}

export class LayoutConfigManager {
  private static instance: LayoutConfigManager | null = null;
  private dataPreferences: preferences.Preferences | null = null;
  private layouts: LayoutConfiguration[] = [];
  private defaultLayoutId: string = BUILTIN_DEFAULT_ID;
  private initialized: boolean = false;

  static getInstance(): LayoutConfigManager {
    if (!LayoutConfigManager.instance) {
      LayoutConfigManager.instance = new LayoutConfigManager();
    }
    return LayoutConfigManager.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    try {
      this.dataPreferences = await preferences.getPreferences(context, PREFS_NAME);
      await this.load();
      this.initialized = true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Init failed: %{public}s', (err as Error).message);
    }
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  /** 获取 Preferences 实例 (供背景管理等外部模块使用) */
  getPreferences(): preferences.Preferences | null {
    return this.dataPreferences;
  }

  // ============================================================================
  // 默认布局生成 (对齐 Android DefaultLayoutProvider)
  // ============================================================================

  /**
   * 生成默认竖屏布局
   * 3DS 双屏布局:
   *   - 上屏（400×240，5:3）和下屏（320×240，4:3）上下排列，宽度撑满
   *   - L/R + 动作按钮行在两屏分界线
   *   - DPad/ABXY 贴底部
   *   - SELECT/START 与 DPad/ABXY 中心 Y 对齐
   *   - L/R/SELECT/START 矩形按主题素材宽高比拉伸
   */
  // 游戏内按键尺寸直接使用主题比例表，无额外缩放。
  private static padSizesFor(actionBase: number): PadSizes {
    const controlSizes = getOverlayControlSizes('default', actionBase);
    return {
      lrW: controlSizes.lrWidth,
      lrH: controlSizes.lrHeight,
      ssW: controlSizes.ssWidth,
      ssH: controlSizes.ssHeight,
      dpad: controlSizes.dpad,
      abxy: controlSizes.abxy,
      stick: controlSizes.stick,
      cStick: controlSizes.cStick,
      small: controlSizes.action,
      turbo: controlSizes.action
    };
  }

  private static actionBaseFor(width: number, height: number): number {
    return Math.min(width, height) >= TABLET_CONTROL_MIN_SIDE
      ? TABLET_ACTION_BUTTON_SIZE : ACTION_BUTTON_BASE_SIZE;
  }

  private static readonly PAD_VISIBLE_DEFAULT: PadVisibility = {
    l: true, r: true, zl: false, zr: false, dpad: true, stick: true,
    cStick: false, abxy: true, select: true, start: true,
    home: false, swap: false, turbo: true, pause: true, more: true
  };

  // 横屏默认布局用游戏内自适应算法生成控件矩形，按两屏并集计算侧边空间。
  private padComponentsFromPadLayout(width: number, height: number,
    topScreen: LayoutRect, bottomScreen: LayoutRect): PositionedLayoutComponent[] {
    const left = Math.min(topScreen.x, bottomScreen.x);
    const right = Math.max(topScreen.x + topScreen.width, bottomScreen.x + bottomScreen.width);
    const top = Math.min(topScreen.y, bottomScreen.y);
    const bottom = Math.max(topScreen.y + topScreen.height, bottomScreen.y + bottomScreen.height);
    const pad = computePadLayout({
      width,
      height,
      gameRect: { x: left, y: top, w: right - left, h: bottom - top },
      sizes: LayoutConfigManager.padSizesFor(LayoutConfigManager.actionBaseFor(width, height)),
      visible: LayoutConfigManager.PAD_VISIBLE_DEFAULT
    });
    const out: PositionedLayoutComponent[] = [];
    const push = (rect: PadRect | null, component: LayoutComponent) => {
      if (rect) {
        out.push({
          rect: { x: Math.round(rect.x), y: Math.round(rect.y),
            width: Math.round(rect.w), height: Math.round(rect.h) },
          component
        });
      }
    };
    push(pad.dpad, LayoutComponent.DPAD);
    push(pad.abxy, LayoutComponent.BUTTONS);
    push(pad.stick, LayoutComponent.STICK);
    push(pad.cStick, LayoutComponent.CSTICK);
    push(pad.l, LayoutComponent.BUTTON_L);
    push(pad.r, LayoutComponent.BUTTON_R);
    push(pad.zl, LayoutComponent.BUTTON_ZL);
    push(pad.zr, LayoutComponent.BUTTON_ZR);
    push(pad.select, LayoutComponent.BUTTON_SELECT);
    push(pad.start, LayoutComponent.BUTTON_START);
    push(pad.home, LayoutComponent.BUTTON_HOME);
    push(pad.swap, LayoutComponent.BUTTON_SWAP_SCREENS);
    push(pad.turbo, LayoutComponent.BUTTON_FAST_FORWARD_TOGGLE);
    push(pad.pause, LayoutComponent.BUTTON_PAUSE);
    push(pad.more, LayoutComponent.BUTTON_MORE);
    return out;
  }

  /** 竖屏默认控件沿用 NDS 锚点；圆形摇杆对齐 Android 默认布局放在 DPad 下方。 */
  private defaultPortraitPadComponents(width: number, height: number,
    topScreen: LayoutRect, overlayTheme: string): PositionedLayoutComponent[] {
    const actionBase = LayoutConfigManager.actionBaseFor(width, height);
    const s = getOverlayControlSizes(overlayTheme, actionBase);
    const spacing = 4;
    const ss = clampSsRectForPortraitGap(
      { width: s.ssWidth, height: s.ssHeight }, width, s.dpad, s.abxy, spacing);
    const lrW = Math.round(s.lrWidth);
    const lrH = Math.round(s.lrHeight);
    const dpad = Math.round(s.dpad);
    const abxy = Math.round(s.abxy);
    const stick = Math.round(s.stick);
    const small = Math.round(s.action);
    const clusterBottom = height - CONTROL_EDGE_MARGIN;
    const stickY = clusterBottom - stick;
    const dpadY = stickY - PAD_BLOCK_GAP - dpad;
    const abxyY = clusterBottom - abxy;
    const clusterTop = Math.min(dpadY, abxyY, stickY);

    let actionRowY = topScreen.y + topScreen.height;
    if (actionRowY + small + 48 > clusterTop) {
      actionRowY = topScreen.y;
    }

    const ssW = Math.round(ss.width);
    const ssH = Math.round(ss.height);
    const startY = clusterBottom - ssH;
    const selectY = startY - CONTROL_EDGE_MARGIN - ssH;
    const middleX = Math.round(width / 2);
    const actionCenterX = width / 2;
    const rect = (component: LayoutComponent, x: number, y: number, w: number, h: number): PositionedLayoutComponent => ({
      rect: { x: Math.round(x), y: Math.round(y), width: Math.round(w), height: Math.round(h) },
      component: component
    });

    return [
      rect(LayoutComponent.DPAD, CONTROL_EDGE_MARGIN, dpadY, dpad, dpad),
      rect(LayoutComponent.STICK, CONTROL_EDGE_MARGIN + (dpad - stick) / 2, stickY, stick, stick),
      rect(LayoutComponent.BUTTONS, width - abxy - CONTROL_EDGE_MARGIN, abxyY, abxy, abxy),
      rect(LayoutComponent.BUTTON_L, 0, actionRowY, lrW, lrH),
      rect(LayoutComponent.BUTTON_R, width - lrW, actionRowY, lrW, lrH),
      rect(LayoutComponent.BUTTON_SELECT, middleX - ssW / 2, selectY, ssW, ssH),
      rect(LayoutComponent.BUTTON_START, middleX - ssW / 2, startY, ssW, ssH),
      rect(LayoutComponent.BUTTON_PAUSE, actionCenterX - small * 1.5 - spacing, actionRowY, small, small),
      rect(LayoutComponent.BUTTON_FAST_FORWARD_TOGGLE, actionCenterX - small / 2, actionRowY, small, small),
      rect(LayoutComponent.BUTTON_MORE, actionCenterX + small / 2 + spacing, actionRowY, small, small),
    ];
  }

  buildDefaultPortraitLayout(width: number, height: number, overlayTheme: string = 'default'): PositionedLayoutComponent[] {
    const gap = DEFAULT_SCREEN_GAP;

    // 计算屏幕尺寸：优先按宽度铺满
    let topScreenW = width;
    let topScreenH = Math.round(width / TOP_SCREEN_ASPECT);
    let bottomScreenW = width;
    let bottomScreenH = Math.round(width / BOTTOM_SCREEN_ASPECT);
    let screenMargin = 0;

    // 如果两屏总高度超过可用空间，按高度等比缩小
    const availableH = height - gap;
    if (topScreenH + bottomScreenH > availableH) {
      const scale = availableH / (topScreenH + bottomScreenH);
      topScreenH = Math.round(topScreenH * scale);
      topScreenW = Math.round(topScreenH * TOP_SCREEN_ASPECT);
      bottomScreenH = Math.round(bottomScreenH * scale);
      bottomScreenW = Math.round(bottomScreenH * BOTTOM_SCREEN_ASPECT);
      screenMargin = Math.round((width - Math.max(topScreenW, bottomScreenW)) / 2);
    }

    const topScreen: LayoutRect = {
      x: Math.round((width - topScreenW) / 2),
      y: 0,
      width: topScreenW,
      height: topScreenH
    };
    const bottomScreen: LayoutRect = {
      x: Math.round((width - bottomScreenW) / 2),
      y: topScreenH + gap,
      width: bottomScreenW,
      height: bottomScreenH
    };

    return [
      { rect: topScreen, component: LayoutComponent.TOP_SCREEN },
      { rect: bottomScreen, component: LayoutComponent.BOTTOM_SCREEN },
      ...this.defaultPortraitPadComponents(width, height, topScreen, overlayTheme),
    ];
  }

  /**
   * 生成默认横屏布局
   * 3DS 双屏布局:
   *   - 上屏左侧较大，下屏右侧较小
   *   - L/R 在顶部两角
   *   - DPad/ABXY 在底部两角
   *   - SELECT/START 与 DPad/ABXY 中心 Y 对齐
   */
  buildDefaultLandscapeLayout(width: number, height: number, overlayTheme: string = 'default'): PositionedLayoutComponent[] {

    // 上屏占 66% 宽度，下屏占 34% 宽度
    let topScreenW = Math.round(width * 0.66);
    let topScreenH = Math.round(topScreenW / TOP_SCREEN_ASPECT);
    if (topScreenH > height) {
      topScreenH = height;
      topScreenW = Math.round(topScreenH * TOP_SCREEN_ASPECT);
    }

    topScreenW = Math.max(0, Math.min(topScreenW, width));
    topScreenH = Math.max(0, Math.min(topScreenH, height));

    const bottomScreenW = Math.max(0, width - topScreenW);
    const bottomScreenH = Math.max(0, Math.round(bottomScreenW / BOTTOM_SCREEN_ASPECT));

    const topScreen: LayoutRect = { x: 0, y: 0, width: topScreenW, height: topScreenH };
    const bottomScreen: LayoutRect = { x: topScreenW, y: 0, width: bottomScreenW, height: bottomScreenH };
    return [
      { rect: topScreen, component: LayoutComponent.TOP_SCREEN },
      { rect: bottomScreen, component: LayoutComponent.BOTTOM_SCREEN },
      ...this.padComponentsFromPadLayout(width, height, topScreen, bottomScreen),
    ];
  }

  /**
   * 游戏运行时解析（参照 nds applyCustomLayout）：
   * 精确匹配原样返回；否则取容差内或按宽高比+尺寸打分最近的同方向变体，
   * 用 scaleComponentsToVariant 适配（屏幕保持比例、按钮尺寸不变）；
   * 无已存变体时生成默认布局。返回矩形即窗口 vp 坐标。
   */
  resolveGameComponents(config: LayoutConfiguration, width: number, height: number,
    overlayTheme: string = 'default'): PositionedLayoutComponent[] {
    const variant = LayoutConfigManager.buildVariant(width, height);
    const best = this.findBestVariantKey(config, variant);
    if (!best) {
      if (variant.orientation === Orientation.LANDSCAPE) {
        return this.buildDefaultLandscapeLayout(width, height, overlayTheme);
      }
      return this.buildDefaultPortraitLayout(width, height, overlayTheme);
    }
    const saved = config.layoutVariants[best.key];
    const src = keyToVariant(best.key)!;
    if (src.width === variant.width && src.height === variant.height) {
      return this.normalizeForTheme(saved.components, saved.theme, variant, overlayTheme);
    }
    // 尺寸不同(含容差内): 先在源变体坐标系下归一化，再智能缩放到目标变体 (按钮会 clamp 到边界)
    const comps = this.normalizeForTheme(saved.components, saved.theme, src, overlayTheme);
    return this.scaleComponentsToVariant(comps, src, variant);
  }

  // ============================================================================
  // 变体布局匹配 (对齐 Android UILayoutProvider.getOptimalLayoutForVariant)
  // ============================================================================

  /**
   * 获取最优布局 (对齐 Android UILayoutProvider.getOptimalLayoutForVariant)
   * 匹配链: 精确匹配 → 同方向回退(等比缩放) → 生成默认布局
   *
   * @param scale 是否对不同尺寸的同方向变体做等比缩放 (默认 true)
   *   - true: 游戏运行时使用，缩放屏幕组件并保持按钮间距
   *   - false: 布局编辑器使用，返回原始组件由编辑器自行 clamp
   */
  getOptimalLayoutForVariant(
    config: LayoutConfiguration,
    variant: UILayoutVariant,
    scale: boolean = false,
    overlayTheme: string = 'default'
  ): PositionedLayoutComponent[] {
    const key = variantToKey(variant);

    // 1. 精确匹配
    const exact = config.layoutVariants[key];
    if (exact) {
      return this.normalizeForTheme(exact.components, exact.theme, variant, overlayTheme);
    }

    // 2. 同方向回退
    const similar = this.findSimilarLayoutVariant(config, variant, scale);
    if (similar) {
      return this.normalizeForTheme(similar.components, similar.theme, variant, overlayTheme);
    }

    // 3. 生成默认布局 (已按当前主题生成，无需归一化)
    if (variant.orientation === Orientation.LANDSCAPE) {
      return this.buildDefaultLandscapeLayout(variant.width, variant.height, overlayTheme);
    } else {
      return this.buildDefaultPortraitLayout(variant.width, variant.height, overlayTheme);
    }
  }

  /**
   * 将已存组件矩形归一化到目标主题 (对齐 OverlayThemeHelper.normalizeRectToTheme):
   * - BUTTON_L/R/SELECT/START 按"相对设计尺寸倍数"换算大小并重算宽高比
   * - 其他组件 (屏幕/DPAD/ABXY/方形功能键) 原样返回
   * - srcTheme 缺省时按目标主题处理 (仅重算宽高比、保持面积)
   * - 返回新数组新对象，不修改持久化数据；归一化后 clamp 到变体边界内
   */
  private normalizeForTheme(
    components: PositionedLayoutComponent[],
    srcTheme: string | undefined,
    variant: UILayoutVariant,
    dstTheme: string
  ): PositionedLayoutComponent[] {
    const src = srcTheme ?? dstTheme;
    return components.map((c: PositionedLayoutComponent): PositionedLayoutComponent => {
      const r = normalizeRectToTheme(c.component, c.rect, src, dstTheme);
      if (!r) return c;
      return {
        rect: {
          x: Math.max(0, Math.min(r.x, variant.width - r.width)),
          y: Math.max(0, Math.min(r.y, variant.height - r.height)),
          width: r.width,
          height: r.height,
        },
        component: c.component,
      };
    });
  }

  /**
   * 为目标变体在已存变体中挑选最佳 key (单趟遍历):
   * 1. 精确 key 匹配直接返回
   * 2. 同方向且尺寸在容差内 → 取 |dw|+|dh| 最小者 (withinTolerance)
   * 3. 无容差内候选时，同方向按宽高比+尺寸打分取最近者:
   *    score = |ln(目标宽高比/候选宽高比)| * 0.7 + (|ln(w比)| + |ln(h比)|) * 0.15
   *    宽高比差异超过 MAX_VARIANT_ASPECT_DELTA 的候选不参与
   * 4. 无可用候选 → null (调用方生成默认布局)
   */
  private findBestVariantKey(config: LayoutConfiguration, variant: UILayoutVariant): VariantMatch | null {
    const exactKey = variantToKey(variant);
    const keys = Object.keys(config.layoutVariants);
    let bestToleranceKey: string | null = null;
    let bestToleranceDelta = Number.MAX_VALUE;
    let bestScoreKey: string | null = null;
    let bestScore = Number.MAX_VALUE;

    for (const k of keys) {
      if (k === exactKey) {
        return { key: k, withinTolerance: true };
      }
      const kv = keyToVariant(k);
      if (!kv || kv.orientation !== variant.orientation) {
        continue;
      }
      if (LayoutConfigManager.isSameVariantSize(kv, variant)) {
        const delta = Math.abs(kv.width - variant.width) + Math.abs(kv.height - variant.height);
        if (delta < bestToleranceDelta) {
          bestToleranceDelta = delta;
          bestToleranceKey = k;
        }
      }
      if (kv.width > 0 && kv.height > 0) {
        const aspectDelta = Math.abs(Math.log((variant.width / variant.height) / (kv.width / kv.height)));
        if (aspectDelta > MAX_VARIANT_ASPECT_DELTA) {
          continue;
        }
        const score = aspectDelta * 0.7 +
          (Math.abs(Math.log(variant.width / kv.width)) + Math.abs(Math.log(variant.height / kv.height))) * 0.15;
        if (score < bestScore) {
          bestScore = score;
          bestScoreKey = k;
        }
      }
    }

    if (bestToleranceKey) {
      return { key: bestToleranceKey, withinTolerance: true };
    }
    if (bestScoreKey) {
      return { key: bestScoreKey, withinTolerance: false };
    }
    return null;
  }

  /**
   * 查找容差内的已存变体 (编辑器用: 继续编辑相近变体而非创建近似重复变体)
   * 仅当存在同方向且尺寸在容差内的变体时返回，否则 null
   */
  /** 是否存在可复用的已存变体 (精确/容差内/宽高比相近)，否则应使用默认布局 */
  hasUsableVariant(config: LayoutConfiguration, variant: UILayoutVariant): boolean {
    return this.findBestVariantKey(config, variant) !== null;
  }

  findToleranceVariant(config: LayoutConfiguration, width: number, height: number): UILayoutVariant | null {
    const variant = LayoutConfigManager.buildVariant(width, height);
    const best = this.findBestVariantKey(config, variant);
    if (!best || !best.withinTolerance) return null;
    return keyToVariant(best.key);
  }

  /**
   * 查找相似变体 (对齐 Android UILayoutProvider.findSimilarLayoutVariant — 简化版)
   * 优先: 精确/容差内匹配 → 同方向按宽高比+尺寸打分最近 → null
   *
   * @param scale 是否对不同尺寸的变体做等比缩放
   */
  private findSimilarLayoutVariant(
    config: LayoutConfiguration,
    variant: UILayoutVariant,
    scale: boolean
  ): UILayout | null {
    const best = this.findBestVariantKey(config, variant);
    if (!best) return null;

    const sourceLayout = config.layoutVariants[best.key];
    const sourceVariant = keyToVariant(best.key);
    if (best.withinTolerance || !scale || !sourceVariant) {
      // 容差内/编辑器模式: 返回原始组件，由调用方归一化/clamp
      return { components: sourceLayout.components, theme: sourceLayout.theme };
    }
    // 游戏运行时: 智能缩放适配当前窗口
    return {
      components: this.scaleComponentsToVariant(sourceLayout.components, sourceVariant, variant),
      theme: sourceLayout.theme,
    };
  }

  /**
   * 将布局组件从源变体尺寸适配到目标变体尺寸
   *
   * 屏幕组件: 位置和尺寸均等比缩放，保持原始宽高比（上屏 5:3，下屏 4:3）
   * 按钮组件: 以中心点做等比缩放，尺寸保持不变 (避免点击区域过小)，
   *           缩放后对相邻按钮保持最小间距 (MIN_BUTTON_GAP)，间距随窗口等比压缩但不低于最小值，
   *           最后 clamp 到窗口边界内
   */
  private scaleComponentsToVariant(
    components: PositionedLayoutComponent[],
    source: UILayoutVariant,
    target: UILayoutVariant
  ): PositionedLayoutComponent[] {
    if (source.width <= 0 || source.height <= 0) return components;
    const scaleX = target.width / source.width;
    const scaleY = target.height / source.height;
    const MIN_BUTTON_GAP = 2;

    const buttonIndices: number[] = [];
    for (let i = 0; i < components.length; i++) {
      if (!isScreenComponent(components[i].component)) {
        buttonIndices.push(i);
      }
    }

    // 第一步: 缩放
    const result = components.map((c: PositionedLayoutComponent): PositionedLayoutComponent => {
      if (isScreenComponent(c.component)) {
        // 屏幕组件: 保持原始宽高比，在缩放后的目标区域内 fit 居中
        const aspect = c.component === LayoutComponent.TOP_SCREEN ? TOP_SCREEN_ASPECT : BOTTOM_SCREEN_ASPECT;
        const targetX = c.rect.x * scaleX;
        const targetY = c.rect.y * scaleY;
        const targetW = c.rect.width * scaleX;
        const targetH = c.rect.height * scaleY;
        let fitW = targetW;
        let fitH = Math.round(fitW / aspect);
        if (fitH > targetH) {
          fitH = targetH;
          fitW = Math.round(fitH * aspect);
        }
        const fitX = targetX + (targetW - fitW) / 2;
        const fitY = targetY + (targetH - fitH) / 2;
        return {
          rect: {
            x: Math.round(fitX),
            y: Math.round(fitY),
            width: Math.round(fitW),
            height: Math.round(fitH),
          },
          component: c.component,
        };
      } else {
        // 按钮: 中心点缩放，尺寸不变
        const cx = (c.rect.x + c.rect.width / 2) * scaleX;
        const cy = (c.rect.y + c.rect.height / 2) * scaleY;
        return {
          rect: {
            x: Math.round(cx - c.rect.width / 2),
            y: Math.round(cy - c.rect.height / 2),
            width: c.rect.width,
            height: c.rect.height,
          },
          component: c.component,
        };
      }
    });

    // 第二步: 对相邻按钮保证最小间距 (MIN_BUTTON_GAP)
    // 只处理源布局中真正相邻的按钮对 (中心距 < 半对角线之和 * 2)
    for (let round = 0; round < 10; round++) {
      let anyAdjust = false;
      for (let ai = 0; ai < buttonIndices.length; ai++) {
        for (let bi = ai + 1; bi < buttonIndices.length; bi++) {
          // 先用源布局判断是否相邻
          const sa = components[buttonIndices[ai]].rect;
          const sb = components[buttonIndices[bi]].rect;
          const cxA = sa.x + sa.width / 2;
          const cyA = sa.y + sa.height / 2;
          const cxB = sb.x + sb.width / 2;
          const cyB = sb.y + sb.height / 2;
          const dist = Math.sqrt((cxA - cxB) * (cxA - cxB) + (cyA - cyB) * (cyA - cyB));
          const diagA = Math.sqrt(sa.width * sa.width + sa.height * sa.height) / 2;
          const diagB = Math.sqrt(sb.width * sb.width + sb.height * sb.height) / 2;
          if (dist >= (diagA + diagB) * 2) continue;

          const a = result[buttonIndices[ai]].rect;
          const b = result[buttonIndices[bi]].rect;

          // 计算两轴上的间距 (负值 = 重叠)
          const gapX = Math.max(a.x, b.x) - Math.min(a.x + a.width, b.x + b.width);
          const gapY = Math.max(a.y, b.y) - Math.min(a.y + a.height, b.y + b.height);

          // 任一轴间距 >= MIN_BUTTON_GAP 说明没有紧贴/重叠，无需调整
          if (gapX >= MIN_BUTTON_GAP || gapY >= MIN_BUTTON_GAP) continue;

          anyAdjust = true;
          // 需要推开的量: 让间距达到 MIN_BUTTON_GAP
          const needX = MIN_BUTTON_GAP - gapX;
          const needY = MIN_BUTTON_GAP - gapY;
          // 沿需要推开量较小的轴调整，避免不必要的大位移
          if (needX <= needY) {
            const half = Math.ceil(needX / 2);
            if (a.x <= b.x) { a.x -= half; b.x += half; }
            else { b.x -= half; a.x += half; }
          } else {
            const half = Math.ceil(needY / 2);
            if (a.y <= b.y) { a.y -= half; b.y += half; }
            else { b.y -= half; a.y += half; }
          }
        }
      }
      if (!anyAdjust) break;
    }

    // 第三步: clamp 所有按钮到窗口边界
    for (const idx of buttonIndices) {
      const r = result[idx].rect;
      r.x = Math.max(0, Math.min(r.x, target.width - r.width));
      r.y = Math.max(0, Math.min(r.y, target.height - r.height));
    }

    return result;
  }

  /**
   * 判断两个变体是否同方向且尺寸在容差内 (相对 b 的宽高)
   */
  static isSameVariantSize(a: UILayoutVariant, b: UILayoutVariant): boolean {
    return a.orientation === b.orientation &&
      Math.abs(a.width - b.width) <= b.width * VARIANT_SIZE_TOLERANCE &&
      Math.abs(a.height - b.height) <= b.height * VARIANT_SIZE_TOLERANCE;
  }

  /**
   * 构建当前屏幕的 UILayoutVariant
   */
  static buildVariant(width: number, height: number): UILayoutVariant {
    return {
      width: width,
      height: height,
      orientation: width > height ? Orientation.LANDSCAPE : Orientation.PORTRAIT,
    };
  }

  /**
   * 检查布局配置是否有指定方向的已保存变体
   * 用于 GameView 判断是否应使用内置布局而非生成默认布局
   */
  hasVariantForOrientation(config: LayoutConfiguration, orientation: Orientation): boolean {
    const keys = Object.keys(config.layoutVariants);
    for (const k of keys) {
      const v = keyToVariant(k);
      if (v && v.orientation === orientation) return true;
    }
    return false;
  }

  // ============================================================================
  // CRUD 操作
  // ============================================================================

  getLayouts(): LayoutConfiguration[] {
    return this.layouts;
  }

  getDefaultLayoutId(): string {
    return this.defaultLayoutId;
  }

  getLayoutById(id: string): LayoutConfiguration | undefined {
    if (id === BUILTIN_DEFAULT_ID) {
      return this.createBuiltinDefault(0, 0);
    }
    return this.layouts.find((l: LayoutConfiguration) => l.id === id);
  }

  /** 获取当前全局默认布局，如果没有则返回内置默认 */
  getDefaultLayout(viewportW: number, viewportH: number): LayoutConfiguration {
    if (this.defaultLayoutId === BUILTIN_DEFAULT_ID) {
      return this.createBuiltinDefault(viewportW, viewportH);
    }
    const found = this.layouts.find((l: LayoutConfiguration) => l.id === this.defaultLayoutId);
    if (found) {
      return found;
    }
    return this.createBuiltinDefault(viewportW, viewportH);
  }

  private createBuiltinDefault(w: number, h: number): LayoutConfiguration {
    const now = Date.now();
    return {
      id: BUILTIN_DEFAULT_ID,
      name: I18n.t('default_layout'),
      type: LayoutType.DEFAULT,
      orientation: LayoutOrientation.FOLLOW_SYSTEM,
      useCustomOpacity: false,
      opacity: 50,
      secondaryScreenOpacity: 100,
      layoutVariants: {},
      backgroundUri: THEME_COLOR_BG_URI,
      createdAt: now,
      updatedAt: now,
    };
  }

  private generateId(): string {
    return `layout_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
  }

  async createLayout(name: string, viewportW: number, viewportH: number): Promise<LayoutConfiguration> {
    const now = Date.now();
    const config: LayoutConfiguration = {
      id: this.generateId(),
      name: name,
      type: LayoutType.CUSTOM,
      orientation: LayoutOrientation.FOLLOW_SYSTEM,
      useCustomOpacity: false,
      opacity: 50,
      secondaryScreenOpacity: 100,
      layoutVariants: {},
      createdAt: now,
      updatedAt: now,
    };

    this.layouts.push(config);
    if (this.layouts.length === 1) {
      this.defaultLayoutId = config.id;
    }
    await this.save();
    return config;
  }

  async updateLayout(config: LayoutConfiguration): Promise<void> {
    const idx = this.layouts.findIndex((l: LayoutConfiguration) => l.id === config.id);
    if (idx >= 0) {
      config.updatedAt = Date.now();
      this.layouts[idx] = config;
      await this.save();
    }
  }

  async deleteLayout(id: string): Promise<void> {
    this.layouts = this.layouts.filter((l: LayoutConfiguration) => l.id !== id);
    if (this.defaultLayoutId === id) {
      this.defaultLayoutId = this.layouts.length > 0 ? this.layouts[0].id : BUILTIN_DEFAULT_ID;
    }
    await this.save();
  }

  async setDefaultLayoutId(id: string): Promise<void> {
    this.defaultLayoutId = id;
    await this.save();
  }

  async renameLayout(id: string, newName: string): Promise<void> {
    const layout = this.layouts.find((l: LayoutConfiguration) => l.id === id);
    if (layout) {
      layout.name = newName;
      layout.updatedAt = Date.now();
      await this.save();
    }
  }

  // ============================================================================
  // 持久化
  // ============================================================================

  private async load(): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      const json = await this.dataPreferences.get(KEY_LAYOUTS, '[]') as string;
      const parsed = JSON.parse(json) as SerializedLayoutConfig[];
      this.layouts = parsed.map(deserializeLayout);
      this.defaultLayoutId = await this.dataPreferences.get(KEY_DEFAULT_ID, BUILTIN_DEFAULT_ID) as string;
      hilog.debug(DOMAIN, TAG, 'Loaded %{public}d layouts', this.layouts.length);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Load failed: %{public}s', (err as Error).message);
      this.layouts = [];
    }
  }

  private async save(): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      const serialized = this.layouts.map(serializeLayout);
      await this.dataPreferences.put(KEY_LAYOUTS, JSON.stringify(serialized));
      await this.dataPreferences.put(KEY_DEFAULT_ID, this.defaultLayoutId);
      await this.dataPreferences.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Save failed: %{public}s', (err as Error).message);
    }
  }
}

import { LOWER_BUTTON_CENTER_RATIO } from './OverlayThemeHelper';

// 游戏内虚拟按键默认布局：按传入的画面避让区域自适应；竖屏默认布局可允许覆盖下屏。
// 纯数学模块，不依赖 ArkUI 组件，便于单测。

export const PAD_EDGE_MARGIN: number = 8;
export const PAD_ROW_GAP: number = 4;
export const PAD_BLOCK_GAP: number = 8;
export const PAD_MIN_FIT: number = 0.6;
// 摇杆相对边缘的额外内缩（对齐 Android 原版默认布局：摇杆不贴角）
export const STICK_EDGE_INSET: number = 24;

export interface PadRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface PadSizes {
  lrW: number;
  lrH: number;
  ssW: number;
  ssH: number;
  dpad: number;
  abxy: number;
  stick: number;
  cStick: number;
  small: number;
  turbo: number;
}

export interface PadVisibility {
  l: boolean;
  r: boolean;
  zl: boolean;
  zr: boolean;
  dpad: boolean;
  stick: boolean;
  cStick: boolean;
  abxy: boolean;
  select: boolean;
  start: boolean;
  home: boolean;
  swap: boolean;
  turbo: boolean;
  pause: boolean;
  more: boolean;
}

export interface PadLayoutInput {
  width: number;
  height: number;
  /** 需要避让的画面区域（vp）；竖屏默认布局可只传上屏以允许按键覆盖下屏；null = 无画面信息 */
  gameRect: PadRect | null;
  /** 未缩放（fit=1）的各键尺寸，由按键层按现有常量算好传入 */
  sizes: PadSizes;
  visible: PadVisibility;
}

/** 默认按键层的固定显隐（旧 Android buttonToggle 默认值的等价物）：
 *  ZL/ZR/C 摇杆/Home/换屏默认隐藏；按键显隐由布局编辑器的组件有无决定，不再有独立开关 */
export const DEFAULT_PAD_VISIBILITY: PadVisibility = {
  l: true,
  r: true,
  zl: false,
  zr: false,
  dpad: true,
  stick: true,
  cStick: false,
  abxy: true,
  select: true,
  start: true,
  home: false,
  swap: false,
  turbo: true,
  pause: true,
  more: true
};

export interface PadLayout {
  /** 实际使用的统一缩放（所有 sizes 同乘） */
  fit: number;
  /** true = 空间不足，允许压画面的兜底模式 */
  overlay: boolean;
  l: PadRect | null;
  r: PadRect | null;
  zl: PadRect | null;
  zr: PadRect | null;
  dpad: PadRect | null;
  stick: PadRect | null;
  cStick: PadRect | null;
  abxy: PadRect | null;
  select: PadRect | null;
  start: PadRect | null;
  home: PadRect | null;
  swap: PadRect | null;
  turbo: PadRect | null;
  pause: PadRect | null;
  more: PadRect | null;
}

interface PadCtx {
  input: PadLayoutInput;
  out: PadLayout;
  fit: number;
  v: PadVisibility;
  // 已缩放尺寸
  lrW: number;
  lrH: number;
  ssW: number;
  ssH: number;
  dpad: number;
  abxy: number;
  stick: number;
  cStick: number;
  small: number;
  turbo: number;
}

function clampRect(rect: PadRect, width: number, height: number): PadRect {
  const maxX = Math.max(0, width - rect.w);
  const maxY = Math.max(0, height - rect.h);
  return {
    x: Math.max(0, Math.min(maxX, rect.x)),
    y: Math.max(0, Math.min(maxY, rect.y)),
    w: rect.w,
    h: rect.h
  };
}

export function computePadLayout(input: PadLayoutInput): PadLayout {
  const out: PadLayout = {
    fit: 1,
    overlay: false,
    l: null, r: null, zl: null, zr: null,
    dpad: null, stick: null, cStick: null, abxy: null,
    select: null, start: null, home: null, swap: null, turbo: null,
    pause: null, more: null
  };
  const ctx: PadCtx = { input: input, out: out, fit: 1, v: input.visible,
    lrW: 0, lrH: 0, ssW: 0, ssH: 0, dpad: 0, abxy: 0, stick: 0, cStick: 0, small: 0, turbo: 0 };

  if (input.height > input.width) {
    layoutPortrait(ctx);
  } else {
    layoutLandscape(ctx);
  }

  const W = input.width;
  const H = input.height;
  if (out.l) out.l = clampRect(out.l, W, H);
  if (out.r) out.r = clampRect(out.r, W, H);
  if (out.zl) out.zl = clampRect(out.zl, W, H);
  if (out.zr) out.zr = clampRect(out.zr, W, H);
  if (out.dpad) out.dpad = clampRect(out.dpad, W, H);
  if (out.stick) out.stick = clampRect(out.stick, W, H);
  if (out.cStick) out.cStick = clampRect(out.cStick, W, H);
  if (out.abxy) out.abxy = clampRect(out.abxy, W, H);
  if (out.select) out.select = clampRect(out.select, W, H);
  if (out.start) out.start = clampRect(out.start, W, H);
  if (out.home) out.home = clampRect(out.home, W, H);
  if (out.swap) out.swap = clampRect(out.swap, W, H);
  if (out.turbo) out.turbo = clampRect(out.turbo, W, H);
  if (out.pause) out.pause = clampRect(out.pause, W, H);
  if (out.more) out.more = clampRect(out.more, W, H);
  return out;
}

function scaleSizes(ctx: PadCtx, fit: number): void {
  const s = ctx.input.sizes;
  ctx.fit = fit;
  ctx.lrW = s.lrW * fit;
  ctx.lrH = s.lrH * fit;
  ctx.ssW = s.ssW * fit;
  ctx.ssH = s.ssH * fit;
  ctx.dpad = s.dpad * fit;
  ctx.abxy = s.abxy * fit;
  ctx.stick = s.stick * fit;
  ctx.cStick = s.cStick * fit;
  ctx.small = s.small * fit;
  ctx.turbo = s.turbo * fit;
}

// ============================================================================
// 竖屏：控件区在画面下方，dpad/ABXY 贴底，肩键行贴控件区顶
// ============================================================================

function layoutPortrait(ctx: PadCtx): void {
  const W = ctx.input.width;
  const H = ctx.input.height;
  const v = ctx.v;
  const s = ctx.input.sizes;
  const g = ctx.input.gameRect;
  const out = ctx.out;

  let top = g ? g.y + g.h + PAD_ROW_GAP : H * 0.5;
  const bottom = H - PAD_EDGE_MARGIN;
  const left = PAD_EDGE_MARGIN;
  const right = W - PAD_EDGE_MARGIN;

  // 未缩放需求量
  const rows0 = (v.l || v.r ? 1 : 0) + (v.zl || v.zr ? 1 : 0);
  const shoulderH0 = rows0 > 0 ? rows0 * s.lrH + (rows0 - 1) * PAD_ROW_GAP : 0;
  const leftColH0 = (v.dpad ? s.dpad : 0) + (v.stick ? PAD_BLOCK_GAP + s.stick : 0);
  const rightColH0 = (v.abxy ? s.abxy : 0) + (v.cStick ? PAD_BLOCK_GAP + s.cStick : 0);
  const needH0 = (shoulderH0 > 0 ? shoulderH0 + PAD_BLOCK_GAP : 0) + Math.max(leftColH0, rightColH0);
  const needW0 = Math.max(v.dpad ? s.dpad : 0, v.stick ? s.stick : 0) + PAD_BLOCK_GAP +
    Math.max(v.abxy ? s.abxy : 0, v.cStick ? s.cStick : 0);

  let fit = Math.min(1,
    needH0 > 0 ? (bottom - top) / needH0 : 1,
    needW0 > 0 ? (right - left) / needW0 : 1);
  if (fit < PAD_MIN_FIT) {
    fit = PAD_MIN_FIT;
    out.overlay = true;
    // 空间不足：贴底向上排，允许压画面
    top = Math.max(PAD_EDGE_MARGIN, bottom - needH0 * fit);
  }
  out.fit = fit;
  scaleSizes(ctx, fit);

  // 底行：摇杆左、ABXY 右，同一底线；摇杆额外内缩不贴角
  if (v.stick) {
    out.stick = { x: left + STICK_EDGE_INSET, y: bottom - ctx.stick - STICK_EDGE_INSET, w: ctx.stick, h: ctx.stick };
  }
  if (v.abxy) {
    out.abxy = { x: right - ctx.abxy, y: bottom - ctx.abxy, w: ctx.abxy, h: ctx.abxy };
  }

  // 十字键：摇杆正上方，水平对齐摇杆中心
  if (v.dpad) {
    const cx = out.stick ? out.stick.x + out.stick.w / 2 : left + ctx.stick / 2;
    const dpadBottom = out.stick ? out.stick.y - PAD_BLOCK_GAP : bottom;
    out.dpad = { x: cx - ctx.dpad / 2, y: dpadBottom - ctx.dpad, w: ctx.dpad, h: ctx.dpad };
  }
  if (v.cStick) {
    const cx = out.abxy ? out.abxy.x + out.abxy.w / 2 : right - ctx.abxy / 2;
    const stickBottom = out.abxy ? out.abxy.y - PAD_BLOCK_GAP : bottom;
    out.cStick = { x: cx - ctx.cStick / 2, y: stickBottom - ctx.cStick, w: ctx.cStick, h: ctx.cStick };
  }

  // 肩键行：L/R 一行贴 top，ZL/ZR 一行紧随其下；L/R 不可见时 ZL/ZR 占第一行
  if (v.l) {
    out.l = { x: left, y: top, w: ctx.lrW, h: ctx.lrH };
  }
  if (v.r) {
    out.r = { x: right - ctx.lrW, y: top, w: ctx.lrW, h: ctx.lrH };
  }
  const zlRowY = (v.l || v.r) ? top + ctx.lrH + PAD_ROW_GAP : top;
  if (v.zl) {
    out.zl = { x: left, y: zlRowY, w: ctx.lrW, h: ctx.lrH };
  }
  if (v.zr) {
    out.zr = { x: right - ctx.lrW, y: zlRowY, w: ctx.lrW, h: ctx.lrH };
  }

  // 动作键三键组（nds 默认：L | PAUSE FF MORE | R），统一 small 尺寸居中于肩键行
  if (v.pause || v.turbo || v.more) {
    const item = ctx.small;
    const innerL = out.l ? out.l.x + out.l.w : left;
    const innerR = out.r ? out.r.x : right;
    const cx = (innerL + innerR) / 2;
    const y = top + (ctx.lrH - item) / 2;
    const trioW = 3 * item + 2 * PAD_ROW_GAP;
    const x0 = cx - trioW / 2;
    if (v.pause) {
      out.pause = { x: x0, y: y, w: item, h: item };
    }
    if (v.turbo) {
      out.turbo = { x: x0 + item + PAD_ROW_GAP, y: y, w: item, h: item };
    }
    if (v.more) {
      out.more = { x: x0 + 2 * (item + PAD_ROW_GAP), y: y, w: item, h: item };
    }
  }

  // Select/Start
  let ssInMiddle = false;
  if (v.select || v.start) {
    ssInMiddle = placeSelectStartPortrait(ctx, top, left, right);
  }

  // 换屏/Home：dpad 与 abxy 列之间的中间列（固定槽位）
  if (v.swap || v.home) {
    placeActionColumnPortrait(ctx, left, right, ssInMiddle);
  }
}

// Select/Start：优先在底部 D-pad 与 ABXY 之间纵向排列；空间不足时退回肩键行。
// 返回 true 表示使用底部中间列。
function placeSelectStartPortrait(ctx: PadCtx, lrRowY: number,
  left: number, right: number): boolean {
  const v = ctx.v;
  const out = ctx.out;
  let ssW = ctx.ssW;
  let ssH = ctx.ssH;
  const pairNeed = 2 * ssW + PAD_BLOCK_GAP + 2 * PAD_BLOCK_GAP;

  // 底部控制区中间的纵向按钮列
  const leftPad = out.stick ?? out.dpad;
  const gapL = leftPad ? leftPad.x + leftPad.w : left;
  const gapR = out.abxy ? out.abxy.x : right;
  const gapW = gapR - gapL;
  if (leftPad && out.abxy && gapW > 0) {
    if (ssW > gapW) {
      const scale = gapW / ssW;
      ssW *= scale;
      ssH *= scale;
    }
    const centerX = gapL + gapW / 2;
    const centerY = leftPad.y + leftPad.w * LOWER_BUTTON_CENTER_RATIO;
    const stackH = (v.select && v.start ? 2 * ssH + PAD_BLOCK_GAP : ssH);
    const stackY = centerY - stackH / 2;
    if (v.select) {
      out.select = { x: centerX - ssW / 2, y: stackY, w: ssW, h: ssH };
    }
    if (v.start) {
      out.start = { x: centerX - ssW / 2,
        y: stackY + (v.select ? ssH + PAD_BLOCK_GAP : 0), w: ssW, h: ssH };
    }
    return true;
  }

  // B：肩键行内 L 右缘与 R 左缘之间
  const innerL = out.l ? out.l.x + out.l.w : left;
  const innerR = out.r ? out.r.x : right;
  const innerW = innerR - innerL;
  const centerX = (innerL + innerR) / 2;
  // 动作键已占用肩键行时 ss 下移一行避让
  const y = lrRowY + (ctx.lrH - ssH) / 2 + ((v.pause || v.turbo || v.more) ? ctx.lrH + PAD_ROW_GAP : 0);
  // C：放不下则把 ssW/ssH 等比缩到恰好放下
  if (innerW < pairNeed) {
    const scale = Math.max(0.1, (innerW - 2 * PAD_BLOCK_GAP) / (2 * ssW + PAD_BLOCK_GAP));
    ssW *= scale;
    ssH *= scale;
  }
  if (v.select) {
    out.select = { x: centerX - ssW - PAD_BLOCK_GAP / 2, y: y, w: ssW, h: ssH };
  }
  if (v.start) {
    out.start = { x: centerX + PAD_BLOCK_GAP / 2, y: y, w: ssW, h: ssH };
  }
  return false;
}

function placeActionColumnPortrait(ctx: PadCtx, left: number, right: number, ssInMiddle: boolean): void {
  const v = ctx.v;
  const out = ctx.out;
  const colL = out.dpad ? out.dpad.x + out.dpad.w : left;
  const colR = out.abxy ? out.abxy.x : right;
  const colCenter = (colL + colR) / 2;
  // 中间列宽不足时把这三个键等比缩小到列宽 − 2×ROW_GAP
  const maxItemW = Math.max(1, colR - colL - 2 * PAD_ROW_GAP);
  const swapS = Math.min(ctx.small, maxItemW);
  const turboS = Math.min(ctx.turbo, maxItemW);
  const homeS = Math.min(ctx.small, maxItemW);
  const sizeOf = (key: string): number =>
    key === 'swap' ? swapS : homeS;

  // 固定槽位（上→下）：换屏、Home
  if (ssInMiddle && out.select) {
    // A 方案已占用中间列 → 动作列放在 Select/Start 上方，底 = select.y − ROW_GAP，向上排
    let cursor = out.select.y - PAD_ROW_GAP;
    const orderUp: string[] = ['home', 'swap'];
    for (const key of orderUp) {
      const sz = sizeOf(key);
      if (actionVisible(v, key)) {
        setActionRect(out, key, { x: colCenter - sz / 2, y: cursor - sz, w: sz, h: sz });
      }
      cursor -= sz + PAD_ROW_GAP;
    }
    return;
  }

  // 常规：自 max(abxy.y, 左列贴底键.y) 起向下依次排
  let cursor = Math.max(out.abxy ? out.abxy.y : 0, out.stick ? out.stick.y : 0, out.dpad ? out.dpad.y : 0);
  const order: string[] = ['swap', 'home'];
  for (const key of order) {
    const sz = sizeOf(key);
    if (actionVisible(v, key)) {
      setActionRect(out, key, { x: colCenter - sz / 2, y: cursor, w: sz, h: sz });
    }
    cursor += sz + PAD_ROW_GAP;
  }
}

function actionVisible(v: PadVisibility, key: string): boolean {
  if (key === 'swap') return v.swap;
  if (key === 'turbo') return v.turbo;
  if (key === 'pause') return v.pause;
  if (key === 'more') return v.more;
  return v.home;
}

function setActionRect(out: PadLayout, key: string, rect: PadRect): void {
  if (key === 'swap') {
    out.swap = rect;
  } else if (key === 'turbo') {
    out.turbo = rect;
  } else if (key === 'pause') {
    out.pause = rect;
  } else if (key === 'more') {
    out.more = rect;
  } else {
    out.home = rect;
  }
}

// ============================================================================
// 横屏：优先放进画面两侧，放不下回退 overlay 模式
// ============================================================================

function layoutLandscape(ctx: PadCtx): void {
  const W = ctx.input.width;
  const H = ctx.input.height;
  const v = ctx.v;
  const s = ctx.input.sizes;
  const g = ctx.input.gameRect;
  const out = ctx.out;

  const gameL = g ? g.x : 0;
  const gameR = g ? g.x + g.w : W;
  const leftSide = gameL - 2 * PAD_EDGE_MARGIN;
  const rightSide = W - gameR - 2 * PAD_EDGE_MARGIN;

  // 侧边列需求（未缩放）
  const leftShoulderRows = (v.l ? 1 : 0) + (v.zl ? 1 : 0);
  const rightShoulderRows = (v.r ? 1 : 0) + (v.zr ? 1 : 0);
  const leftColW0 = Math.max(
    leftShoulderRows > 0 ? s.lrW : 0,
    v.stick ? s.stick : 0,
    v.dpad ? s.dpad : 0);
  const leftColH0 = (leftShoulderRows > 0 ? leftShoulderRows * s.lrH + (leftShoulderRows - 1) * PAD_ROW_GAP : 0) +
    (v.stick ? PAD_BLOCK_GAP + s.stick : 0) +
    (v.dpad ? PAD_BLOCK_GAP + s.dpad : 0);
  const rightColW0 = Math.max(
    rightShoulderRows > 0 ? s.lrW : 0,
    v.cStick ? s.cStick : 0,
    v.abxy ? s.abxy : 0);
  const rightColH0 = (rightShoulderRows > 0 ? rightShoulderRows * s.lrH + (rightShoulderRows - 1) * PAD_ROW_GAP : 0) +
    (v.cStick ? PAD_BLOCK_GAP + s.cStick : 0) +
    (v.abxy ? PAD_BLOCK_GAP + s.abxy : 0);

  const fitSide = Math.min(1,
    leftColW0 > 0 ? leftSide / leftColW0 : 1,
    rightColW0 > 0 ? rightSide / rightColW0 : 1,
    (H - 2 * PAD_EDGE_MARGIN) / Math.max(1, Math.max(leftColH0, rightColH0)));

  if (fitSide >= PAD_MIN_FIT && (leftColW0 > 0 || rightColW0 > 0)) {
    out.fit = fitSide;
    scaleSizes(ctx, fitSide);
    layoutLandscapeSide(ctx, gameL, gameR);
    return;
  }

  // overlay 兜底：画面铺满，按键压在画面上
  out.overlay = true;
  const shoulderH0 = Math.max(leftShoulderRows, rightShoulderRows) > 0
    ? Math.max(leftShoulderRows, rightShoulderRows) * s.lrH +
      (Math.max(leftShoulderRows, rightShoulderRows) - 1) * PAD_ROW_GAP
    : 0;
  const colH0 = shoulderH0 + (shoulderH0 > 0 ? PAD_BLOCK_GAP : 0) +
    Math.max(
      (v.stick ? s.stick + PAD_BLOCK_GAP : 0) + (v.dpad ? s.dpad : 0),
      (v.cStick ? s.cStick + PAD_BLOCK_GAP : 0) + (v.abxy ? s.abxy : 0));
  const fitOverlay = Math.max(PAD_MIN_FIT,
    Math.min(1, (H - 2 * PAD_EDGE_MARGIN) / Math.max(1, colH0)));
  out.fit = fitOverlay;
  scaleSizes(ctx, fitOverlay);
  layoutLandscapeOverlay(ctx);
}

// 侧边模式：左右两列塞进画面两侧
function layoutLandscapeSide(ctx: PadCtx, gameL: number, gameR: number): void {
  const H = ctx.input.height;
  const v = ctx.v;
  const out = ctx.out;
  const top = PAD_EDGE_MARGIN;
  const bottom = H - PAD_EDGE_MARGIN;

  // 左列：L/ZL 左上（各一行），摇杆左下贴底，十字键在摇杆正上方居中
  let rowY = top;
  if (v.l) {
    out.l = { x: PAD_EDGE_MARGIN, y: rowY, w: ctx.lrW, h: ctx.lrH };
    rowY += ctx.lrH + PAD_ROW_GAP;
  }
  if (v.zl) {
    out.zl = { x: PAD_EDGE_MARGIN, y: rowY, w: ctx.lrW, h: ctx.lrH };
  }
  if (v.stick) {
    out.stick = { x: PAD_EDGE_MARGIN + STICK_EDGE_INSET, y: bottom - ctx.stick - STICK_EDGE_INSET, w: ctx.stick, h: ctx.stick };
  }
  if (v.dpad) {
    const cx = out.stick ? out.stick.x + out.stick.w / 2 : PAD_EDGE_MARGIN + ctx.stick / 2;
    const dpadBottom = out.stick ? out.stick.y - PAD_BLOCK_GAP : bottom;
    out.dpad = { x: cx - ctx.dpad / 2, y: dpadBottom - ctx.dpad, w: ctx.dpad, h: ctx.dpad };
  }

  // 右列镜像：R/ZR 右上，abxy 右下，cStick 在 abxy 上方
  rowY = top;
  if (v.r) {
    out.r = { x: ctx.input.width - PAD_EDGE_MARGIN - ctx.lrW, y: rowY, w: ctx.lrW, h: ctx.lrH };
    rowY += ctx.lrH + PAD_ROW_GAP;
  }
  if (v.zr) {
    out.zr = { x: ctx.input.width - PAD_EDGE_MARGIN - ctx.lrW, y: rowY, w: ctx.lrW, h: ctx.lrH };
  }
  if (v.abxy) {
    out.abxy = { x: ctx.input.width - PAD_EDGE_MARGIN - ctx.abxy, y: bottom - ctx.abxy,
      w: ctx.abxy, h: ctx.abxy };
  }
  if (v.cStick) {
    const cx = out.abxy ? out.abxy.x + out.abxy.w / 2 : ctx.input.width - PAD_EDGE_MARGIN - ctx.abxy / 2;
    const stickBottom = out.abxy ? out.abxy.y - PAD_BLOCK_GAP : bottom;
    out.cStick = { x: cx - ctx.cStick / 2, y: stickBottom - ctx.cStick, w: ctx.cStick, h: ctx.cStick };
  }

  // Select 放 dpad 右侧、Start 放 abxy 左侧，y 对齐各自簇的 LOWER_BUTTON_CENTER_RATIO 行；
  // 越过画面边界则回退为底部居中一对
  const ssY = (anchor: PadRect | null): number =>
    anchor ? anchor.y + anchor.w * LOWER_BUTTON_CENTER_RATIO - ctx.ssH / 2
      : bottom - ctx.ssH;
  let sideOk = true;
  let selectRect: PadRect | null = null;
  let startRect: PadRect | null = null;
  if (v.select) {
    const x = out.dpad ? out.dpad.x + out.dpad.w + PAD_BLOCK_GAP : PAD_EDGE_MARGIN;
    selectRect = { x: x, y: ssY(out.dpad), w: ctx.ssW, h: ctx.ssH };
    if (selectRect.x + selectRect.w > gameL) {
      sideOk = false;
    }
  }
  if (v.start) {
    const x = out.abxy ? out.abxy.x - PAD_BLOCK_GAP - ctx.ssW
      : ctx.input.width - PAD_EDGE_MARGIN - ctx.ssW;
    startRect = { x: x, y: ssY(out.abxy), w: ctx.ssW, h: ctx.ssH };
    if (startRect.x < gameR) {
      sideOk = false;
    }
  }
  if (!sideOk) {
    // 底部居中一对（overlay 位置：横屏画面铺满高度，居中必然压在画面上）
    out.overlay = true;
    const pairW = (v.select ? ctx.ssW : 0) + (v.start ? ctx.ssW : 0) +
      (v.select && v.start ? PAD_BLOCK_GAP : 0);
    const cx = ctx.input.width / 2;
    if (v.select) {
      out.select = { x: cx - pairW / 2, y: ctx.input.height - PAD_EDGE_MARGIN - ctx.ssH,
        w: ctx.ssW, h: ctx.ssH };
    }
    if (v.start) {
      out.start = { x: cx + pairW / 2 - ctx.ssW, y: ctx.input.height - PAD_EDGE_MARGIN - ctx.ssH,
        w: ctx.ssW, h: ctx.ssH };
    }
  } else {
    out.select = selectRect;
    out.start = startRect;
  }

  // 换屏/快进/Home：顶部居中一行
  placeActionRowTop(ctx);
}

// overlay 模式：按键压在画面上，角部布局
function layoutLandscapeOverlay(ctx: PadCtx): void {
  const W = ctx.input.width;
  const H = ctx.input.height;
  const v = ctx.v;
  const out = ctx.out;
  const top = PAD_EDGE_MARGIN;
  const bottom = H - PAD_EDGE_MARGIN;

  let rowY = top;
  if (v.l) {
    out.l = { x: PAD_EDGE_MARGIN, y: rowY, w: ctx.lrW, h: ctx.lrH };
    rowY += ctx.lrH + PAD_ROW_GAP;
  }
  if (v.zl) {
    out.zl = { x: PAD_EDGE_MARGIN, y: rowY, w: ctx.lrW, h: ctx.lrH };
  }
  rowY = top;
  if (v.r) {
    out.r = { x: W - PAD_EDGE_MARGIN - ctx.lrW, y: rowY, w: ctx.lrW, h: ctx.lrH };
    rowY += ctx.lrH + PAD_ROW_GAP;
  }
  if (v.zr) {
    out.zr = { x: W - PAD_EDGE_MARGIN - ctx.lrW, y: rowY, w: ctx.lrW, h: ctx.lrH };
  }

  if (v.stick) {
    out.stick = { x: PAD_EDGE_MARGIN + STICK_EDGE_INSET, y: bottom - ctx.stick - STICK_EDGE_INSET,
      w: ctx.stick, h: ctx.stick };
  }
  if (v.dpad) {
    const cx = out.stick ? out.stick.x + out.stick.w / 2 : PAD_EDGE_MARGIN + ctx.stick / 2;
    const dpadBottom = out.stick ? out.stick.y - PAD_BLOCK_GAP : bottom;
    out.dpad = { x: cx - ctx.dpad / 2, y: dpadBottom - ctx.dpad, w: ctx.dpad, h: ctx.dpad };
  }
  if (v.abxy) {
    out.abxy = { x: W - PAD_EDGE_MARGIN - ctx.abxy, y: bottom - ctx.abxy, w: ctx.abxy, h: ctx.abxy };
  }
  if (v.cStick) {
    const cx = out.abxy ? out.abxy.x + out.abxy.w / 2 : W - PAD_EDGE_MARGIN - ctx.abxy / 2;
    const stickBottom = out.abxy ? out.abxy.y - PAD_BLOCK_GAP : bottom;
    out.cStick = { x: cx - ctx.cStick / 2, y: stickBottom - ctx.cStick, w: ctx.cStick, h: ctx.cStick };
  }

  // Select/Start 底部居中一对，y 对齐左下簇贴底件（摇杆，缺省退回十字键）的
  // LOWER_BUTTON_CENTER_RATIO 行
  const anchor = out.stick ?? out.dpad;
  const anchorY = anchor
    ? anchor.y + anchor.w * LOWER_BUTTON_CENTER_RATIO - ctx.ssH / 2
    : bottom - ctx.ssH;
  const pairW = (v.select ? ctx.ssW : 0) + (v.start ? ctx.ssW : 0) +
    (v.select && v.start ? PAD_BLOCK_GAP : 0);
  if (v.select) {
    out.select = { x: W / 2 - pairW / 2, y: anchorY, w: ctx.ssW, h: ctx.ssH };
  }
  if (v.start) {
    out.start = { x: W / 2 + pairW / 2 - ctx.ssW, y: anchorY, w: ctx.ssW, h: ctx.ssH };
  }

  placeActionRowTop(ctx);
}

// 换屏/快进/Home 顶部居中一行（nds 动作按钮行），间隔 BLOCK_GAP
function placeActionRowTop(ctx: PadCtx): void {
  const v = ctx.v;
  const out = ctx.out;
  const order: string[] = ['pause', 'swap', 'turbo', 'home', 'more'];
  const rowH = Math.max(ctx.small, ctx.turbo);
  let total = 0;
  for (const key of order) {
    if (actionVisible(v, key)) {
      total += key === 'turbo' ? ctx.turbo : ctx.small;
      total += PAD_BLOCK_GAP;
    }
  }
  if (total > 0) {
    total -= PAD_BLOCK_GAP;
  }
  let x = ctx.input.width / 2 - total / 2;
  const g = ctx.input.gameRect;
  for (const key of order) {
    if (!actionVisible(v, key)) {
      continue;
    }
    const sz = key === 'turbo' ? ctx.turbo : ctx.small;
    const rect: PadRect = { x: x, y: PAD_EDGE_MARGIN + (rowH - sz) / 2, w: sz, h: sz };
    setActionRect(out, key, rect);
    // 顶行动作键压在画面上属于固有的 overlay 位置
    if (g && rectsIntersect(rect, g)) {
      out.overlay = true;
    }
    x += sz + PAD_BLOCK_GAP;
  }
}

function rectsIntersect(a: PadRect, b: PadRect): boolean {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

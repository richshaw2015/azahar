import { AzaharThemeColors } from '../../types/ThemeTypes';
import { ThemeManager } from '../../utils/ThemeManager';
import { mixWithWhite, pageGradientOf } from '../../utils/ThemeSurfaces';
import { displaySync } from '@kit.ArkGraphics2D';
const TARGET_CELL_VP: number = 72;
const CELL_FILL_RATIO: number = 0.78;
const PATTERN_CELLS: number = 6;
const SCROLL_CYCLE_S: number = 8;
const STATIC_ALPHA: number = 0.22;
const MOVING_ALPHA: number = 0.28;
const MERGED_ALPHA: number = 0.22;
// 深色模式下白方块过亮，alpha 减半再压低保持克制
const DARK_ALPHA_SCALE: number = 0.4;
const MOVING_CELL_OFFSET: number = 0.5;
const EXPECTED_FPS: number = 15;
const MAX_FPS: number = 30;
const FALLBACK_FRAME_MS: number = 66;
const NS_PER_SECOND: number = 1e9;
const LIGHT_TILE_TINT_MIN: number = 0.14;
const LIGHT_TILE_TINT_MAX: number = 0.26;
const DARK_TILE_TINT_MIN: number = 0.1;
const DARK_TILE_TINT_MAX: number = 0.2;

function drawRoundedRectPath(ctx: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D,
  x: number, y: number, w: number, h: number, r: number): void {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + w - r, y);
  ctx.arcTo(x + w, y, x + w, y + r, r);
  ctx.lineTo(x + w, y + h - r);
  ctx.arcTo(x + w, y + h, x + w - r, y + h, r);
  ctx.lineTo(x + r, y + h);
  ctx.arcTo(x, y + h, x, y + h - r, r);
  ctx.lineTo(x, y + r);
  ctx.arcTo(x, y, x + r, y, r);
  ctx.closePath();
  ctx.fill();
}

function tileTintAmount(index: number, isDark: boolean): number {
  // A periodic low-frequency field keeps adjacent tiles close in color and pattern seams smooth.
  const row = Math.floor(index / PATTERN_CELLS);
  const column = index % PATTERN_CELLS;
  const phase = 2 * Math.PI / PATTERN_CELLS;
  const value = 0.5 + 0.25 * (Math.sin(column * phase) + Math.sin(row * phase));
  const min = isDark ? DARK_TILE_TINT_MIN : LIGHT_TILE_TINT_MIN;
  const max = isDark ? DARK_TILE_TINT_MAX : LIGHT_TILE_TINT_MAX;
  return min + (max - min) * value;
}

@Component
export struct FloatTilesBackground {
  @Prop @Watch('onColorsChanged') themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();
  @Prop @Watch('onPlayChanged') isPlaying: boolean = true;
  @StorageLink('floatTilesPageScrolling') @Watch('onPlayChanged') isPageScrolling: boolean = false;

  private shouldPlay(): boolean {
    return this.isPlaying && !this.isPageScrolling;
  }

  private onPlayChanged(): void {
    if (this.shouldPlay()) {
      this.start();
    } else {
      this.stop();
    }
  }

  private staticContext: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private animContext: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));

  private time: number = 0;
  private canvasWidth: number = 0;
  private canvasHeight: number = 0;
  private staticPattern: CanvasPattern | null = null;
  private movingPattern: CanvasPattern | null = null;
  private frameSync: displaySync.DisplaySync | null = null;
  private fallbackTimer: number = 0;
  private lastFrameTime: number = 0;
  private staticAlphaScale: number = -1;

  aboutToDisappear(): void {
    this.stop();
  }

  private start(): void {
    if (this.frameSync !== null || this.fallbackTimer !== 0 || !this.shouldPlay()) {
      return;
    }
    this.lastFrameTime = 0;
    try {
      const sync: displaySync.DisplaySync = displaySync.create();
      sync.on('frame', (info: displaySync.IntervalInfo) => {
        this.onFrame(info.timestamp);
      });
      sync.setExpectedFrameRateRange({ expected: EXPECTED_FPS, min: 0, max: MAX_FPS });
      sync.start();
      this.frameSync = sync;
    } catch {
      this.fallbackTimer = setInterval(() => {
        this.onFrame(Date.now() * 1e6);
      }, FALLBACK_FRAME_MS);
    }
  }

  private stop(): void {
    if (this.frameSync !== null) {
      try {
        this.frameSync.off('frame');
        this.frameSync.stop();
      } catch {
      }
      this.frameSync = null;
    }
    if (this.fallbackTimer !== 0) {
      clearInterval(this.fallbackTimer);
      this.fallbackTimer = 0;
    }
  }

  private onFrame(timestampNs: number): void {
    if (!this.shouldPlay()) {
      this.stop();
      return;
    }
    if (this.lastFrameTime !== 0) {
      this.time += (timestampNs - this.lastFrameTime) / NS_PER_SECOND;
    }
    this.lastFrameTime = timestampNs;
    this.drawMoving();
  }

  private updateSize(newArea: Area): void {
    const w = newArea.width as number;
    const h = newArea.height as number;
    if (w <= 0 || h <= 0 || (w === this.canvasWidth && h === this.canvasHeight)) {
      return;
    }
    this.canvasWidth = w;
    this.canvasHeight = h;
    this.rebuildTilePattern();
    this.drawStatic();
    this.drawMoving();
  }

  private rebuildTilePattern(): void {
    if (this.canvasWidth <= 0) {
      return;
    }
    const cell = this.canvasWidth / Math.max(4, Math.round(this.canvasWidth / TARGET_CELL_VP));
    const tile = cell * CELL_FILL_RATIO;
    const radius = tile * 0.18;

    const patternSize = cell * PATTERN_CELLS;
    const offCanvas: OffscreenCanvas = new OffscreenCanvas(patternSize, patternSize);
    const offCtx = offCanvas.getContext('2d');
    const isDark = ThemeManager.getInstance().isDarkModeEffective();
    for (let row = 0; row < PATTERN_CELLS; row++) {
      for (let column = 0; column < PATTERN_CELLS; column++) {
        const index = row * PATTERN_CELLS + column;
        offCtx.fillStyle = mixWithWhite(this.themeColors.primary, tileTintAmount(index, isDark));
        drawRoundedRectPath(offCtx, column * cell + (cell - tile) / 2, row * cell + (cell - tile) / 2,
          tile, tile, radius);
      }
    }
    const bitmap: ImageBitmap = offCanvas.transferToImageBitmap();
    this.staticPattern = this.staticContext.createPattern(bitmap, 'repeat');
    this.movingPattern = this.animContext.createPattern(bitmap, 'repeat');
  }

  private onColorsChanged(): void {
    this.rebuildTilePattern();
    this.drawStatic();
    this.drawMoving();
  }

  private alphaScale(): number {
    return ThemeManager.getInstance().isDarkModeEffective() ? DARK_ALPHA_SCALE : 1;
  }

  private drawStatic(): void {
    if (this.staticPattern === null || this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      return;
    }
    const ctx = this.staticContext;
    this.staticAlphaScale = this.alphaScale();
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    ctx.fillStyle = this.staticPattern;
    ctx.globalAlpha = STATIC_ALPHA * this.staticAlphaScale;
    ctx.fillRect(0, 0, this.canvasWidth, this.canvasHeight);
    ctx.globalAlpha = 1;
  }

  private drawMoving(): void {
    if (this.movingPattern === null || this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      return;
    }
    const cell = this.canvasWidth / Math.max(4, Math.round(this.canvasWidth / TARGET_CELL_VP));
    const tile = cell * CELL_FILL_RATIO;
    const drift = ((this.time / SCROLL_CYCLE_S) % 1) * cell;
    const shift = drift + cell * MOVING_CELL_OFFSET;

    const scale = this.alphaScale();
    if (scale !== this.staticAlphaScale) {
      this.drawStatic();
    }
    const mod = ((cell / 2 + shift) % cell + cell) % cell - cell / 2;
    // 按移动方块与静态方块的重叠面积连续插值透明度，smoothstep 抹平两端拐点，避免阈值跳变
    const overlap = Math.max(0, 1 - Math.abs(mod) / tile);
    const area = overlap * overlap;
    const weight = area * area * (3 - 2 * area);
    const alpha = (MOVING_ALPHA + (MERGED_ALPHA - MOVING_ALPHA) * weight) * scale;

    const ctx = this.animContext;
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    ctx.save();
    ctx.translate(shift, shift);
    ctx.fillStyle = this.movingPattern;
    ctx.globalAlpha = alpha;
    ctx.fillRect(-shift, -shift, this.canvasWidth, this.canvasHeight);
    ctx.restore();
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [pageGradientOf(this.themeColors)[0], 0.0],
            [pageGradientOf(this.themeColors)[1], 1.0]
          ]
        })

      Canvas(this.staticContext)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.rebuildTilePattern();
          this.drawStatic();
        })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.updateSize(newArea);
        })

      Canvas(this.animContext)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.rebuildTilePattern();
          if (this.shouldPlay()) {
            this.start();
          }
        })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.updateSize(newArea);
        })
        .onVisibleAreaChange([0.0], (isExpanding: boolean, currentRatio: number) => {
          if (currentRatio > 0) {
            if (this.shouldPlay()) {
              this.start();
            }
          } else {
            this.stop();
          }
        })
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

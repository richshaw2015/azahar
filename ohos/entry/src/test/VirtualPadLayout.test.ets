import { describe, it, expect } from '@ohos/hypium';
import {
  computePadLayout,
  PadLayout,
  PadRect,
  PadSizes,
  PadVisibility
} from '../main/ets/utils/VirtualPadLayout';
import { LayoutComponent, LayoutRect, PositionedLayoutComponent } from '../main/ets/types/LayoutTypes';
import { LayoutConfigManager } from '../main/ets/utils/LayoutConfigManager';

// 与 AzaharVirtualButtonLayer 相同的常量（controlScale=50 → 系数 1.0）
const SHOULDER = 0.18 * (110 / 472) / (78 / 463);
const DPAD = SHOULDER * (148 / 110) * (512 / 482);
const STICK = DPAD * (482 / 512) * 0.8;
const ABXY = SHOULDER * (92 / 174) * (512 / 176);
const SS = SHOULDER * 118 / 174;
const LR_AS = 76 / 174;
const SS_AS = 62 / 118;

function sizesOf(min: number): PadSizes {
  return {
    lrW: min * SHOULDER, lrH: min * SHOULDER * LR_AS,
    ssW: min * SS, ssH: min * SS * SS_AS,
    dpad: min * DPAD, abxy: min * ABXY,
    stick: min * STICK, cStick: min * STICK / 2,
    small: min * 0.08, turbo: min * 0.10
  };
}

const VIS_DEFAULT: PadVisibility = {
  l: true, r: true, zl: false, zr: false, dpad: true, stick: true, cStick: false,
  abxy: true, select: true, start: true, home: false, swap: false, turbo: false,
  pause: false, more: false
};
const VIS_ALL: PadVisibility = {
  l: true, r: true, zl: true, zr: true, dpad: true, stick: true, cStick: true,
  abxy: true, select: true, start: true, home: true, swap: true, turbo: true,
  pause: true, more: true
};

const TOL = 0.5;

function rects(o: PadLayout): PadRect[] {
  const all = [o.l, o.r, o.zl, o.zr, o.dpad, o.stick, o.cStick, o.abxy,
    o.select, o.start, o.home, o.swap, o.turbo];
  return all.filter((r: PadRect | null) => r !== null) as PadRect[];
}

function intersects(a: PadRect, b: PadRect): boolean {
  return a.x < b.x + b.w - TOL && b.x < a.x + a.w - TOL &&
    a.y < b.y + b.h - TOL && b.y < a.y + a.h - TOL;
}

function assertLayout(o: PadLayout, w: number, h: number, g: PadRect | null): void {
  const rs = rects(o);
  for (let i = 0; i < rs.length; i++) {
    for (let j = i + 1; j < rs.length; j++) {
      expect(intersects(rs[i], rs[j])).assertFalse();
    }
    expect(rs[i].x >= -TOL && rs[i].y >= -TOL &&
      rs[i].x + rs[i].w <= w + TOL && rs[i].y + rs[i].h <= h + TOL).assertTrue();
    if (!o.overlay && g) {
      expect(intersects(rs[i], g)).assertFalse();
    }
  }
}

export default function virtualPadLayoutTest() {
  describe('virtualPadLayout', () => {
    const portraits: number[][] = [[320, 640], [360, 780], [393, 852], [412, 915], [600, 960], [800, 1280]];
    const landscapes: number[][] = [[640, 360], [780, 360], [870, 400], [915, 412], [1280, 800]];

    it('stacks portrait select and start between dpad and abxy', 0, () => {
      const width = 393;
      const height = 852;
      const layout = computePadLayout({
        width: width,
        height: height,
        gameRect: { x: 0, y: 0, w: width, h: 530 },
        sizes: sizesOf(Math.min(width, height)),
        visible: VIS_DEFAULT
      });
      expect(layout.select !== null && layout.start !== null).assertTrue();
      const select = layout.select as PadRect;
      const start = layout.start as PadRect;
      expect(Math.abs(select.x - start.x) < TOL).assertTrue();
      expect(select.y + select.h <= start.y + TOL).assertTrue();
      expect(select.x >= (layout.dpad as PadRect).x + (layout.dpad as PadRect).w - TOL).assertTrue();
      expect(select.x + select.w <= (layout.abxy as PadRect).x + TOL).assertTrue();
      assertLayout(layout, width, height, { x: 0, y: 0, w: width, h: 530 });
    });

    it('matches Android portrait anchors with the stick below the dpad on tablets', 0, () => {
      const width = 800;
      const height = 1280;
      const components = LayoutConfigManager.getInstance().buildDefaultPortraitLayout(width, height);
      const findRect = (component: LayoutComponent): LayoutRect => {
        const found = components.find((item: PositionedLayoutComponent) => item.component === component);
        expect(found !== undefined).assertTrue();
        return (found as PositionedLayoutComponent).rect;
      };
      const topScreen = findRect(LayoutComponent.TOP_SCREEN);
      const dpad = findRect(LayoutComponent.DPAD);
      const stick = findRect(LayoutComponent.STICK);
      const abxy = findRect(LayoutComponent.BUTTONS);
      const select = findRect(LayoutComponent.BUTTON_SELECT);
      const start = findRect(LayoutComponent.BUTTON_START);
      const leftShoulder = findRect(LayoutComponent.BUTTON_L);
      const pause = findRect(LayoutComponent.BUTTON_PAUSE);

      expect(abxy.y + abxy.height).assertEqual(height - 12);
      expect(stick.y + stick.height).assertEqual(height - 12);
      expect(dpad.y + dpad.height + 8).assertEqual(stick.y);
      expect(dpad.width).assertEqual(154);
      expect(leftShoulder.y).assertEqual(topScreen.height);
      expect(pause.y).assertEqual(leftShoulder.y);
      expect(select.x).assertEqual(start.x);
      expect(select.y + select.height + 12).assertEqual(start.y);
      expect(start.y + start.height).assertEqual(height - 12);
    });

    for (const [w, h] of portraits) {
      const game: PadRect = { x: 0, y: 0, w: w, h: Math.min(h, w * 1.35) };
      for (const g of [null, game]) {
        for (const v of [VIS_DEFAULT, VIS_ALL]) {
          it(`portrait_${w}x${h}_${g ? 'game' : 'null'}_${v === VIS_ALL ? 'all' : 'def'}`, () => {
            assertLayout(
              computePadLayout({ width: w, height: h, gameRect: g, sizes: sizesOf(Math.min(w, h)), visible: v }),
              w, h, g);
          });
        }
      }
    }

    for (const [w, h] of landscapes) {
      const gw = h * (400 / 480);
      const game: PadRect = { x: (w - gw) / 2, y: 0, w: gw, h: h };
      for (const g of [null, game]) {
        for (const v of [VIS_DEFAULT, VIS_ALL]) {
          it(`landscape_${w}x${h}_${g ? 'game' : 'null'}_${v === VIS_ALL ? 'all' : 'def'}`, () => {
            assertLayout(
              computePadLayout({ width: w, height: h, gameRect: g, sizes: sizesOf(Math.min(w, h)), visible: v }),
              w, h, g);
          });
        }
      }
    }
  });
}

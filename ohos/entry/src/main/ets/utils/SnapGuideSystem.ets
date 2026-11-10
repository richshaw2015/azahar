/**
 * SnapGuideSystem - 布局编辑器网格吸附系统
 *
 * 提供拖拽时的智能吸附功能:
 * - 网格吸附: 元素边缘/中心吸附到固定间距的网格线
 * - 中心线吸附: 吸附到画布水平/垂直中心线
 * - 元素对齐吸附: 吸附到其他元素的边缘或中心线
 *
 * 吸附优先级: 元素对齐 > 中心线 > 网格
 */

import { PositionedLayoutComponent, LayoutRect } from '../types/LayoutTypes';
import { DEFAULT_LAYOUT_EDITOR_GRID_SIZE } from '../types/SettingsTypes';

const DEFAULT_GRID_SIZE: number = DEFAULT_LAYOUT_EDITOR_GRID_SIZE;
const MIN_GRID_SIZE: number = 0;
const MAX_GRID_SIZE: number = 24;
const GRID_SIZE_STEP: number = 4;
const SNAP_THRESHOLD: number = 10;
const CENTER_SNAP_THRESHOLD: number = 14;
const ELEMENT_SNAP_THRESHOLD: number = 10;

export class SnapGuideLine {
  type: string = 'grid';
  direction: string = 'vertical';
  position: number = 0;

  constructor(type: string, direction: string, position: number) {
    this.type = type;
    this.direction = direction;
    this.position = position;
  }
}

export class SnapResult {
  x: number = 0;
  y: number = 0;
  guideLines: SnapGuideLine[] = [];

  constructor(x: number, y: number, guideLines: SnapGuideLine[]) {
    this.x = x;
    this.y = y;
    this.guideLines = guideLines;
  }
}

class SnapCandidate {
  snappedValue: number = 0;
  distance: number = 0;
  guideLine: SnapGuideLine = new SnapGuideLine('grid', 'vertical', 0);

  constructor(sv: number, d: number, gl: SnapGuideLine) {
    this.snappedValue = sv;
    this.distance = d;
    this.guideLine = gl;
  }
}

export class SnapGuideSystem {
  static readonly GRID_SIZE: number = DEFAULT_GRID_SIZE;
  static readonly MIN_GRID_SIZE: number = MIN_GRID_SIZE;
  static readonly MAX_GRID_SIZE: number = MAX_GRID_SIZE;
  static readonly GRID_SIZE_STEP: number = GRID_SIZE_STEP;

  private _gridSize: number = DEFAULT_GRID_SIZE;

  private _gridEnabled: boolean = true;
  private _centerEnabled: boolean = true;
  private _elementEnabled: boolean = true;

  get gridEnabled(): boolean {
    return this._gridEnabled;
  }

  set gridEnabled(v: boolean) {
    this._gridEnabled = v;
  }

  get gridSize(): number {
    return this._gridSize;
  }

  set gridSize(v: number) {
    let normalized = Math.round(v / GRID_SIZE_STEP) * GRID_SIZE_STEP;
    normalized = Math.max(MIN_GRID_SIZE, Math.min(MAX_GRID_SIZE, normalized));
    this._gridSize = normalized;
    this._gridEnabled = normalized > 0;
  }

  get centerEnabled(): boolean {
    return this._centerEnabled;
  }

  set centerEnabled(v: boolean) {
    this._centerEnabled = v;
  }

  get elementEnabled(): boolean {
    return this._elementEnabled;
  }

  set elementEnabled(v: boolean) {
    this._elementEnabled = v;
  }

  private addXEdge(c: SnapCandidate[], edge: number, target: number, rect: LayoutRect, type: string, gp: number, th: number): void {
    const dist: number = Math.abs(edge - target);
    if (dist > th) {
      return;
    }
    const line: SnapGuideLine = new SnapGuideLine(type, 'vertical', gp);
    const candidate: SnapCandidate = new SnapCandidate(rect.x + (target - edge), dist, line);
    c.push(candidate);
  }

  private addXCenter(c: SnapCandidate[], ctr: number, target: number, rect: LayoutRect, type: string, gp: number, th: number): void {
    const dist: number = Math.abs(ctr - target);
    if (dist > th) {
      return;
    }
    const line: SnapGuideLine = new SnapGuideLine(type, 'vertical', gp);
    const candidate: SnapCandidate = new SnapCandidate(rect.x + (target - ctr), dist, line);
    c.push(candidate);
  }

  private addYEdge(c: SnapCandidate[], edge: number, target: number, rect: LayoutRect, type: string, gp: number, th: number): void {
    const dist: number = Math.abs(edge - target);
    if (dist > th) {
      return;
    }
    const line: SnapGuideLine = new SnapGuideLine(type, 'horizontal', gp);
    const candidate: SnapCandidate = new SnapCandidate(rect.y + (target - edge), dist, line);
    c.push(candidate);
  }

  private addYCenter(c: SnapCandidate[], ctr: number, target: number, rect: LayoutRect, type: string, gp: number, th: number): void {
    const dist: number = Math.abs(ctr - target);
    if (dist > th) {
      return;
    }
    const line: SnapGuideLine = new SnapGuideLine(type, 'horizontal', gp);
    const candidate: SnapCandidate = new SnapCandidate(rect.y + (target - ctr), dist, line);
    c.push(candidate);
  }

  private getPriority(type: string): number {
    if (type === 'element') {
      return 3;
    }
    if (type === 'center') {
      return 2;
    }
    return 1;
  }

  private pickBest(candidates: SnapCandidate[]): SnapCandidate | null {
    if (candidates.length === 0) {
      return null;
    }
    let best: SnapCandidate = candidates[0];
    for (let i: number = 1; i < candidates.length; i++) {
      const cur: SnapCandidate = candidates[i];
      const bp: number = this.getPriority(best.guideLine.type);
      const cp: number = this.getPriority(cur.guideLine.type);
      if (cp > bp || (cp === bp && cur.distance < best.distance)) {
        best = cur;
      }
    }
    return best;
  }

  calculateSnap(
    targetRect: LayoutRect,
    allComponents: PositionedLayoutComponent[],
    dragIndex: number,
    canvasLeft: number,
    canvasTop: number,
    canvasRight: number,
    canvasBottom: number
  ): SnapResult {
    const guideLines: SnapGuideLine[] = [];
    const left: number = targetRect.x;
    const right: number = targetRect.x + targetRect.width;
    const top: number = targetRect.y;
    const bottom: number = targetRect.y + targetRect.height;
    const centerX: number = targetRect.x + targetRect.width / 2;
    const centerY: number = targetRect.y + targetRect.height / 2;
    const canvasCenterX: number = (canvasLeft + canvasRight) / 2;
    const canvasCenterY: number = (canvasTop + canvasBottom) / 2;
    const xCandidates: SnapCandidate[] = [];
    const yCandidates: SnapCandidate[] = [];

    // 1. 元素对齐吸附
    if (this._elementEnabled) {
      for (let i: number = 0; i < allComponents.length; i++) {
        if (i === dragIndex) {
          continue;
        }
        const o: LayoutRect = allComponents[i].rect;
        const oL: number = o.x;
        const oR: number = o.x + o.width;
        const oT: number = o.y;
        const oB: number = o.y + o.height;
        const oCX: number = o.x + o.width / 2;
        const oCY: number = o.y + o.height / 2;
        this.addXEdge(xCandidates, left, oL, targetRect, 'element', oL, ELEMENT_SNAP_THRESHOLD);
        this.addXEdge(xCandidates, right, oR, targetRect, 'element', oR, ELEMENT_SNAP_THRESHOLD);
        this.addXEdge(xCandidates, left, oR, targetRect, 'element', oR, ELEMENT_SNAP_THRESHOLD);
        this.addXEdge(xCandidates, right, oL, targetRect, 'element', oL, ELEMENT_SNAP_THRESHOLD);
        this.addXCenter(xCandidates, centerX, oCX, targetRect, 'element', oCX, ELEMENT_SNAP_THRESHOLD);
        this.addYEdge(yCandidates, top, oT, targetRect, 'element', oT, ELEMENT_SNAP_THRESHOLD);
        this.addYEdge(yCandidates, bottom, oB, targetRect, 'element', oB, ELEMENT_SNAP_THRESHOLD);
        this.addYEdge(yCandidates, top, oB, targetRect, 'element', oB, ELEMENT_SNAP_THRESHOLD);
        this.addYEdge(yCandidates, bottom, oT, targetRect, 'element', oT, ELEMENT_SNAP_THRESHOLD);
        this.addYCenter(yCandidates, centerY, oCY, targetRect, 'element', oCY, ELEMENT_SNAP_THRESHOLD);
      }
    }

    // 2. 中心线吸附
    if (this._centerEnabled) {
      this.addXCenter(xCandidates, centerX, canvasCenterX, targetRect, 'center', canvasCenterX, CENTER_SNAP_THRESHOLD);
      this.addYCenter(yCandidates, centerY, canvasCenterY, targetRect, 'center', canvasCenterY, CENTER_SNAP_THRESHOLD);
    }

    // 3. 网格吸附
    if (this._gridEnabled && this._gridSize > 0) {
      const gL: number = Math.round(left / this._gridSize) * this._gridSize;
      this.addXEdge(xCandidates, left, gL, targetRect, 'grid', gL, SNAP_THRESHOLD);
      const gT: number = Math.round(top / this._gridSize) * this._gridSize;
      this.addYEdge(yCandidates, top, gT, targetRect, 'grid', gT, SNAP_THRESHOLD);
      const gCX: number = Math.round(centerX / this._gridSize) * this._gridSize;
      this.addXCenter(xCandidates, centerX, gCX, targetRect, 'grid', gCX, SNAP_THRESHOLD);
      const gCY: number = Math.round(centerY / this._gridSize) * this._gridSize;
      this.addYCenter(yCandidates, centerY, gCY, targetRect, 'grid', gCY, SNAP_THRESHOLD);
    }

    // 选择最佳候选
    let finalX: number = targetRect.x;
    let finalY: number = targetRect.y;
    const bestX: SnapCandidate | null = this.pickBest(xCandidates);
    if (bestX !== null) {
      finalX = bestX.snappedValue;
      guideLines.push(bestX.guideLine);
    }
    const bestY: SnapCandidate | null = this.pickBest(yCandidates);
    if (bestY !== null) {
      finalY = bestY.snappedValue;
      guideLines.push(bestY.guideLine);
    }
    return new SnapResult(finalX, finalY, guideLines);
  }
}

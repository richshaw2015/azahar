

import { AzaharFrontendAction, AzaharVirtualButtonLayer } from './AzaharVirtualButtonLayer';
import { PadRect } from '../../utils/VirtualPadLayout';

import uiMaterial from '@ohos.arkui.uiMaterial';
import { AzaharAnalog, AzaharKey } from '../../types/AzaharNative';

import { FONT_SIZE_SETTING_DESC } from '../../types/UIConstants';

import { PositionedLayoutComponent } from '../../types/LayoutTypes';
import { HapticManager } from '../../utils/HapticManager';

/** 游戏 HUD：虚拟按键层 + 性能悬浮层 */
@Component
export struct GameViewHud {
  @Prop controlsWidth: number = 0;
  @Prop controlsHeight: number = 0;
  @Prop padInsetLeft: number = 0;
  @Prop padInsetTop: number = 0;
  @Prop padInsetRight: number = 0;
  @Prop padInsetBottom: number = 0;
  @Prop gameRect: PadRect | null = null;
  @Prop customPadComponents: PositionedLayoutComponent[] = [];
  @Prop inputOpacity: number = 70;
  @Prop showOverlay: boolean = true;
  @Prop circlePadOffsetX: number = 0;
  @Prop circlePadOffsetY: number = 0;
  @Prop cStickOffsetX: number = 0;
  @Prop cStickOffsetY: number = 0;
  @Prop circlePadCenterOffsetX: number = 0;
  @Prop circlePadCenterOffsetY: number = 0;
  @Prop cStickCenterOffsetX: number = 0;
  @Prop cStickCenterOffsetY: number = 0;
  @Prop circlePadActive: boolean = false;
  @Prop cStickActive: boolean = false;
  @Prop fastForwardEnabled: boolean = false;
  @Prop swapScreenEnabled: boolean = false;
  @Prop slowMotionEnabled: boolean = false;
  @Prop microphoneEnabled: boolean = false;
  @Prop showPauseMenu: boolean = false;
  @Prop showCheatPanel: boolean = false;
  @Prop showSaveStateDetail: boolean = false;
  @Prop showQuickActions: boolean = false;
  // softInputBehaviour=always_invisible 时不渲染触控隐藏后的恢复入口
  @Prop hideRecoveryEntry: boolean = false;
  @Prop performanceOverlayEnabled: boolean = false;
  @Prop performanceOverlayPosition: number = 0;
  @Prop performanceOverlayText: string = '';
  @Prop perfOverlayAlignment: Alignment = Alignment.TopStart;
  @Prop perfOverlayArea: PadRect = { x: 0, y: 0, w: 0, h: 0 };
  @Prop macroKeys: AzaharKey[] = [];
  /** 手柄按住的 3DS 按键（AzaharKey 值），用于虚拟按键按下视觉反馈 */
  @Prop externalPressedKeys: number[] = [];
  /** 手柄驱动的 3DS 摇杆值（-1~1），用于虚拟摇杆随物理摇杆移动 */
  @Prop externalCirclePadX: number = 0;
  @Prop externalCirclePadY: number = 0;
  @Prop externalCStickX: number = 0;
  @Prop externalCStickY: number = 0;
  handleAnalogTouch: (event: TouchEvent, analog: AzaharAnalog) => void = () => {};
  handleVirtualKeyChange: (key: AzaharKey, pressed: boolean) => void = () => {};
  handleVirtualAction: (action: AzaharFrontendAction) => void = () => {};
  handleMacroKeys: (keys: AzaharKey[], pressed: boolean) => void = () => {};

  @Builder
  GameControls() {
    AzaharVirtualButtonLayer({
      screenWidth: this.controlsWidth,
      screenHeight: this.controlsHeight,
      insetLeft: this.padInsetLeft,
      insetTop: this.padInsetTop,
      insetRight: this.padInsetRight,
      insetBottom: this.padInsetBottom,
      customComponents: this.customPadComponents,
      gameRect: this.gameRect,
      circlePadOffsetX: this.circlePadOffsetX,
      circlePadOffsetY: this.circlePadOffsetY,
      cStickOffsetX: this.cStickOffsetX,
      cStickOffsetY: this.cStickOffsetY,
      circlePadCenterOffsetX: this.circlePadCenterOffsetX,
      circlePadCenterOffsetY: this.circlePadCenterOffsetY,
      cStickCenterOffsetX: this.cStickCenterOffsetX,
      cStickCenterOffsetY: this.cStickCenterOffsetY,
      circlePadActive: this.circlePadActive,
      cStickActive: this.cStickActive,
      disabled: this.showPauseMenu || this.showCheatPanel || this.showSaveStateDetail || this.showQuickActions,
      buttonOpacity: this.inputOpacity,
      showOverlay: this.showOverlay,
      fastForwardActive: this.fastForwardEnabled,
      swapScreensActive: this.swapScreenEnabled,
      slowMotionActive: this.slowMotionEnabled,
      microphoneActive: this.microphoneEnabled,
      hideRecoveryEntry: this.hideRecoveryEntry,
      macroKeys: this.macroKeys,
      externalPressedKeys: this.externalPressedKeys,
      externalCirclePadX: this.externalCirclePadX,
      externalCirclePadY: this.externalCirclePadY,
      externalCStickX: this.externalCStickX,
      externalCStickY: this.externalCStickY,
      onKeyChange: (key: AzaharKey, pressed: boolean) => {
        if (pressed) {
          HapticManager.getInstance().trigger();
        }
        this.handleVirtualKeyChange(key, pressed);
      },
      onAnalogTouch: (event: TouchEvent, analog: AzaharAnalog) => {
        this.handleAnalogTouch(event, analog);
      },
      onAction: (action: AzaharFrontendAction) => {
        HapticManager.getInstance().trigger();
        this.handleVirtualAction(action);
      },
      onMacroKeys: (keys: AzaharKey[], pressed: boolean) => {
        if (pressed) {
          HapticManager.getInstance().trigger();
        }
        this.handleMacroKeys(keys, pressed);
      }
    })
  }

  @Builder
  PerformanceOverlay() {
    if (this.performanceOverlayEnabled && this.performanceOverlayText.length > 0) {
      // 对齐 nds：锚定游戏画面区域（双屏并集），位置选项只做区内对齐
      Stack() {
        Text(this.performanceOverlayText)
          .fontSize(FONT_SIZE_SETTING_DESC)
          .fontColor($r('app.color.perf_overlay_text'))
          .fontWeight(FontWeight.Regular)
          .textShadow([
            { radius: 0, color: $r('app.color.text_outline'), offsetX: 1, offsetY: 0 },
            { radius: 0, color: $r('app.color.text_outline'), offsetX: -1, offsetY: 0 },
            { radius: 0, color: $r('app.color.text_outline'), offsetX: 0, offsetY: 1 },
            { radius: 0, color: $r('app.color.text_outline'), offsetX: 0, offsetY: -1 },
            { radius: 0, color: $r('app.color.text_outline'), offsetX: 1, offsetY: 1 },
            { radius: 0, color: $r('app.color.text_outline'), offsetX: -1, offsetY: -1 },
            { radius: 0, color: $r('app.color.text_outline'), offsetX: 1, offsetY: -1 },
            { radius: 0, color: $r('app.color.text_outline'), offsetX: -1, offsetY: 1 }
          ])
      }
      .position({ x: this.perfOverlayArea.x, y: this.perfOverlayArea.y })
      .width(this.perfOverlayArea.w)
      .height(this.perfOverlayArea.h)
      .padding($r('sys.float.ohos_id_elements_margin_vertical_m'))
      .alignContent(this.perfOverlayAlignment)
      .hitTestBehavior(HitTestMode.None)
    }
  }

  // 锚定区域：游戏画面（双屏并集）；布局未就绪时退化为安全区内窗口
  private getPerformanceOverlayArea(): PadRect {
    const g = this.gameRect;
    if (g !== null) {
      return g;
    }
    return {
      x: this.padInsetLeft,
      y: this.padInsetTop,
      w: Math.max(0, this.controlsWidth - this.padInsetLeft - this.padInsetRight),
      h: Math.max(0, this.controlsHeight - this.padInsetTop - this.padInsetBottom)
    };
  }

  // 0-5：左上/中上/右上/左下/中下/右下
  private getPerformanceOverlayAlignment(): Alignment {
    switch (this.performanceOverlayPosition) {
      case 1:
        return Alignment.Top;
      case 2:
        return Alignment.TopEnd;
      case 3:
        return Alignment.BottomStart;
      case 4:
        return Alignment.Bottom;
      case 5:
        return Alignment.BottomEnd;
      default:
        return Alignment.TopStart;
    }
  }

  build() {
    Stack() {
      this.GameControls()
      this.PerformanceOverlay()
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }
}

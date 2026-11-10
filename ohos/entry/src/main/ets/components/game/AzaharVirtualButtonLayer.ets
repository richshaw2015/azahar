import { AzaharAnalog, AzaharKey } from '../../types/AzaharNative';
import { AbxyButtonSpec, getOverlayControlSizes, getThemeAbxy } from '../../utils/OverlayThemeHelper';
import { computePadLayout, DEFAULT_PAD_VISIBILITY, PadLayout, PadRect, PadSizes, PadVisibility } from '../../utils/VirtualPadLayout';
import { getComponentImageName, LayoutComponent, PositionedLayoutComponent } from '../../types/LayoutTypes';

export type AzaharFrontendAction =
  'more' | 'pause' | 'quick_save' | 'quick_load' | 'reset' | 'fast_forward' | 'slow_motion' |
  'swap_screens' | 'toggle_upright_screen' | 'toggle_soft_input' | 'toggle_lid' |
  'toggle_microphone' | 'open_settings' | 'toggle_screen_orientation';

/** 前端动作 → 布局组件（更多菜单过滤已放置项、编辑器组件渲染共用同一映射，对齐 nds） */
export function frontendActionToLayoutComponent(action: AzaharFrontendAction): LayoutComponent | null {
  const map: Record<string, LayoutComponent> = {
    'pause': LayoutComponent.BUTTON_PAUSE,
    'quick_save': LayoutComponent.BUTTON_QUICK_SAVE,
    'quick_load': LayoutComponent.BUTTON_QUICK_LOAD,
    'reset': LayoutComponent.BUTTON_RESET,
    'fast_forward': LayoutComponent.BUTTON_FAST_FORWARD_TOGGLE,
    'slow_motion': LayoutComponent.BUTTON_SLOW_MOTION_TOGGLE,
    'swap_screens': LayoutComponent.BUTTON_SWAP_SCREENS,
    'toggle_soft_input': LayoutComponent.BUTTON_TOGGLE_SOFT_INPUT,
    'toggle_lid': LayoutComponent.BUTTON_HINGE,
    'toggle_microphone': LayoutComponent.BUTTON_MICROPHONE_TOGGLE,
    'open_settings': LayoutComponent.BUTTON_SETTINGS,
    'toggle_screen_orientation': LayoutComponent.BUTTON_SCREEN_ROTATION,
  };
  return map[action] ?? null;
}

/** 布局组件 → 前端动作；非动作组件（按键/摇杆/屏幕）返回 null */
export function layoutComponentToAction(component: LayoutComponent): AzaharFrontendAction | null {
  const map: Record<string, AzaharFrontendAction> = {
    'BUTTON_PAUSE': 'pause',
    'BUTTON_QUICK_SAVE': 'quick_save',
    'BUTTON_QUICK_LOAD': 'quick_load',
    'BUTTON_RESET': 'reset',
    'BUTTON_FAST_FORWARD_TOGGLE': 'fast_forward',
    'BUTTON_SLOW_MOTION_TOGGLE': 'slow_motion',
    'BUTTON_SWAP_SCREENS': 'swap_screens',
    'BUTTON_TOGGLE_SOFT_INPUT': 'toggle_soft_input',
    'BUTTON_HINGE': 'toggle_lid',
    'BUTTON_MICROPHONE_TOGGLE': 'toggle_microphone',
    'BUTTON_SETTINGS': 'open_settings',
    'BUTTON_SCREEN_ROTATION': 'toggle_screen_orientation',
    'BUTTON_MORE': 'more',
  };
  return map[component] ?? null;
}

const TOUCH_SCALE_FACTOR: number = 1.5;
const DPAD_TILT_ANGLE: number = 14;
const DPAD_TILT_PERSPECTIVE: number = 600;
const PRESS_ANIMATION_MS: number = 80;

@Component
export struct AzaharVirtualButtonLayer {
  @Prop @Watch('refreshPadLayout') screenWidth: number = 360;
  @Prop @Watch('refreshPadLayout') screenHeight: number = 0;
  // 安全区内边距（vp）：按键布局在内边距区域内计算，结果平移回窗口坐标
  @Prop @Watch('refreshPadLayout') insetLeft: number = 0;
  @Prop @Watch('refreshPadLayout') insetTop: number = 0;
  @Prop @Watch('refreshPadLayout') insetRight: number = 0;
  @Prop @Watch('refreshPadLayout') insetBottom: number = 0;
  /** 布局编辑器保存的自定义组件矩形（窗口坐标 vp）；空 = 走自适应默认布局 */
  @Prop @Watch('refreshPadLayout') customComponents: PositionedLayoutComponent[] = [];
  /** 原生画面矩形（vp，两屏并集）；null = 无画面信息 */
  @Prop @Watch('refreshPadLayout') gameRect: PadRect | null = null;
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
  @Prop @Watch('onDisabledChanged') disabled: boolean = false;
  @Prop buttonOpacity: number = 50;
  @Prop showOverlay: boolean = true;
  @Prop fastForwardActive: boolean = false;
  @Prop swapScreensActive: boolean = false;
  @Prop slowMotionActive: boolean = false;
  @Prop microphoneActive: boolean = false;
  // softInputBehaviour=always_invisible 时连恢复入口也不渲染（用户明确要求无触控 UI）
  @Prop hideRecoveryEntry: boolean = false;

  // 宏按键（BUTTON_MACRO）触发的 3DS 按键集合，由设置页配置经 GameView 传入
  @Prop macroKeys: AzaharKey[] = [];
  /** 手柄按住的 3DS 按键（AzaharKey 值）：仅参与按下视觉反馈，不触发 onKeyChange（对齐 nds externalPressedKeys） */
  @Prop externalPressedKeys: number[] = [];
  /** 手柄驱动的 3DS 摇杆值（-1~1）：触摸未激活时显示物理摇杆位置，不触发 sendAnalogEvent */
  @Prop externalCirclePadX: number = 0;
  @Prop externalCirclePadY: number = 0;
  @Prop externalCStickX: number = 0;
  @Prop externalCStickY: number = 0;

  onKeyChange: (key: AzaharKey, pressed: boolean) => void = () => {};
  onAnalogTouch: (event: TouchEvent, analog: AzaharAnalog) => void = () => {};
  onAction: (action: AzaharFrontendAction) => void = () => {};
  // 宏按下/抬起时整组上报；来源区分交给 GameView 的持有者计数
  onMacroKeys: (keys: AzaharKey[], pressed: boolean) => void = () => {};

  @State private pressedKeys: number[] = [];
  @State private pressedActions: string[] = [];
  @State private macroPressed: boolean = false;
  // 自定义布局中无固定槽位的动作组件（慢速/快存/麦克风等编辑器可放置项），由 applyCustomComponents 收集
  @State private extraActionComponents: PositionedLayoutComponent[] = [];

  // 同一次 build 内只算一次的布局缓存
  @State private padLayout: PadLayout = computePadLayout({
    width: 360, height: 640, gameRect: null,
    sizes: { lrW: 1, lrH: 1, ssW: 1, ssH: 1, dpad: 1, abxy: 1, stick: 1, cStick: 1, small: 1, turbo: 1 },
    visible: { l: false, r: false, zl: false, zr: false, dpad: false, stick: false, cStick: false,
      abxy: false, select: false, start: false, home: false, swap: false, turbo: false,
      pause: false, more: false }
  });

  private padSizes(): PadSizes {
    const s = getOverlayControlSizes();
    return {
      lrW: s.lrWidth,
      lrH: s.lrHeight,
      ssW: s.ssWidth,
      ssH: s.ssHeight,
      dpad: s.dpad,
      abxy: s.abxy,
      stick: s.stick,
      cStick: s.cStick,
      small: s.action,
      turbo: s.action
    };
  }

  private padVisibility(): PadVisibility {
    return DEFAULT_PAD_VISIBILITY;
  }

  private currentPadLayout(): PadLayout {
    const offsetX = this.insetLeft;
    const offsetY = this.insetTop;
    const effW = Math.max(1, this.viewWidth() - offsetX - this.insetRight);
    const effH = Math.max(1, this.viewHeight() - offsetY - this.insetBottom);
    const localGame: PadRect | null = this.gameRect
      ? { x: this.gameRect.x - offsetX, y: this.gameRect.y - offsetY,
          w: this.gameRect.w, h: this.gameRect.h }
      : null;
    const layout = computePadLayout({
      width: effW,
      height: effH,
      gameRect: localGame,
      sizes: this.padSizes(),
      visible: this.padVisibility()
    });
    if (offsetX === 0 && offsetY === 0) {
      return layout;
    }
    const shift = (rect: PadRect | null): PadRect | null => rect
      ? { x: rect.x + offsetX, y: rect.y + offsetY, w: rect.w, h: rect.h } : null;
    return {
      fit: layout.fit,
      overlay: layout.overlay,
      l: shift(layout.l), r: shift(layout.r), zl: shift(layout.zl), zr: shift(layout.zr),
      dpad: shift(layout.dpad), stick: shift(layout.stick), cStick: shift(layout.cStick),
      abxy: shift(layout.abxy), select: shift(layout.select), start: shift(layout.start),
      home: shift(layout.home), swap: shift(layout.swap), turbo: shift(layout.turbo),
      pause: shift(layout.pause), more: shift(layout.more)
    };
  }

  private refreshPadLayout(): void {
    this.padLayout = this.applyCustomComponents(this.currentPadLayout());
  }

  // 用编辑器保存的组件矩形覆盖自适应结果；组件坐标是窗口绝对坐标。
  // 编辑器只管按键槽位（摇杆/C 摇杆/Home 沿用算法结果）；
  // 已保存布局中不存在的槽位 → 隐藏（和 nds 一致，布局内容即显示内容）。
  private applyCustomComponents(layout: PadLayout): PadLayout {
    if (this.customComponents.length === 0) {
      this.extraActionComponents = [];
      return layout;
    }
    const out: PadLayout = {
      fit: layout.fit,
      overlay: layout.overlay,
      l: null, r: null, zl: null, zr: null, dpad: null,
      stick: null, cStick: null, abxy: null,
      select: null, start: null, home: null,
      swap: null, turbo: null, pause: null, more: null
    };
    const extras: PositionedLayoutComponent[] = [];
    for (const c of this.customComponents) {
      const rect: PadRect = { x: c.rect.x, y: c.rect.y, w: c.rect.width, h: c.rect.height };
      switch (c.component) {
        case LayoutComponent.BUTTON_L: out.l = rect; break;
        case LayoutComponent.BUTTON_R: out.r = rect; break;
        case LayoutComponent.BUTTON_ZL: out.zl = rect; break;
        case LayoutComponent.BUTTON_ZR: out.zr = rect; break;
        case LayoutComponent.DPAD: out.dpad = rect; break;
        case LayoutComponent.BUTTONS: out.abxy = rect; break;
        case LayoutComponent.STICK: out.stick = rect; break;
        case LayoutComponent.CSTICK: out.cStick = rect; break;
        case LayoutComponent.BUTTON_SELECT: out.select = rect; break;
        case LayoutComponent.BUTTON_START: out.start = rect; break;
        case LayoutComponent.BUTTON_HOME: out.home = rect; break;
        case LayoutComponent.BUTTON_SWAP_SCREENS: out.swap = rect; break;
        case LayoutComponent.BUTTON_FAST_FORWARD_TOGGLE: out.turbo = rect; break;
        case LayoutComponent.BUTTON_PAUSE: out.pause = rect; break;
        case LayoutComponent.BUTTON_MORE: out.more = rect; break;
        default:
          // 无固定槽位的动作组件（慢速/快存/麦克风等）与宏按键进入通用渲染列表
          if (layoutComponentToAction(c.component) !== null ||
            c.component === LayoutComponent.BUTTON_MACRO) {
            extras.push(c);
          }
          break;
      }
    }
    this.extraActionComponents = extras;
    // 已存布局缺摇杆/C摇杆/Home 等编辑器新组件时回退算法结果，避免按键凭空消失
    if (!out.stick) out.stick = layout.stick;
    if (!out.cStick) out.cStick = layout.cStick;
    if (!out.home) out.home = layout.home;
    return out;
  }

  // @Builder 参数按值传递、首帧后不再求值：所有渲染都必须在 builder 体内经此读取最新矩形
  private rectFor(slot: string): PadRect {
    let rect: PadRect | null = null;
    switch (slot) {
      case 'l': rect = this.padLayout.l; break;
      case 'r': rect = this.padLayout.r; break;
      case 'zl': rect = this.padLayout.zl; break;
      case 'zr': rect = this.padLayout.zr; break;
      case 'dpad': rect = this.padLayout.dpad; break;
      case 'stick': rect = this.padLayout.stick; break;
      case 'cStick': rect = this.padLayout.cStick; break;
      case 'abxy': rect = this.padLayout.abxy; break;
      case 'select': rect = this.padLayout.select; break;
      case 'start': rect = this.padLayout.start; break;
      case 'home': rect = this.padLayout.home; break;
      case 'swap': rect = this.padLayout.swap; break;
      case 'turbo': rect = this.padLayout.turbo; break;
      case 'pause': rect = this.padLayout.pause; break;
      case 'more': rect = this.padLayout.more; break;
      default: break;
    }
    return rect ?? { x: 0, y: 0, w: 0, h: 0 };
  }

  /** 手柄摇杆当前是否在驱动该 3DS 摇杆（死区内为精确 0，非 0 即激活） */
  private externalStickActive(analog: AzaharAnalog): boolean {
    return analog === AzaharAnalog.CirclePad
      ? this.externalCirclePadX !== 0 || this.externalCirclePadY !== 0
      : this.externalCStickX !== 0 || this.externalCStickY !== 0;
  }

  private stickActive(analog: AzaharAnalog): boolean {
    const touchActive =
      analog === AzaharAnalog.CirclePad ? this.circlePadActive : this.cStickActive;
    return touchActive || this.externalStickActive(analog);
  }

  /** 摇杆显示值：触摸激活时优先触摸，否则跟随物理摇杆 */
  private stickAxisX(analog: AzaharAnalog): number {
    return analog === AzaharAnalog.CirclePad
      ? (this.circlePadActive ? this.circlePadOffsetX : this.externalCirclePadX)
      : (this.cStickActive ? this.cStickOffsetX : this.externalCStickX);
  }

  private stickAxisY(analog: AzaharAnalog): number {
    return analog === AzaharAnalog.CirclePad
      ? (this.circlePadActive ? this.circlePadOffsetY : this.externalCirclePadY)
      : (this.cStickActive ? this.cStickOffsetY : this.externalCStickY);
  }

  private stickCenterX(analog: AzaharAnalog): number {
    return analog === AzaharAnalog.CirclePad ? this.circlePadCenterOffsetX : this.cStickCenterOffsetX;
  }

  private stickCenterY(analog: AzaharAnalog): number {
    return analog === AzaharAnalog.CirclePad ? this.circlePadCenterOffsetY : this.cStickCenterOffsetY;
  }

  aboutToAppear(): void {
    this.refreshPadLayout();
  }

  private viewWidth(): number {
    return this.screenWidth > 0 ? this.screenWidth : 360;
  }

  private viewHeight(): number {
    const fallback = this.viewWidth() > 480 ? this.viewWidth() * 9 / 16 : this.viewWidth() * 16 / 9;
    return Math.max(1, this.screenHeight > 0 ? this.screenHeight : fallback);
  }

  private opacityValue(): number {
    return Math.max(0, Math.min(1, this.buttonOpacity / 100));
  }

  private disabledOpacity(): number {
    return this.disabled ? this.opacityValue() * 0.42 : this.opacityValue();
  }

  /** 按下视觉反馈：触摸按住 或 手柄映射后按住（externalPressedKeys，仅显示） */
  private isKeyPressed(key: AzaharKey): boolean {
    return this.pressedKeys.indexOf(key as number) >= 0 ||
      this.externalPressedKeys.indexOf(key as number) >= 0;
  }

  /** 触摸自身按住的按键（不含手柄外部态）：触摸处理的事件判定必须只看触摸持有的状态 */
  private isTouchKeyPressed(key: AzaharKey): boolean {
    return this.pressedKeys.indexOf(key as number) >= 0;
  }

  private setKeyPressed(key: AzaharKey, pressed: boolean): void {
    const value = key as number;
    if (pressed && this.pressedKeys.indexOf(value) < 0) {
      this.pressedKeys = [...this.pressedKeys, value];
      return;
    }
    if (!pressed) {
      this.pressedKeys = this.pressedKeys.filter((item: number) => item !== value);
    }
  }

  private isActionPressed(action: AzaharFrontendAction): boolean {
    return this.pressedActions.indexOf(action) >= 0;
  }

  private setActionPressed(action: AzaharFrontendAction, pressed: boolean): void {
    if (pressed && this.pressedActions.indexOf(action) < 0) {
      this.pressedActions = [...this.pressedActions, action];
      return;
    }
    if (!pressed) {
      this.pressedActions = this.pressedActions.filter((item: string) => item !== action);
    }
  }

  private onDisabledChanged(): void {
    if (this.disabled) {
      // 宏正按住时被禁用：先向 GameView 释放整组按键，防止持有者集合残留
      if (this.macroPressed) {
        this.onMacroKeys(this.macroKeys, false);
      }
      this.pressedKeys = [];
      this.pressedActions = [];
      this.macroPressed = false;
    }
  }

  private updateCompositeKeys(allKeys: AzaharKey[], nextKeys: AzaharKey[]): void {
    for (let i = 0; i < allKeys.length; i++) {
      const key = allKeys[i];
      const shouldPress = nextKeys.indexOf(key) >= 0;
      const pressed = this.isTouchKeyPressed(key);
      if (shouldPress && !pressed) {
        this.setKeyPressed(key, true);
        this.onKeyChange(key, true);
      } else if (!shouldPress && pressed) {
        this.setKeyPressed(key, false);
        this.onKeyChange(key, false);
      }
    }
  }

  private releaseDpadKeys(): void {
    this.updateCompositeKeys([AzaharKey.Up, AzaharKey.Down, AzaharKey.Left, AzaharKey.Right], []);
  }

  private handleDigitalTouch(event: TouchEvent, key: AzaharKey): void {
    event.stopPropagation();
    if (this.disabled) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.setKeyPressed(key, true);
      this.onKeyChange(key, true);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.setKeyPressed(key, false);
      this.onKeyChange(key, false);
    }
  }

  private handleActionTouch(event: TouchEvent, action: AzaharFrontendAction): void {
    event.stopPropagation();
    if (this.disabled) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.setActionPressed(action, true);
      this.onAction(action);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.setActionPressed(action, false);
    }
  }

  private handleDpadTouch(event: TouchEvent): void {
    event.stopPropagation();
    if (this.disabled || event.changedTouches.length < 1) {
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.releaseDpadKeys();
      return;
    }
    const touch = event.changedTouches[0];
    const size = this.padLayout.dpad ? this.padLayout.dpad.w : getOverlayControlSizes().dpad;
    const xAxis = (touch.x - size / 2) / (size / 2);
    const yAxis = (touch.y - size / 2) / (size / 2);
    const nextKeys: AzaharKey[] = [];
    if (yAxis < -0.5) {
      nextKeys.push(AzaharKey.Up);
    }
    if (yAxis > 0.5) {
      nextKeys.push(AzaharKey.Down);
    }
    if (xAxis < -0.5) {
      nextKeys.push(AzaharKey.Left);
    }
    if (xAxis > 0.5) {
      nextKeys.push(AzaharKey.Right);
    }
    this.updateCompositeKeys([AzaharKey.Up, AzaharKey.Down, AzaharKey.Left, AzaharKey.Right], nextKeys);
  }

  private stickVisualOffset(axis: number, size: number): number {
    return axis * size * 0.5;
  }

  @Builder
  AndroidButtonPx(resource: Resource, key: AzaharKey, slot: string) {
    Image(resource)
      .width(this.rectFor(slot).w)
      .height(this.rectFor(slot).h)
      .objectFit(ImageFit.Fill)
      .draggable(false)
      .opacity(this.disabledOpacity())
      .position({ x: this.rectFor(slot).x, y: this.rectFor(slot).y })
      .scale({
        x: this.isKeyPressed(key) ? TOUCH_SCALE_FACTOR : 1,
        y: this.isKeyPressed(key) ? TOUCH_SCALE_FACTOR : 1,
        centerX: '50%',
        centerY: '50%'
      })
      .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        this.handleDigitalTouch(event, key);
      })
  }

  /** 固定槽位动作键：动作与素材都在 builder 体内读取（@Builder 参数按值冻结，状态素材不能走参数） */
  private slotAction(slot: string): AzaharFrontendAction {
    switch (slot) {
      case 'swap': return 'swap_screens';
      case 'pause': return 'pause';
      case 'more': return 'more';
      default: return 'fast_forward';
    }
  }

  private slotActionImage(slot: string): Resource {
    switch (slot) {
      case 'swap': return $rawfile('themes/default/button_swap_screens.png');
      case 'pause': return $rawfile('themes/default/button_pause.png');
      case 'more': return $rawfile('themes/default/button_more.png');
      default:
        return this.fastForwardActive
          ? $rawfile('themes/default/button_fast_forward.png')
          : $rawfile('themes/default/button_fast_forward_disabled.png');
    }
  }

  /** 扩展动作组件的素材：开关类按当前状态切启用/停用图（对齐 nds More 菜单与放置按钮的状态素材） */
  private extraActionImage(component: LayoutComponent): string {
    switch (component) {
      case LayoutComponent.BUTTON_SLOW_MOTION_TOGGLE:
        return this.slowMotionActive ? 'button_slow_motion.png' : 'button_slow_motion_disabled.png';
      case LayoutComponent.BUTTON_TOGGLE_SOFT_INPUT:
        return this.showOverlay ? 'ic_touch_enabled.png' : 'ic_touch_disabled.png';
      case LayoutComponent.BUTTON_MICROPHONE_TOGGLE:
        return this.microphoneActive ? 'button_microphone.png' : 'button_microphone_disabled.png';
      default:
        return getComponentImageName(component);
    }
  }

  private extraActionOf(component: LayoutComponent): AzaharFrontendAction {
    return layoutComponentToAction(component) ?? 'pause';
  }

  private extraRectOf(component: LayoutComponent): PadRect {
    const found = this.extraActionComponents.find((c: PositionedLayoutComponent) => c.component === component);
    return found
      ? { x: found.rect.x, y: found.rect.y, w: found.rect.width, h: found.rect.height }
      : { x: 0, y: 0, w: 0, h: 0 };
  }

  private hasSoftInputToggleExtra(): boolean {
    return this.extraActionComponents.some(
      (c: PositionedLayoutComponent) => c.component === LayoutComponent.BUTTON_TOGGLE_SOFT_INPUT);
  }

  private softInputExtraComponents(): PositionedLayoutComponent[] {
    return this.extraActionComponents.filter(
      (c: PositionedLayoutComponent) => c.component === LayoutComponent.BUTTON_TOGGLE_SOFT_INPUT);
  }

  @Builder
  PadActionButton(slot: string) {
    Image(this.slotActionImage(slot))
      .width(this.rectFor(slot).w)
      .height(this.rectFor(slot).h)
      .objectFit(ImageFit.Fill)
      .draggable(false)
      .opacity(this.disabledOpacity())
      .position({ x: this.rectFor(slot).x, y: this.rectFor(slot).y })
      .scale({
        x: this.isActionPressed(this.slotAction(slot)) ? TOUCH_SCALE_FACTOR : 1,
        y: this.isActionPressed(this.slotAction(slot)) ? TOUCH_SCALE_FACTOR : 1,
        centerX: '50%',
        centerY: '50%'
      })
      .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        this.handleActionTouch(event, this.slotAction(slot));
      })
  }

  @Builder
  ExtraActionButton(component: LayoutComponent) {
    Image($rawfile(`themes/default/${this.extraActionImage(component)}`))
      .width(this.extraRectOf(component).w)
      .height(this.extraRectOf(component).h)
      .objectFit(ImageFit.Fill)
      .draggable(false)
      .opacity(this.disabledOpacity())
      .position({ x: this.extraRectOf(component).x, y: this.extraRectOf(component).y })
      .scale({
        x: this.isActionPressed(this.extraActionOf(component)) ? TOUCH_SCALE_FACTOR : 1,
        y: this.isActionPressed(this.extraActionOf(component)) ? TOUCH_SCALE_FACTOR : 1,
        centerX: '50%',
        centerY: '50%'
      })
      .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        this.handleActionTouch(event, this.extraActionOf(component));
      })
  }

  /** 宏按键：渲染与 ExtraActionButton 一致，但触摸走 key 组上报而非动作 */
  @Builder
  MacroButton(component: LayoutComponent) {
    Image($rawfile('themes/default/button_macro.png'))
      .width(this.extraRectOf(component).w)
      .height(this.extraRectOf(component).h)
      .objectFit(ImageFit.Fill)
      .draggable(false)
      .opacity(this.disabledOpacity())
      .position({ x: this.extraRectOf(component).x, y: this.extraRectOf(component).y })
      .scale({
        x: this.macroPressed ? TOUCH_SCALE_FACTOR : 1,
        y: this.macroPressed ? TOUCH_SCALE_FACTOR : 1,
        centerX: '50%',
        centerY: '50%'
      })
      .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        this.handleMacroTouch(event);
      })
  }

  private handleMacroTouch(event: TouchEvent): void {
    event.stopPropagation();
    if (this.disabled || this.macroKeys.length === 0) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.macroPressed = true;
      this.onMacroKeys(this.macroKeys, true);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.macroPressed = false;
      this.onMacroKeys(this.macroKeys, false);
    }
  }

  @Builder
  DpadImage(slot: string) {
    // 整体方向键 3D 倾斜：按下哪个方向，方向键就向那个方向倾倒（被按入屏幕）
    // 外层 Stack 处理 X 轴（UP/DOWN）倾斜，内层处理 Y 轴（LEFT/RIGHT），对角按下两轴叠加
    Stack() {
      Stack() {
        Image($rawfile('themes/default/keypad.png'))
          .width(this.rectFor(slot).w)
          .height(this.rectFor(slot).h)
          .objectFit(ImageFit.Fill)
          .draggable(false)
          .hitTestBehavior(HitTestMode.None)
      }
      .width(this.rectFor(slot).w)
      .height(this.rectFor(slot).h)
      .rotate({
        x: 0, y: 1, z: 0,
        angle: (this.isKeyPressed(AzaharKey.Left) ? -DPAD_TILT_ANGLE : 0) +
          (this.isKeyPressed(AzaharKey.Right) ? DPAD_TILT_ANGLE : 0),
        centerX: '50%', centerY: '50%',
        perspective: DPAD_TILT_PERSPECTIVE
      })
      .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
    }
    .width(this.rectFor(slot).w)
    .height(this.rectFor(slot).h)
    .rotate({
      x: 1, y: 0, z: 0,
      angle: (this.isKeyPressed(AzaharKey.Up) ? DPAD_TILT_ANGLE : 0) +
        (this.isKeyPressed(AzaharKey.Down) ? -DPAD_TILT_ANGLE : 0),
      centerX: '50%', centerY: '50%',
      perspective: DPAD_TILT_PERSPECTIVE
    })
    .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
    .opacity(this.disabledOpacity())
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  AbxyButtonImage(spec: AbxyButtonSpec, file: string, key: AzaharKey, slot: string) {
    // spec.ccx/ccy 是 PNG 有效内容中心在自身画布中的归一化位置：
    // 让"内容中心"落在 spec.cx/cy 处，避免内容偏移的素材摆歪
    Image($rawfile(`themes/default/${file}`))
      .width(this.rectFor(slot).w * spec.s)
      .height(this.rectFor(slot).w * spec.s)
      .objectFit(ImageFit.Fill)
      .draggable(false)
      .opacity(this.disabledOpacity())
      .position({
        x: this.rectFor(slot).w * (spec.cx - spec.ccx * spec.s),
        y: this.rectFor(slot).w * (spec.cy - spec.ccy * spec.s)
      })
      .scale({
        x: this.isKeyPressed(key) ? TOUCH_SCALE_FACTOR : 1,
        y: this.isKeyPressed(key) ? TOUCH_SCALE_FACTOR : 1,
        centerX: spec.ccx * this.rectFor(slot).w * spec.s,
        centerY: spec.ccy * this.rectFor(slot).w * spec.s
      })
      .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        this.handleDigitalTouch(event, key);
      })
  }

  @Builder
  AbxyCluster(slot: string) {
    // ABXY 四键拼接簇：不要底衬整图，四张单键素材按主题几何摆放
    Stack() {
      this.AbxyButtonImage(getThemeAbxy('default').x, 'buttons_X.png', AzaharKey.X, slot)
      this.AbxyButtonImage(getThemeAbxy('default').y, 'buttons_Y.png', AzaharKey.Y, slot)
      this.AbxyButtonImage(getThemeAbxy('default').a, 'buttons_A.png', AzaharKey.A, slot)
      this.AbxyButtonImage(getThemeAbxy('default').b, 'buttons_B.png', AzaharKey.B, slot)
    }
    .width(this.rectFor(slot).w)
    .height(this.rectFor(slot).h)
    .position({ x: this.rectFor(slot).x, y: this.rectFor(slot).y })
    .hitTestBehavior(HitTestMode.Transparent)
    .clip(false)
  }

  @Builder
  AndroidDpad(slot: string) {
    Stack({ alignContent: Alignment.Center }) {
      this.DpadImage(slot)
    }
    .width(this.rectFor(slot).w)
    .height(this.rectFor(slot).h)
    .position({ x: this.rectFor(slot).x, y: this.rectFor(slot).y })
    .onTouch((event: TouchEvent) => {
      this.handleDpadTouch(event);
    })
  }

  @Builder
  AndroidStick(rangeResource: Resource, defaultResource: Resource,
    analog: AzaharAnalog, slot: string) {
    Stack({ alignContent: Alignment.Center }) {
      Image(rangeResource)
        .width(this.rectFor(slot).w)
        .height(this.rectFor(slot).h)
        .objectFit(ImageFit.Fill)
        .draggable(false)
        .opacity(this.stickActive(analog) ? 0 : this.disabledOpacity())
        .hitTestBehavior(HitTestMode.None)

      Image(rangeResource)
        .width(this.rectFor(slot).w)
        .height(this.rectFor(slot).h)
        .objectFit(ImageFit.Fill)
        .draggable(false)
        .opacity(this.stickActive(analog) && !this.disabled ? this.opacityValue() : 0)
        .translate({ x: this.stickCenterX(analog), y: this.stickCenterY(analog) })
        .hitTestBehavior(HitTestMode.None)

      Image(defaultResource)
        .width(this.rectFor(slot).w)
        .height(this.rectFor(slot).h)
        .objectFit(ImageFit.Fill)
        .draggable(false)
        .opacity(this.disabledOpacity())
        .translate({
          x: this.stickCenterX(analog) + this.stickVisualOffset(this.stickAxisX(analog), this.rectFor(slot).w),
          y: this.stickCenterY(analog) + this.stickVisualOffset(this.stickAxisY(analog), this.rectFor(slot).w)
        })
        .hitTestBehavior(HitTestMode.None)
    }
    .width(this.rectFor(slot).w)
    .height(this.rectFor(slot).h)
    .clip(false)
    .position({ x: this.rectFor(slot).x, y: this.rectFor(slot).y })
    .onTouch((event: TouchEvent) => {
      event.stopPropagation();
      if (!this.disabled) {
        this.onAnalogTouch(event, analog);
      }
    })
  }

  build() {
    Stack() {
      if (this.showOverlay) {
        if (this.padLayout.l) {
          this.AndroidButtonPx($rawfile('themes/default/button_l.png'), AzaharKey.L, 'l')
        }
        if (this.padLayout.r) {
          this.AndroidButtonPx($rawfile('themes/default/button_r.png'), AzaharKey.R, 'r')
        }
        if (this.padLayout.zl) {
          this.AndroidButtonPx($rawfile('themes/default/button_zl.png'), AzaharKey.ZL, 'zl')
        }
        if (this.padLayout.zr) {
          this.AndroidButtonPx($rawfile('themes/default/button_zr.png'), AzaharKey.ZR, 'zr')
        }

        if (this.padLayout.dpad) {
          this.AndroidDpad('dpad')
        }
        if (this.padLayout.stick) {
          this.AndroidStick($rawfile('themes/default/stick_main_range.png'), $rawfile('themes/default/stick_main.png'),
            AzaharAnalog.CirclePad, 'stick')
        }
        if (this.padLayout.cStick) {
          this.AndroidStick($rawfile('themes/default/stick_c_range.png'), $rawfile('themes/default/stick_c.png'),
            AzaharAnalog.CStick, 'cStick')
        }

        if (this.padLayout.abxy) {
          this.AbxyCluster('abxy')
        }

        if (this.padLayout.select) {
          this.AndroidButtonPx($rawfile('themes/default/button_select.png'), AzaharKey.Select, 'select')
        }
        if (this.padLayout.start) {
          this.AndroidButtonPx($rawfile('themes/default/button_start.png'), AzaharKey.Start, 'start')
        }
        if (this.padLayout.home) {
          this.AndroidButtonPx($rawfile('themes/default/button_home.png'), AzaharKey.Home, 'home')
        }
        if (this.padLayout.swap) {
          this.PadActionButton('swap')
        }
        if (this.padLayout.pause) {
          this.PadActionButton('pause')
        }
        if (this.padLayout.more) {
          this.PadActionButton('more')
        }
        if (this.padLayout.turbo) {
          this.PadActionButton('turbo')
        }

        // 自定义布局中无固定槽位的动作组件（慢速/快存/麦克风/宏按键等）
        ForEach(this.extraActionComponents, (c: PositionedLayoutComponent) => {
          if (c.component === LayoutComponent.BUTTON_MACRO) {
            this.MacroButton(c.component)
          } else {
            this.ExtraActionButton(c.component)
          }
        }, (c: PositionedLayoutComponent) => c.component)
      } else if (!this.hideRecoveryEntry) {
        // 触控层隐藏时的恢复入口（对齐 nds）：已放置触控开关就只渲染它，否则保留更多键；
        // always_invisible 语义是"完全无触控 UI"，此时连恢复入口也不渲染
        if (this.hasSoftInputToggleExtra()) {
          ForEach(this.softInputExtraComponents(), (c: PositionedLayoutComponent) => {
            this.ExtraActionButton(c.component)
          }, (c: PositionedLayoutComponent) => c.component)
        } else if (this.padLayout.more) {
          this.PadActionButton('more')
        }
      }
    }
    .width('100%')
    .height('100%')
    .opacity(this.disabled ? 0.42 : 1)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}

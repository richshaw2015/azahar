import { SEGMENT_BAR_HEIGHT } from '../../types/UIConstants';
import { SettingsContentPage } from '../../components/settings/SettingsContentPage';
import {
  GamepadSettingsContent, GamepadSegmentBar, GamepadCaptureState, GamepadFocusAxisState, GamepadArkKeyState,
  GAMEPAD_TAB_MAPPING, GAMEPAD_TAB_TEST
} from '../../components/settings/content/GamepadSettingsContent';
import { I18n } from '../../utils/I18nManager';
import { PAGE_TRANSITION_DURATION } from '../../utils/PageTransitionHelper';
import { gamepadBackHandler, GAMEPAD_B, isGamepadKey } from '../../utils/GamepadUIHelper';

@Entry
@Component
struct GamepadSettings {
  private pageScroller: Scroller = new Scroller();
  private pageBackHandler: (event: KeyEvent) => void = gamepadBackHandler();
  @State gamepadTab: number = GAMEPAD_TAB_MAPPING;

  @Builder
  GamepadTabBar() {
    GamepadSegmentBar({
      selectedIndex: this.gamepadTab,
      onSelect: (index: number) => {
        this.gamepadTab = index;
        this.pageScroller.scrollEdge(Edge.Top);
      }
    })
  }

  build() {
    Column() {
      SettingsContentPage({
        title: I18n.t('settings_gamepad'),
        scrollers: [this.pageScroller],
        bottomBuilder: () => {
          this.GamepadTabBar();
        },
        bottomBuilderHeight: SEGMENT_BAR_HEIGHT
      }) {
        GamepadSettingsContent({
          scroller: this.pageScroller,
          selectedTab: this.gamepadTab
        })
      }
    }
    .width('100%')
    .height('100%')
    // 手柄十字键与摇杆走 FocusAxisEvent 通道（不是 KeyEvent），沿焦点链冒泡到页面根；
    // 测试 tab 消费掉以免触发走焦，数据照常记录给示波器兜底
    .onFocusAxisEvent((event: FocusAxisEvent) => {
      GamepadFocusAxisState.record(event);
      if (this.gamepadTab === GAMEPAD_TAB_TEST) {
        event.stopPropagation();
      }
    })
    // 键盘类十字键码走 KeyEvent 分发：onKeyEvent 是冒泡阶段拦不住焦点导航，
    // 必须在 onKeyPreIme 分发前消费（返回 true 拦截后续所有回调与系统处理）。
    // 同时把按键沿记入 ArkUI 通道状态：Mode(2313) 等键码无 GCK 监视器，
    // 测试器/捕获只能从这里收到
    .onKeyPreIme((event: KeyEvent) => {
      // 捕获态下键盘键码也要入边队列：统一捕获靠 pad 标记区分键盘/手柄来源
      if (!isGamepadKey(event.keyCode) && !GamepadCaptureState.active) {
        return false;
      }
      GamepadArkKeyState.record(event.keyCode, event.type === KeyType.Down,
        GamepadArkKeyState.isGamepadSource(event));
      return this.gamepadTab === GAMEPAD_TAB_TEST || GamepadCaptureState.active;
    })
    .onKeyEvent((event: KeyEvent) => {
      if (isGamepadKey(event.keyCode) || GamepadCaptureState.active) {
        GamepadArkKeyState.record(event.keyCode, event.type === KeyType.Down,
          GamepadArkKeyState.isGamepadSource(event));
      }
      // 测试 tab：手柄按键只用于检测，吞掉以免移动焦点/点击/返回
      if (this.gamepadTab === GAMEPAD_TAB_TEST && isGamepadKey(event.keyCode)) {
        event.stopPropagation();
        return;
      }
      if (event.type !== KeyType.Down || event.keyCode !== GAMEPAD_B) {
        return;
      }
      // 捕获中 B 是合法绑定目标，不触发返回
      if (GamepadCaptureState.active) {
        event.stopPropagation();
        return;
      }
      this.pageBackHandler(event);
    })
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
    PageTransitionEnter({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
  }
}

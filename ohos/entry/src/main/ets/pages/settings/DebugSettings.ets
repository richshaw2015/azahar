import { SettingsContentPage } from '../../components/settings/SettingsContentPage';
import { DebugSettingsContent } from '../../components/settings/content/DebugSettingsContent';
import { I18n } from '../../utils/I18nManager';
import { PAGE_TRANSITION_DURATION } from '../../utils/PageTransitionHelper';
import { gamepadBackHandler } from '../../utils/GamepadUIHelper';

@Entry
@Component
struct DebugSettings {
  private pageScroller: Scroller = new Scroller();

  build() {
    Column() {
      SettingsContentPage({
        title: I18n.t('settings_debug'),
        scrollers: [this.pageScroller]
      }) {
        DebugSettingsContent({ scroller: this.pageScroller })
      }
    }
    .width('100%')
    .height('100%')
    .onKeyEvent(gamepadBackHandler())
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
    PageTransitionEnter({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
  }
}

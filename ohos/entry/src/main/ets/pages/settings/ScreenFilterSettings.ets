import { SettingsContentPage } from '../../components/settings/SettingsContentPage';
import { ScreenFilterSettingsContent } from '../../components/settings/content/ScreenFilterSettingsContent';
import { I18n } from '../../utils/I18nManager';
import { PAGE_TRANSITION_DURATION } from '../../utils/PageTransitionHelper';
import { gamepadBackHandler } from '../../utils/GamepadUIHelper';

@Entry
@Component
struct ScreenFilterSettings {
  private pageScroller: Scroller = new Scroller();

  build() {
    Column() {
      SettingsContentPage({
        title: I18n.t('settings_screen_filter'),
        scrollers: [this.pageScroller]
      }) {
        ScreenFilterSettingsContent({ scroller: this.pageScroller })
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

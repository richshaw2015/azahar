import { SettingsContentPage } from '../../components/settings/SettingsContentPage';
import { AboutSettingsContent } from '../../components/settings/content/AboutSettingsContent';
import { gamepadBackHandler } from '../../utils/GamepadUIHelper';
import { I18n } from '../../utils/I18nManager';
import { PAGE_TRANSITION_DURATION } from '../../utils/PageTransitionHelper';

@Entry
@Component
struct AboutSettings {
  private pageScroller: Scroller = new Scroller();

  build() {
    Column() {
      SettingsContentPage({
        title: I18n.t('about'),
        backgroundAnimationEnabled: true,
        scrollers: [this.pageScroller]
      }) {
        AboutSettingsContent({ scroller: this.pageScroller })
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

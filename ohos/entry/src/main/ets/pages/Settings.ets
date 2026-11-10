import { router, ComposeListItem, IconType, SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsNavigation, HdsNavDestination, HdsNavigationTitleMode, BottomBuilderShowType, hdsMaterial, ScrollEffectType } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { GlobalWallpaper } from '../components/common/GlobalWallpaper';
import { AzaharNavPage } from '../components/common/AzaharNavPage';
import { menuGroupMargin, menuGroupPadding, settingsGroupDivider } from '../components/settings/SettingsList';
import { AboutSettingsContent } from '../components/settings/content/AboutSettingsContent';
import { AppearanceSettingsContent } from '../components/settings/content/AppearanceSettingsContent';
import { AudioSettingsContent } from '../components/settings/content/AudioSettingsContent';
import { CoreSettingsContent } from '../components/settings/content/CoreSettingsContent';
import { DebugSettingsContent } from '../components/settings/content/DebugSettingsContent';
import { DisplaySettingsContent } from '../components/settings/content/DisplaySettingsContent';
import { GraphicsSettingsContent } from '../components/settings/content/GraphicsSettingsContent';
import { NetworkSettingsContent } from '../components/settings/content/NetworkSettingsContent';
import { GamepadSettingsContent, GamepadSegmentBar, GamepadArkKeyState, GamepadCaptureState, GamepadFocusAxisState, GAMEPAD_TAB_MAPPING, GAMEPAD_TAB_TEST } from '../components/settings/content/GamepadSettingsContent';
import { StorageSettingsContent } from '../components/settings/content/StorageSettingsContent';
import { FloatTilesBackground } from '../components/theme/FloatTilesBackground';
import { navBackIconModifier, NAV_TITLE_SCROLL_SPACE, SEGMENT_BAR_HEIGHT, TEXT_DANGER, TEXT_SECONDARY } from '../types/UIConstants';
import { AzaharTheme, AzaharThemeColors, AzaharThemeId } from '../types/ThemeTypes';
import { GLOBAL_WALLPAPER_URI_KEY } from '../types/SettingsTypes';
import { AppIconManager } from '../utils/AppIconManager';
import { DeviceProfile } from '../utils/DeviceProfile';
import { gamepadBackHandler, GAMEPAD_B, isGamepadKey } from '../utils/GamepadUIHelper';
import { I18n } from '../utils/I18nManager';
import { PAGE_TRANSITION_DURATION } from '../utils/PageTransitionHelper';
import { SafeAreaHelper } from '../utils/SafeAreaHelper';
import { SettingsManager } from '../utils/SettingsManager';
import { createScrollSource, setScrollSourceActive } from '../utils/ScrollAnimationState';
import { SoundEffect, SoundEffectManager } from '../utils/SoundEffectManager';
import { ThemeManager } from '../utils/ThemeManager';
import { initToastHelper, showErrorToast, showSuccessToast } from '../utils/ToastHelper';
import { listCardBgOf } from '../utils/ThemeSurfaces';

type SettingsCategoryKey = 'appearance' | 'core' | 'gamepad' | 'graphics' | 'display' | 'audio' | 'storage' | 'network' | 'debug' | 'about';

interface SettingsCategory {
  key: SettingsCategoryKey;
  title: string;
  description: string;
  route: string;
  icon: Resource;
}

const WIDE_SCREEN_BREAKPOINT: number = 640;

AppStorage.setOrCreate('globalWallpaperUri', '');
AppStorage.setOrCreate('globalWallpaperVersion', 0);

@Entry
@Component
struct Settings {
  @State themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();
  @State selectedCategoryKey: SettingsCategoryKey = 'appearance';
  @State gamepadTab: number = GAMEPAD_TAB_MAPPING;
  @State settingsWidth: number = 0;
  @StorageLink('globalWallpaperUri') wallpaperUri: string = '';
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;
  @StorageLink('safeAreaTopVp') safeAreaTopVp: number = 0;

  private navPathStack: NavPathStack = new NavPathStack();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private pageScroller: Scroller = new Scroller();
  private detailScroller: Scroller = new Scroller();
  private pageBackHandler: (event: KeyEvent) => void = gamepadBackHandler();
  private pageScrollSourceId: number = createScrollSource();
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private themeManager: ThemeManager = ThemeManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private themeChangeListener: ((theme: AzaharTheme) => void) | null = null;

  async aboutToAppear(): Promise<void> {
    initToastHelper(this.getUIContext());
    await this.soundEffectManager.initialize(this.context);
    SafeAreaHelper.refresh();
    await this.loadSettings();
    this.ensureNavPath();
  }

  onPageShow(): void {
    // 从子页/游戏返回时窗口避让区可能已变化，重测一次
    SafeAreaHelper.refresh();
  }

  aboutToDisappear(): void {
    setScrollSourceActive(this.pageScrollSourceId, false);
    if (this.themeChangeListener) {
      this.themeManager.removeListener(this.themeChangeListener);
      this.themeChangeListener = null;
    }
  }

  private async loadSettings(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    await this.themeManager.initialize(this.context);
    this.refreshThemeState();
    this.wallpaperUri = this.settingsManager.getString(GLOBAL_WALLPAPER_URI_KEY);
    if (!this.themeChangeListener) {
      this.themeChangeListener = (_theme: AzaharTheme) => {
        this.refreshThemeState();
      };
      this.themeManager.addListener(this.themeChangeListener);
    }
  }

  private refreshThemeState(): void {
    this.themeColors = this.themeManager.getCurrentColors();
  }

  private getCategories(): SettingsCategory[] {
    return [
      { key: 'appearance', title: I18n.t('settings_appearance'), description: I18n.t('settings_appearance_desc'), route: 'pages/settings/AppearanceSettings', icon: $r('sys.symbol.sun_max') },
      { key: 'display', title: I18n.t('settings_display'), description: I18n.t('settings_display_desc'), route: 'pages/settings/DisplaySettings', icon: $r('sys.symbol.hand_tap') },
      { key: 'gamepad', title: I18n.t('settings_gamepad'), description: I18n.t('settings_gamepad_desc'), route: 'pages/settings/GamepadSettings', icon: $r('sys.symbol.gamecontroller') },
      { key: 'graphics', title: I18n.t('settings_graphics'), description: I18n.t('settings_graphics_desc'), route: 'pages/settings/GraphicsSettings', icon: $r('sys.symbol.picture') },
      { key: 'audio', title: I18n.t('settings_audio'), description: I18n.t('settings_audio_desc'), route: 'pages/settings/AudioSettings', icon: $r('sys.symbol.speaker_wave_2') },
      { key: 'core', title: I18n.t('settings_core'), description: I18n.t('settings_core_desc'), route: 'pages/settings/CoreSettings', icon: $r('sys.symbol.hardware') },
      { key: 'storage', title: I18n.t('settings_storage'), description: I18n.t('settings_storage_desc'), route: 'pages/settings/StorageSettings', icon: $r('sys.symbol.folder') },
      { key: 'network', title: I18n.t('settings_network'), description: I18n.t('settings_network_desc'), route: 'pages/settings/NetworkSettings', icon: $r('sys.symbol.wifi') },
      { key: 'debug', title: I18n.t('settings_debug'), description: I18n.t('settings_debug_desc'), route: 'pages/settings/DebugSettings', icon: $r('sys.symbol.wrench_and_screwdriver') },
      { key: 'about', title: I18n.t('about'), description: I18n.t('about_desc'), route: 'pages/settings/AboutSettings', icon: $r('sys.symbol.info_circle') }
    ];
  }

  private isSelectedCategory(key: SettingsCategoryKey): boolean {
    return this.selectedCategoryKey === key;
  }

  private isWideScreenMode(): boolean {
    return this.settingsWidth >= WIDE_SCREEN_BREAKPOINT;
  }

  // 分栏详情当前展示的是手柄设置测试 tab：该 tab 消费全部手柄输入，
  // 不触发走焦/点击/返回（与独立 GamepadSettings 页一致）
  private isInSplitGamepadTest(): boolean {
    return this.isWideScreenMode() && this.selectedCategoryKey === 'gamepad' &&
      this.gamepadTab === GAMEPAD_TAB_TEST;
  }

  private selectGamepadTab(index: number): void {
    this.gamepadTab = index;
    this.detailScroller.scrollEdge(Edge.Top);
  }

  private hasInlineDetail(key: SettingsCategoryKey): boolean {
    return key === 'appearance' || key === 'core' || key === 'gamepad' || key === 'graphics' ||
      key === 'display' || key === 'audio' || key === 'storage' || key === 'network' || key === 'debug' || key === 'about';
  }

  private ensureNavPath(): void {
    if (this.navPathStack.size() === 0 && this.hasInlineDetail(this.selectedCategoryKey)) {
      this.navPathStack.pushPath({ name: this.selectedCategoryKey }, false);
    }
  }

  private handleBack(): void {
    this.soundEffectManager.play(SoundEffect.BACK);
    router.back();
  }

  private selectCategory(category: SettingsCategory): void {
    this.soundEffectManager.play(this.isWideScreenMode() ? SoundEffect.SELECT : SoundEffect.DECIDE);
    if (this.isWideScreenMode() && this.hasInlineDetail(category.key)) {
      if (this.selectedCategoryKey !== category.key) {
        this.selectedCategoryKey = category.key;
        this.navPathStack.clear();
        this.navPathStack.pushPath({ name: category.key }, false);
      }
      return;
    }
    this.openCategoryRoute(category);
  }

  private openCategoryRoute(category: SettingsCategory): void {
    router.pushUrl({ url: category.route }).catch((error: Error) => {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('open_failed_fmt', 'error', error.message));
    });
  }

  private confirmResetAllSettings(): void {
    this.getUIContext().showAlertDialog({
      title: I18n.t('reset_all_settings'),
      message: I18n.t('reset_all_settings_description'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: I18n.t('confirm'),
        fontColor: TEXT_DANGER,
        action: () => {
          this.soundEffectManager.play(SoundEffect.CONFIRM);
          this.resetAllSettings();
        }
      },
      secondaryButton: {
        value: I18n.t('cancel'),
        fontColor: this.themeManager.getControlAccent(),
        action: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
        }
      },
      cancel: () => {
        this.soundEffectManager.play(SoundEffect.BACK);
      }
    });
  }

  // Android 在设置根列表放「恢复默认」RunnableSetting；根页保留同款入口。
  // 除清空偏好外，还要把已加载进内存的主题、深浅色、图标样式和壁纸一并复位，
  // 否则按下后界面仍保持旧样式，看起来像没生效。
  private async resetAllSettings(): Promise<void> {
    await this.settingsManager.resetAll();
    this.settingsManager.syncNativeSettings(DeviceProfile.getDeviceType());
    await this.themeManager.setTheme(AzaharThemeId.Orange);
    await this.themeManager.setColorMode('auto');
    this.wallpaperUri = '';
    AppIconManager.getInstance().refreshStyleProp();
    this.refreshThemeState();
    this.soundEffectManager.play(SoundEffect.CONFIRM);
    showSuccessToast(I18n.t('settings_reset_done'));
  }

  @Builder
  CategoryListItem(category: SettingsCategory) {
    ComposeListItem({
      contentItem: {
        iconStyle: IconType.SYSTEM_ICON,
        icon: category.icon,
        symbolStyle: new SymbolGlyphModifier(category.icon).fontColor([TEXT_SECONDARY]),
        primaryText: category.title,
        secondaryText: category.description
      },
      operateItem: (!this.isWideScreenMode() || !this.hasInlineDetail(category.key)) ? {
        arrow: {
          value: $r('sys.symbol.chevron_right')
        }
      } : undefined
    })
    // 外层 ListItem 收了 4vp 外边距（让 .selected 与按压高亮同区域），
    // 这里用 -4vp 负边距把 ComposeListItem 推回原几何，行内容/按压区不随 item 收缩
    .margin({ left: -4, right: -4 })
    .onFocus(() => {
      this.soundEffectManager.play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      this.selectCategory(category);
    })
  }

  @Builder
  CategoryList() {
    List({ scroller: this.pageScroller }) {
      // 顶部占位: 垫出悬浮标题栏高度；不能用 contentStartOffset——它会让滚动总偏移从负值起步，
      // 标题栏 GRADIENT_BLUR 要滚过整段偏移才生效
      ListItem() {
        Column() {
        }
        .width('100%')
        .height(this.safeAreaTopVp + NAV_TITLE_SCROLL_SPACE)
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ForEach(this.getCategories(), (category: SettingsCategory) => {
          // .selected 系统样式画在 item 满宽矩形、按压高亮在 ComposeListItem 内部左缩 4vp 的区域，
          // 两者几何天然对不齐。解法：item 收 4vp 外边距让 selected 矩形=原按压区，
          // 再给 ComposeListItem 负边距把它推回原位——两态高亮落在同一矩形上
          ListItem() {
            this.CategoryListItem(category)
          }
          .selected(this.isWideScreenMode() && this.isSelectedCategory(category.key))
          .margin({ left: 4, right: 4 })
          .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
          .clip(true)
        }, (category: SettingsCategory) => category.key)
      }
      .backgroundColor(listCardBgOf(this.themeColors))
      .padding(menuGroupPadding())
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 「恢复默认设置」是全局动作，独立成卡：与分类导航行同卡会误导成普通跳转项
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ComposeListItem({
            contentItem: {
              iconStyle: IconType.SYSTEM_ICON,
              icon: $r('sys.symbol.arrow_clockwise'),
              symbolStyle: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise')).fontColor([TEXT_SECONDARY]),
              primaryText: I18n.t('reset_to_default')
            },
            operateItem: {
              arrow: {
                value: $r('sys.symbol.chevron_right')
              }
            }
          })
          .onFocus(() => {
            this.soundEffectManager.play(SoundEffect.FOCUS);
          })
          .onClick(() => {
            this.soundEffectManager.play(SoundEffect.DECIDE);
            this.confirmResetAllSettings();
          })
        }
      }
      .backgroundColor(listCardBgOf(this.themeColors))
      .padding(menuGroupPadding())

      ListItem() {
        Column() {
        }
        .width('100%')
        .height(16 + this.safeAreaBottomVp)
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
    .onScrollStart(() => setScrollSourceActive(this.pageScrollSourceId, true))
    .onScrollStop(() => setScrollSourceActive(this.pageScrollSourceId, false))
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
  }

  private detailTitleFor(name: string): string {
    const found = this.getCategories().find((category: SettingsCategory) => category.key === name);
    return found ? found.title : '';
  }

  @Builder
  DetailContent(name: string) {
    if (name === 'appearance') {
      AppearanceSettingsContent({ scroller: this.detailScroller })
    } else if (name === 'core') {
      CoreSettingsContent({ scroller: this.detailScroller })
    } else if (name === 'gamepad') {
      GamepadSettingsContent({ scroller: this.detailScroller, selectedTab: this.gamepadTab })
    } else if (name === 'graphics') {
      GraphicsSettingsContent({ scroller: this.detailScroller })
    } else if (name === 'display') {
      DisplaySettingsContent({ scroller: this.detailScroller })
    } else if (name === 'audio') {
      AudioSettingsContent({ scroller: this.detailScroller })
    } else if (name === 'storage') {
      StorageSettingsContent({ scroller: this.detailScroller })
    } else if (name === 'network') {
      NetworkSettingsContent({ scroller: this.detailScroller })
    } else if (name === 'debug') {
      DebugSettingsContent({ scroller: this.detailScroller })
    } else if (name === 'about') {
      AboutSettingsContent({ scroller: this.detailScroller })
    }
  }

  @Builder
  GamepadTabBar() {
    GamepadSegmentBar({
      selectedIndex: this.gamepadTab,
      onSelect: (index: number) => {
        this.selectGamepadTab(index);
      }
    })
  }

  @Builder
  SettingsNavDestination(name: string, _param: Object) {
    HdsNavDestination() {
      Column() {
        this.DetailContent(name)
      }
      .width('100%')
      .height('100%')
      .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end') })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    }
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleBar({
      content: {
        title: { mainTitle: this.detailTitleFor(name) },
        // 分栏下详情页复用独立页的标题栏分段控件；内容区顶部垫高已含 SEGMENT_BAR_HEIGHT
        bottomBuilder: name === 'gamepad' ? {
          builder: () => {
            this.GamepadTabBar();
          },
          height: SEGMENT_BAR_HEIGHT,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        } : undefined
      },
      style: {
        scrollEffectOpts: {
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false
    })
    .hideBackButton(true)
    .hideToolBar(true)
    .backgroundColor(Color.Transparent)
    .systemTransition(NavigationSystemTransitionType.NONE)
  }

  build() {
    Stack() {
      if (this.wallpaperUri) {
        GlobalWallpaper()
      } else {
        FloatTilesBackground({
          themeColors: this.themeColors,
          isPlaying: this.isWideScreenMode() && this.selectedCategoryKey === 'about'
        })
      }

      if (this.isWideScreenMode()) {
        HdsNavigation(this.navPathStack) {
          // 侧栏与详情栏卡片边距统一为 24vp（= ohos_id_max_padding_start）：
          // 卡片外边距 12vp（menuGroupMargin）+ 容器内边距 12vp
          Column() {
            this.CategoryList()
          }
          .width('100%')
          .height('100%')
          .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end') })
        }
        .navDestination(this.SettingsNavDestination)
        .mode(NavigationMode.Split)
        .titleMode(HdsNavigationTitleMode.MINI)
        .navBarPosition(NavBarPosition.Start)
        .navBarWidth(300)
        .minContentWidth(360)
        .hideToolBar(true)
        .enableDragBar(false)
        .bindToScrollable([this.pageScroller, this.detailScroller])
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .titleBar({
          content: {
            title: { mainTitle: I18n.t('settings') },
            backIcon: {
              icon: navBackIconModifier(),
              action: () => {
                this.handleBack();
              }
            }
          },
          style: {
            scrollEffectOpts: {
              scrollEffectType: ScrollEffectType.GRADIENT_BLUR
            },
            systemMaterialEffect: {
              materialType: hdsMaterial.MaterialType.ADAPTIVE,
              materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
            }
          },
          avoidLayoutSafeArea: true,
          enableComponentSafeArea: false
        })
        .width('100%')
        .height('100%')
      } else {
        AzaharNavPage({
          title: I18n.t('settings'),
          scrollers: [this.pageScroller],
          onBack: () => {
            this.handleBack();
          }
        }) {
          this.CategoryList()
        }
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const width = Number(newArea.width);
      if (width > 0 && width !== this.settingsWidth) {
        this.settingsWidth = width;
      }
    })
    // 分栏下手柄详情没有独立页面：摇杆轴（FocusAxisEvent）与手柄键码
    // （KeyEvent）都由本页根节点喂给模块级状态，供测试/捕获 tab 轮询
    .onFocusAxisEvent((event: FocusAxisEvent) => {
      GamepadFocusAxisState.record(event);
      if (this.isInSplitGamepadTest()) {
        event.stopPropagation();
      }
    })
    .onKeyPreIme((event: KeyEvent) => {
      // 捕获态下键盘键码也要入边队列：统一捕获靠 pad 标记区分键盘/手柄来源
      if (!isGamepadKey(event.keyCode) && !GamepadCaptureState.active) {
        return false;
      }
      GamepadArkKeyState.record(event.keyCode, event.type === KeyType.Down,
        GamepadArkKeyState.isGamepadSource(event));
      return this.isInSplitGamepadTest() || GamepadCaptureState.active;
    })
    .onKeyEvent((event: KeyEvent) => {
      if (isGamepadKey(event.keyCode) || GamepadCaptureState.active) {
        GamepadArkKeyState.record(event.keyCode, event.type === KeyType.Down,
          GamepadArkKeyState.isGamepadSource(event));
      }
      if (this.isInSplitGamepadTest() && isGamepadKey(event.keyCode)) {
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

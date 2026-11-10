import { router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationMenuItemOptions, HdsNavigationTitleMode, BottomBuilderShowType, hdsMaterial, ScrollEffectType } from '@kit.UIDesignKit';
import { navBackIconModifier } from '../../types/UIConstants';
import { SafeAreaHelper } from '../../utils/SafeAreaHelper';

export interface AzaharNavMenuItem {
  icon: Resource;
  action: () => void;
  enabled?: boolean;
  // 设置后该图标携带组件 id，可在 action 里用 promptAction.openMenu 锚定弹出自定义菜单
  componentId?: string;
}

/**
 * 二级页面导航壳：直接用 HdsNavigation 渲染标题栏，
 * 返回键和右侧菜单项与首页右上角按钮是同一个系统组件
 * （圆形沉浸光感 + 按压/拖动反馈 + 标准 icon 尺寸）。
 */
@Component
export struct AzaharNavPage {
  @Prop title: ResourceStr = '';
  @Prop subtitle: ResourceStr = '';
  @Prop showBack: boolean = true;
  menuItems: AzaharNavMenuItem[] = [];
  onBack: () => void = () => router.back();
  scrollers: Scroller[] = [];
  bottomBuilder?: () => void;
  bottomBuilderHeight: number = 0;
  // 标题区自定义内容：走标题栏 stackBuilder 叠层（覆盖返回/菜单区整条栏），内容需自行避让两端按钮；
  // 设置后原生 mainTitle/subTitle 不渲染，避免与自定义标题行重复
  titleBuilder?: () => void;
  @BuilderParam content: () => void;

  aboutToAppear(): void {
    // 悬浮标题栏内部自行避让状态栏，内容垫高依赖 safeAreaTopVp；
    // 进入页面前重测一次，规避初始化早于窗口布局完成的竞态
    SafeAreaHelper.refresh();
  }

  private buildMenuItems(): HdsNavigationMenuItemOptions[] {
    return this.menuItems.map((item: AzaharNavMenuItem) => {
      const menuItem: HdsNavigationMenuItemOptions = {
        content: {
          icon: item.icon,
          isEnabled: item.enabled !== false,
          action: item.action,
          componentId: item.componentId
        }
      };
      return menuItem;
    });
  }

  build() {
    HdsNavigation() {
      Stack({ alignContent: Alignment.Top }) {
        if (this.content) {
          this.content()
        }
      }
      .width('100%')
      .height('100%')
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    }
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(!this.showBack)
    .hideToolBar(true)
    .bindToScrollable(this.scrollers)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleBar({
      content: {
        title: this.titleBuilder ? undefined : {
          mainTitle: this.title,
          subTitle: this.subtitle
        },
        stackBuilder: this.titleBuilder ? () => {
          if (this.titleBuilder) {
            this.titleBuilder();
          }
        } : undefined,
        backIcon: {
          icon: navBackIconModifier(),
          action: this.onBack
        },
        menu: this.menuItems.length > 0 ? {
          value: this.buildMenuItems(),
          maxCount: 4
        } : undefined,
        bottomBuilder: this.bottomBuilder ? {
          builder: () => {
            if (this.bottomBuilder) {
              this.bottomBuilder();
            }
          },
          height: this.bottomBuilderHeight,
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
    .width('100%')
    .height('100%')
  }
}

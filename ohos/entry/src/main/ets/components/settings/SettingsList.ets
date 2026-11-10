import { NAV_TITLE_SCROLL_SPACE, TEXT_PRIMARY, TEXT_SECONDARY } from '../../types/UIConstants';
import { createScrollSource, setScrollSourceActive } from '../../utils/ScrollAnimationState';

// 分组卡片列表的系统分隔线：卡内行间的发丝线，左缩进对齐主文本
export function settingsGroupDivider(): ListDividerOptions {
  return { strokeWidth: '1px', color: $r('sys.color.ohos_id_color_list_separator'), startMargin: $r('sys.float.ohos_id_elements_margin_horizontal_l'), endMargin: 0 };
}

// 导航菜单卡（设置页分类列表、暂停菜单）的 CARD 组内边距：ComposeListItem 外层 Stack 自带左右 4vp，
// 再叠 CARD 默认的左右 4vp 会让按压高亮离卡片边缘 8vp；清掉组的左右内边距只留组件自身 4vp，上下保持 CARD 规格
export function menuGroupPadding(): Padding {
  return { left: 0, right: 0, top: $r('sys.float.padding_level2'), bottom: $r('sys.float.padding_level2') };
}

// CARD 组之间的间距外边距：显式 .margin() 会整体替换 CARD 组的默认外边距，只写 bottom 会把
// 左右 12vp 卡片边距清成 0——窄栏（设置页分栏、详情栏）里卡片会贴边、和同列表其他卡宽度不一致；
// 组间距统一用它，左右按卡片规格补回
export function menuGroupMargin(): Margin {
  return { left: $r('sys.float.ohos_id_card_margin_start'), right: $r('sys.float.ohos_id_card_margin_end'), bottom: $r('sys.float.ohos_id_card_margin_middle') };
}

/**
 * 纯信息展示行（无按压态）：版式对齐 ComposeListItem，但不可点。
 * ComposeListItem 的 useEffect 会挂到自动生成的 __Common__ 包装节点、压不住组件内部的
 * 点击高亮——没有交互的标签/值行统一用它，不要在 ComposeListItem 上叠 useEffect(false)。
 */
@Component
export struct StaticInfoRow {
  icon?: Resource;
  title: ResourceStr = '';
  desc?: ResourceStr;
  value?: ResourceStr;

  build() {
    Row() {
      if (this.icon) {
        SymbolGlyph(this.icon)
          .fontSize(24)
          .fontColor([TEXT_SECONDARY])
          .margin({ right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
      }
      Column({ space: $r('sys.float.ohos_id_text_paragraph_margin_xs') }) {
        Text(this.title)
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontColor(TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.desc) {
          Text(this.desc)
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor(TEXT_SECONDARY)
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.value) {
        Text(this.value)
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontColor(TEXT_SECONDARY)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
      }
    }
    .width('100%')
    .padding({
      left: $r('sys.float.ohos_id_default_padding_start'),
      right: $r('sys.float.ohos_id_default_padding_end'),
      top: $r('sys.float.ohos_id_elements_margin_vertical_l'),
      bottom: $r('sys.float.ohos_id_elements_margin_vertical_l')
    })
    .alignItems(VerticalAlign.Center)
  }
}

// 分组卡片的章节标题：系统设置风格的小号灰色分类标签（如"屏幕"），可带描述行
@Component
export struct SettingsSectionHeader {
  title: ResourceStr = '';
  desc: ResourceStr = '';
  topSpace: number = 12;

  build() {
    Column() {
      Text(this.title)
        .fontSize($r('sys.float.ohos_id_text_size_body2'))
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_SECONDARY)
        .width('100%')
      if (typeof this.desc === 'string' && this.desc !== '') {
        Text(this.desc)
          .fontSize($r('sys.float.ohos_id_text_size_body3'))
          .fontColor(TEXT_SECONDARY)
          .width('100%')
          .margin({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
      }
    }
    .width('100%')
    .padding({ left: $r('sys.float.ohos_id_max_padding_start'), right: $r('sys.float.ohos_id_default_padding_end'), top: this.topSpace, bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })
  }
}

// 全屏滚动的分组卡片列表：内容铺在悬浮标题栏下方，首尾占位垫出安全距离。
// 使用时在 content 里放 ListItemGroup({style: ListItemGroupStyle.CARD}) 分组 + ListItem 行。
@Component
export struct SettingsList {
  scroller?: Scroller;
  // 顶部占位高度：铺满全屏滚动时垫出悬浮标题栏所占的高度（状态栏 + 标题栏），用首个空白 ListItem 实现
  topSpace: number = NAV_TITLE_SCROLL_SPACE;
  // 列表顶边已在状态栏下方时（如 Tab 页内）设为 false，避免重复垫出状态栏高度
  includeTopSafeArea: boolean = true;
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;
  @StorageLink('safeAreaTopVp') safeAreaTopVp: number = 0;
  @BuilderParam content: () => void;
  private ownScroller: Scroller = new Scroller();
  private scrollSourceId: number = createScrollSource();
  @State private isScrolling: boolean = false;

  aboutToDisappear(): void {
    this.isScrolling = false;
    setScrollSourceActive(this.scrollSourceId, false);
  }

  private onScrollStart(): void {
    if (!this.isScrolling) {
      this.isScrolling = true;
      setScrollSourceActive(this.scrollSourceId, true);
    }
  }

  private onScrollStop(): void {
    if (this.isScrolling) {
      this.isScrolling = false;
      setScrollSourceActive(this.scrollSourceId, false);
    }
  }

  build() {
    List({ scroller: this.scroller ? this.scroller : this.ownScroller }) {
      // 顶部占位: 垫出悬浮标题栏高度；不能用 contentStartOffset——它会让滚动总偏移从负值起步，
      // 标题栏 GRADIENT_BLUR 要滚过整段偏移才生效
      ListItem() {
        Column() {
        }
        .width('100%')
        .height((this.includeTopSafeArea ? this.safeAreaTopVp : 0) + this.topSpace)
      }
      this.content()
      ListItem() {
        Column() {
        }
        .width('100%')
        .height(24 + this.safeAreaBottomVp)
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
    .onScrollStart(() => this.onScrollStart())
    .onScrollStop(() => this.onScrollStop())
  }
}

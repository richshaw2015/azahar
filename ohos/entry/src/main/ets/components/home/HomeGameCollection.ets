import { LengthMetrics, ColorMetrics } from '@kit.ArkUI';
import { controlAccentOf } from '../common/AzaharControls';
import { AzaharGameCardDataSource } from '../../models/AzaharGameCardDataSource';
import { AzaharGameCardModel } from '../../models/AzaharGameCardModel';
import { GameInfo } from '../../utils/GameManager';
import { AzaharCartridgeGridModelItem, AzaharCartridgeListModelItem } from '../game/AzaharCartridgeItem';
import { AzaharEmptySlot } from '../game/AzaharEmptySlot';
import { FileManagerHelper } from '../../utils/FileManagerHelper';
import { setScrollSourceActive } from '../../utils/ScrollAnimationState';
import { AzaharThemeColors } from '../../types/ThemeTypes';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { FONT_SIZE_MIN, GRID_COVER_BASE, GRID_COVER_SIZE_MAX, GRID_COVER_SIZE_MIN, LIST_COVER_BASE, LIST_COVER_SIZE_MAX, LIST_COVER_SIZE_MIN, SEGMENT_BAR_HEIGHT, TEXT_SECONDARY } from '../../types/UIConstants';

/** 列表行高 = 封面 + 上下内边距（与 AzaharCartridgeListModelItem.rowHeight 的 s(64)+16 一致） */
const LIST_ROW_VERTICAL_PADDING: number = 16;
/** 宽屏两列分栏断点：与首页/设置页及 nds UIConstants.WIDE_SCREEN_BREAKPOINT 一致 */
const WIDE_SCREEN_BREAKPOINT: number = 640;
/** 网格列数计算用的最小卡间/边缘间距 */
const GRID_GAP_MIN: number = 8;
/** 首页标题区高度（vp） */
const HOME_TITLE_BAR_HEIGHT: number = 56;
/** 悬浮操作栏占位高 = 栏高56(barFloatingStyle默认barHeight) + 内容到栏间距16(同gradientMask默认"栏高+16"留白) */
const FLOATING_BAR_RESERVE: number = 72;

/** 首页游戏集合视图：网格/列表渲染、目录控制行、空态、卡片/行项；由三个 Tab 复用 */
@Component
export struct HomeGameCollection {
  dataSource: AzaharGameCardDataSource = new AzaharGameCardDataSource();
  scroller: Scroller = new Scroller();
  @Prop showDir: boolean = false;
  @Prop isEmpty: boolean = false;
  @Prop emptyTitle: string = '';
  @Prop emptyDesc: string = '';
  @Prop downloadDirPath: string = '';
  @Prop layoutType: string = 'grid';
  @Prop openingGamePath: string = '';
  @Prop collectionScrollSourceId: number = 0;
  @Prop themeColors: AzaharThemeColors;
  soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  // 布局度量必须由本组件在 build 路径中读取已观察状态来计算：函数 prop 闭包读父级
  // 状态不会给子组件建立依赖，封面大小变化时 lanes/padding 不会重算（卡片尺寸走
  // LazyForEach item 重建所以正常），列数会停留在旧值直到组件重建
  @Prop screenWidth: number = 360;
  @StorageLink('safeAreaTopVp') safeAreaTopVp: number = 0;
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;
  // 封面尺寸直接观察 AppStorage：滑块写 AppStorage 时本组件随值重建
  @StorageLink('gridSize') gridSize: number = GRID_COVER_BASE;
  @StorageLink('listSize') listSize: number = LIST_COVER_BASE;
  openGame: (path: string, uri: string) => void = () => {};
  openGameDetailsWithFlash: (game: GameInfo) => void = () => {};
  initializeDownloadDir: () => void = () => {};
  openDownloadDir: () => void = () => {};
  /** 列表逐帧滚动增量（vp），内容上移为正；用于首页底部操作栏随滚动收起/展开 */
  onScrollDelta: (deltaY: number) => void = () => {};

  @Builder
  LibraryControlRow() {
    Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize($r('sys.float.ohos_id_piece_icon_size'))
        .fontColor([TEXT_SECONDARY])
      Text(this.downloadDirPath ? FileManagerHelper.getDisplayPath(this.downloadDirPath) : I18n.t('download_dir_not_set_yet'))
        .fontSize(FONT_SIZE_MIN)
        .fontColor(TEXT_SECONDARY)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .wordBreak(WordBreak.BREAK_ALL)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .focusable(true)
    .focusOnTouch(true)
    .focusBox({ margin: new LengthMetrics(-2), strokeColor: ColorMetrics.resourceColor(controlAccentOf(this.themeColors)) })
    .useEffect(true)
    .onFocus(() => {
      this.soundEffectManager.play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      this.soundEffectManager.play(SoundEffect.SELECT);
      if (!this.downloadDirPath) {
        this.initializeDownloadDir();
      } else {
        this.openDownloadDir();
      }
    })
    .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end'), top: 6 })
  }

  private effectiveGridSize(): number {
    return Math.round(Math.max(GRID_COVER_SIZE_MIN, Math.min(GRID_COVER_SIZE_MAX, this.gridSize)));
  }

  private effectiveListSize(): number {
    return Math.round(Math.max(LIST_COVER_SIZE_MIN, Math.min(LIST_COVER_SIZE_MAX, this.listSize)));
  }

  private listRowHeight(): number {
    return this.effectiveListSize() + LIST_ROW_VERTICAL_PADDING;
  }

  private gridAvailableWidth(): number {
    return this.screenWidth > 0 ? Math.max(1, this.screenWidth) : 360;
  }

  private gridColumnCount(): number {
    const card = this.effectiveGridSize();
    const width = this.gridAvailableWidth();
    // 列数按最小允许间距计算：能挤下就多放一列，间距交给 gridGap 压缩
    return Math.max(1, Math.floor((width - GRID_GAP_MIN) / (card + GRID_GAP_MIN)));
  }

  private gridGap(): number {
    const card = this.effectiveGridSize();
    const columns = this.gridColumnCount();
    // n+1 份间距（含两侧边缘）均分富余宽度：卡片-卡片 与 卡片-屏幕边缘 间距一致
    return Math.max(GRID_GAP_MIN, (this.gridAvailableWidth() - columns * card) / (columns + 1));
  }

  private gridEdgePadding(): number {
    // 边缘外边距与卡间间距等宽
    return this.gridGap();
  }

  private listLanes(): number {
    return this.screenWidth >= WIDE_SCREEN_BREAKPOINT ? 2 : 1;
  }

  private actionBarBottomMargin(): number {
    return Math.max(8, this.safeAreaBottomVp);
  }

  private collectionBottomSpace(): number {
    return FLOATING_BAR_RESERVE + this.actionBarBottomMargin();
  }

  private collectionTopSpace(): number {
    // 垫高 = 首页标题区高度 + 标题栏分段控件区高
    return this.safeAreaTopVp + HOME_TITLE_BAR_HEIGHT + SEGMENT_BAR_HEIGHT;
  }

  @Builder
  GameCard(model: AzaharGameCardModel) {
    AzaharCartridgeGridModelItem({
      model: model,
      themeColors: this.themeColors,
      cardSize: this.effectiveGridSize(),
      isOpening: this.openingGamePath === model.gameInfo.path,
      onLaunch: () => {
        this.openGame(model.gameInfo.path, model.gameInfo.uri);
      },
      onOpenDetails: () => {
        this.openGameDetailsWithFlash(model.gameInfo);
      }
    })
  }

  @Builder
  GameRow(model: AzaharGameCardModel) {
    AzaharCartridgeListModelItem({
      model: model,
      themeColors: this.themeColors,
      cardSize: this.effectiveListSize(),
      isOpening: this.openingGamePath === model.gameInfo.path,
      onLaunch: () => {
        this.openGame(model.gameInfo.path, model.gameInfo.uri);
      },
      onOpenDetails: () => {
        this.openGameDetailsWithFlash(model.gameInfo);
      }
    })
  }

  @Builder
  CenterEmptySlot(title: string, subtitle: string) {
    Column() {
      AzaharEmptySlot({
        title: title,
        subtitle: subtitle
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end') })
  }

  @Builder
  CollectionHeader(showDir: boolean) {
    Column() {
      Blank()
        .width('100%')
        .height(this.collectionTopSpace())
      if (showDir) {
        this.LibraryControlRow()
      }
      Blank()
        .width('100%')
        .height($r('sys.float.ohos_id_card_margin_middle'))
    }
    .width('100%')
  }

  @Builder
  CollectionFooter() {
    Blank()
      .width('100%')
      .height(this.collectionBottomSpace())
  }

  @Builder
  GameCollection(dataSource: AzaharGameCardDataSource, scroller: Scroller, showDir: boolean) {
    // 网格也走 List + lanes：lanes 下 ListItemGroup 独占整行，且 space 不作用于
    // header/footer 与列表项之间，头/尾间距语义与列表模式保持一致
    List({ space: 6, scroller: scroller }) {
      ListItemGroup({
        header: () => this.CollectionHeader(showDir),
        footer: () => this.CollectionFooter(),
        space: this.layoutType === 'grid' ? this.gridGap() : 6
      }) {
        if (this.layoutType === 'grid') {
          LazyForEach(dataSource, (model: AzaharGameCardModel) => {
            ListItem() {
              this.GameCard(model)
            }
            .focusable(true)
            .focusOnTouch(true)
            .focusBox({ margin: new LengthMetrics(-2), strokeColor: ColorMetrics.resourceColor(controlAccentOf(this.themeColors)) })
            .onFocus(() => {
              this.soundEffectManager.play(SoundEffect.FOCUS);
            })
          }, (model: AzaharGameCardModel) => model.gameInfo.path)
        } else {
          LazyForEach(dataSource, (model: AzaharGameCardModel) => {
            ListItem() {
              this.GameRow(model)
            }
            .height(this.listRowHeight())
            .focusable(true)
            .focusOnTouch(true)
            .focusBox({ margin: new LengthMetrics(-2), strokeColor: ColorMetrics.resourceColor(controlAccentOf(this.themeColors)) })
            .onFocus(() => {
              this.soundEffectManager.play(SoundEffect.FOCUS);
            })
          }, (model: AzaharGameCardModel) => model.gameInfo.path)
        }
      }
    }
    .lanes(this.layoutType === 'grid' ? this.gridColumnCount() : this.listLanes(),
      this.layoutType === 'grid' ? this.gridGap() : 6)
    .padding(this.layoutType === 'grid' ? { left: this.gridEdgePadding(), right: this.gridEdgePadding() } : 0)
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .onScrollStart(() => {
      setScrollSourceActive(this.collectionScrollSourceId, true);
    })
    .onScrollStop(() => {
      setScrollSourceActive(this.collectionScrollSourceId, false);
    })
    .onDidScroll((scrollOffset: number) => {
      this.onScrollDelta(scrollOffset);
    })
  }

  build() {
    Column() {
      if (!this.isEmpty) {
        this.GameCollection(this.dataSource, this.scroller, this.showDir)
      } else {
        this.CenterEmptySlot(this.emptyTitle, this.emptyDesc)
      }
    }
    .width('100%')
    .height('100%')
  }
}

import { common } from '@kit.AbilityKit';
import { KEY_PP_SHADER_NAME } from '../../../types/SettingsTypes';
import { SCREEN_FILTER_NONE_VALUE, ScreenFilterItem, screenFilterItems } from '../../../types/ScreenFilterDefs';
import { NAV_TITLE_SCROLL_SPACE } from '../../../types/UIConstants';
import { SettingsManager } from '../../../utils/SettingsManager';
import { SoundEffectManager } from '../../../utils/SoundEffectManager';
import { CARD_EXTRA_H, PREVIEW_ASPECT, ScreenFilterCard } from '../../common/ScreenFilterCard';

const GRID_GAP: number = 8;
const GRID_ROW_GAP: number = 12;
const GRID_PADDING: number = 12;
const GRID_ITEM_TARGET_W: number = 170;

@Component
export struct ScreenFilterSettingsContent {
  @StorageLink('screen_filter_selection') screenFilter: string = SCREEN_FILTER_NONE_VALUE;
  @StorageLink('safeAreaTopVp') safeAreaTopVp: number = 0;
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;
  scroller?: Scroller;
  @State contentWidth: number = 0;
  /** Scroll 视口高度，onAreaChange 回填；与 contentWidth 一起用于首次滚动定位 */
  private viewportHeight: number = 0;
  private initialScrolled: boolean = false;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();

  async aboutToAppear(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    await this.soundEffectManager.initialize(this.context);
    // 未写过该 key 时 getString 可能返回空值 —— 归一到 None 避免无选中项
    const saved = this.settingsManager.getString(KEY_PP_SHADER_NAME);
    this.screenFilter = (typeof saved === 'string' && saved.length > 0)
      ? saved
      : SCREEN_FILTER_NONE_VALUE;
  }

  private columnCount(): number {
    const w = this.contentWidth > 0 ? this.contentWidth : 360;
    return Math.max(1, Math.min(4, Math.floor(w / GRID_ITEM_TARGET_W)));
  }

  private columnsTemplate(): string {
    return new Array<string>(this.columnCount()).fill('1fr').join(' ');
  }

  private selectedIndex(): number {
    const list = screenFilterItems();
    for (let i = 0; i < list.length; i++) {
      if (list[i].value === this.screenFilter) {
        return i;
      }
    }
    return -1;
  }

  private cardWidth(): number {
    const cols = this.columnCount();
    const w = this.contentWidth > 0 ? this.contentWidth : 360;
    return (w - GRID_PADDING * 2 - GRID_GAP * (cols - 1)) / cols;
  }

  /** 打开页面时把选中卡滚到视口中央（对齐 melonDS-ohos 的定位方式） */
  private scrollToSelectedFilter(): void {
    const index = this.selectedIndex();
    if (index < 0 || !this.scroller || this.viewportHeight <= 0) {
      return;
    }
    const cols = this.columnCount();
    const cardH = this.cardWidth() / PREVIEW_ASPECT + CARD_EXTRA_H;
    const topSpace = this.safeAreaTopVp + NAV_TITLE_SCROLL_SPACE;
    const row = Math.floor(index / cols);
    const cardCenter = topSpace + row * (cardH + GRID_ROW_GAP) + cardH / 2;
    const rows = Math.ceil(screenFilterItems().length / cols);
    const gridH = rows * cardH + (rows - 1) * GRID_ROW_GAP;
    const contentH = topSpace + gridH + 12 + this.safeAreaBottomVp;
    const maxOffset = Math.max(0, contentH - this.viewportHeight);
    const target = Math.min(Math.max(0, cardCenter - this.viewportHeight / 2), maxOffset);
    this.scroller.scrollTo({ xOffset: 0, yOffset: target, animation: false });
  }

  private tryInitialScroll(): void {
    if (this.initialScrolled || this.viewportHeight <= 0 || this.contentWidth <= 0) {
      return;
    }
    this.initialScrolled = true;
    this.scrollToSelectedFilter();
  }

  build() {
    Scroll(this.scroller) {
      Grid() {
        ForEach(screenFilterItems(), (item: ScreenFilterItem) => {
          GridItem() {
            ScreenFilterCard({ item: item })
          }
        }, (item: ScreenFilterItem) => item.value)
      }
      .columnsTemplate(this.columnsTemplate())
      .columnsGap(GRID_GAP)
      .rowsGap(GRID_ROW_GAP)
      .padding({
        left: GRID_PADDING,
        right: GRID_PADDING,
        top: this.safeAreaTopVp + NAV_TITLE_SCROLL_SPACE,
        bottom: 12 + this.safeAreaBottomVp
      })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .width('100%')
    .height('100%')
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w = Number(newArea.width);
      const h = Number(newArea.height);
      if (w > 0) {
        this.contentWidth = w;
      }
      if (h > 0) {
        this.viewportHeight = h;
      }
      this.tryInitialScroll();
    })
  }
}

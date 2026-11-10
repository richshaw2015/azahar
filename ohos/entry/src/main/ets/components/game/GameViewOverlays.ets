

import { ComposeListItem, IconType, OperateIcon, SymbolGlyphModifier } from '@kit.ArkUI';
import { immersiveMaterial, controlAccentOf } from '../common/AzaharControls';
import { MultiplayerSheets } from '../common/MultiplayerSheets';
import { AmiiboSheet } from './AmiiboSheet';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { image } from '@kit.ImageKit';
import { fileUri } from '@kit.CoreFileKit';
import { formatFileSize } from '../../utils/FileSizeFormatter';

import { AzaharThemeColors } from '../../types/ThemeTypes';
import { AzaharCheatInfo, AzaharSaveStateInfo, QUICK_SAVE_STATE_SLOT } from '../../types/AzaharNative';
import { KEY_PP_SHADER_NAME } from '../../types/SettingsTypes';
import {
  SCREEN_FILTER_NONE_VALUE,
  ScreenFilterItem,
  screenFilterItems
} from '../../types/ScreenFilterDefs';
import { ScreenFilterCard } from '../common/ScreenFilterCard';
import { menuGroupPadding, settingsGroupDivider } from '../settings/SettingsList';
import { ToggleSettingItem } from '../settings/ToggleSettingItem';
import { SettingsManager } from '../../utils/SettingsManager';
import {
  BUTTON_BG_SECONDARY,
  COVER_RADIUS_DEFAULT,
  RADIUS_SM,
  SURFACE_TRACK,
  TEXT_DANGER,
  TEXT_ON_ACCENT,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';
import { listCardBgOf } from '../../utils/ThemeSurfaces';

import { I18n } from '../../utils/I18nManager';
import { formatSaveStateTime } from '../../utils/DateTimeFormatter';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';

// chevron_up/down 相对 chevron_right 多出的半侧墨迹宽度（24vp 字号下估算），用于把右缘间距拉回设置页同值
const VERTICAL_CHEVRON_OFFSET_X = -6;

interface MoreMenuAction {
  id: string;
  title: string;
  icon: Resource;
  danger: boolean;
  /** 激活态标记：图标用主题强调色渲染（如已收藏的五角星） */
  accent?: boolean;
  /** 关联的存档槽位（撤销覆盖动作用） */
  slot?: number;
}

/** 将文件绝对路径转换为 Image 组件可用的 file:// URI（对齐 nds） */
function toImageUri(path: string): string {
  if (!path) {
    return '';
  }
  try {
    if (path.startsWith('/storage/Users/')) {
      return 'file://docs' + path;
    }
    return fileUri.getUriFromPath(path);
  } catch (_e) {
    return path;
  }
}

/** 宽屏两列分栏断点：与首页/设置页及 nds UIConstants.WIDE_SCREEN_BREAKPOINT 一致 */
const WIDE_SCREEN_BREAKPOINT: number = 640;
/** 紧凑宽屏上限（对齐 nds isCompactWide）：低于此宽度左列菜单面板收窄为 COMPACT_MENU_PANEL_WIDTH */
const COMPACT_WIDE_BREAKPOINT: number = 720;
/** 宽屏左列菜单面板宽（vp，对齐 nds 260/200 两档） */
const WIDE_MENU_PANEL_WIDTH: number = 260;
const COMPACT_MENU_PANEL_WIDTH: number = 200;

/** 游戏运行时暂停菜单（移植自 nds 全屏暂停菜单结构，统一改用系统组件）：
 *  全屏半透明光感覆盖层；即时存档列表（默认展开）+ 金手指/触屏按键/更多 收纳 + 底部 继续游戏/返回主菜单。
 *  宽屏时左列菜单面板、右列当前分区内容面板两列分栏（对齐 nds）；窄屏单列纵向。
 *  由 GameView 以 if 叠加层方式挂载。 */
@Component
export struct GameViewOverlays {
  @Prop uiThemeColors: AzaharThemeColors;
  @Prop gameTitle: string = '';
  /** 游戏包体 Icon，顶部展示与存档槽位缩略图共用。PixelMap 不能用 @Prop（深拷贝会破坏 native 绑定），按引用传递 */
  @Link gameIcon: image.PixelMap | null;
  @Prop saveStates: AzaharSaveStateInfo[] = [];
  /** 手动槽位数量（设置页可配 10/20/50/100，槽 0 为快速存/读档不进列表） */
  @Prop saveStateSlotCount: number = 10;
  @Prop cheats: AzaharCheatInfo[] = [];
  @Prop isFavorite: boolean = false;
  soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  saveStateToSlot: (slot: number) => void = () => {};
  loadStateFromSlot: (slot: number) => void = () => {};
  openSaveStateDetail: (slot: number) => void = () => {};
  undoSaveState: (slot: number) => void = () => {};
  /** 屏幕宽度 (vp)：>=WIDE_SCREEN_BREAKPOINT 启用两列分栏、<COMPACT_WIDE_BREAKPOINT 左列收窄（对齐 nds screenWidth 语义） */
  @Prop screenWidth: number = 0;
  /** 上下屏交换开启时存档截图上屏在右侧，列表缩略图随之切换裁剪侧 */
  @Prop swapScreensEnabled: boolean = false;
  /** 封面圆角：跟随首页"外观设置-封面圆角"百分比设置（AzaharCartridgeItem 同款订阅） */
  @StorageLink('coverCornerRadius') coverCornerRadius: number = COVER_RADIUS_DEFAULT;
  toggleCheat: (cheat: AzaharCheatInfo, enabled: boolean) => void = () => {};
  /** 金手指管理动作：导入文件 / 新增 / 全部禁用（对齐详情页金手指 Tab 工具行） */
  importCheats: () => void = () => {};
  beginAddCheat: () => void = () => {};
  disableAllCheats: () => void = () => {};
  /** 点击金手指行打开详情弹窗（查看/复制/编辑/删除），对齐管理面板行行为 */
  viewCheatDetail: (cheat: AzaharCheatInfo) => void = () => {};
  toggleFavorite: () => void = () => {};
  handleRuntimeMenuAction: (action: string) => void = () => {};

  /** 当前激活的展开段：saves(默认)/cheats/filters/more/'' 收起（与 nds 一致，每次只展开一个） */
  @State activeSection: string = 'saves';
  /** '更多'网格实测宽度，驱动列数自适应 */
  @State moreMenuGridWidth: number = 0;
  /** 滤镜网格实测宽度，驱动列数自适应 */
  @State filterGridWidth: number = 0;
  /** 当前屏幕滤镜：与设置页共用 AppStorage 选中态（screen_filter_selection），两处自动同步 */
  @StorageLink('screen_filter_selection') screenFilter: string = SCREEN_FILTER_NONE_VALUE;
  /** 联机弹窗入口开关（对齐 Android NetPlayDialog：底部弹窗而非跳页） */
  @State showMultiplayerSheet: boolean = false;
  /** Amiibo 弹窗入口开关（对齐 Android Amiibo 二级菜单：底部弹窗） */
  @State showAmiiboSheet: boolean = false;
  /** 文件存在但解码失败的截图路径，后续渲染降级到纯浅色底（对齐 nds） */
  @State failedScreenshotPaths: string[] = [];
  /** 存档列表滚动器：打开时把自动滚动目标对齐到列表底部（对齐 nds），上方露出最近几个已有存档 */
  private savesScroller: Scroller = new Scroller();
  /** 滤镜网格滚动器：展开时把选中滤镜定位到视口中央（对齐滤镜设置页） */
  private filterScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    // 暂停菜单可能先于滤镜设置页打开：AppStorage 选中态未填充时回读持久化值，保证两处显示一致
    const saved = SettingsManager.getInstance().getString(KEY_PP_SHADER_NAME);
    if (saved.length > 0 && saved !== this.screenFilter) {
      this.screenFilter = saved;
    }
  }

  private saveStateInfo(slot: number): AzaharSaveStateInfo | undefined {
    return this.saveStates.find((info: AzaharSaveStateInfo) => info.slot === slot);
  }

  private hasUsableScreenshot(slot: number): boolean {
    const info = this.saveStateInfo(slot);
    return info !== undefined && info.screenshotPath.length > 0
      && this.failedScreenshotPaths.indexOf(info.screenshotPath) < 0;
  }

  private markScreenshotFailed(path: string): void {
    if (path.length > 0 && this.failedScreenshotPaths.indexOf(path) < 0) {
      this.failedScreenshotPaths = [...this.failedScreenshotPaths, path];
    }
  }

  /** 是否启用宽屏两列分栏 */
  private isWideLayout(): boolean {
    return this.screenWidth >= WIDE_SCREEN_BREAKPOINT;
  }

  /** 紧凑宽屏（对齐 nds isCompactWide）：宽度 <720 时左列菜单面板收窄 */
  private isCompactWide(): boolean {
    return this.screenWidth < COMPACT_WIDE_BREAKPOINT;
  }

  /** 宽屏左列菜单面板宽（对齐 nds 260/200 两档） */
  private menuPanelWidth(): number {
    return this.isCompactWide() ? COMPACT_MENU_PANEL_WIDTH : WIDE_MENU_PANEL_WIDTH;
  }

  /** 右栏/展开区当前分区：窄屏收起态('')回退到存档面板，保证宽屏右栏始终有内容（对齐 nds slots 默认面板） */
  private panelSection(): string {
    return this.activeSection === '' ? 'saves' : this.activeSection;
  }

  /** 分区菜单点击：窄屏原位手风琴展开/收起（animateTo 推移下方行）；宽屏切换右栏分区，再点当前分区回退到存档面板（对齐 nds slots 回退） */
  private toggleMenuSection(section: string): void {
    if (this.isWideLayout()) {
      this.activeSection = this.activeSection === section ? 'saves' : section;
    } else {
      animateTo({ duration: 250, curve: Curve.EaseInOut }, () => {
        this.activeSection = this.activeSection === section ? '' : section;
      });
    }
  }

  /** 最近一次被覆盖写档的槽位：native 侧只留底本会话最近一次覆盖，至多一个槽位 hasUndo；
   *  仍按新档时间取最新兜底（覆盖后落盘的 time 更大），无备份返回 undefined。快速槽（0）覆盖同样可撤销 */
  private latestUndoableSlot(): number | undefined {
    let slot: number | undefined;
    let newest = -1;
    this.saveStates.forEach((info: AzaharSaveStateInfo) => {
      if (info.hasUndo && info.time > newest) {
        newest = info.time;
        slot = info.slot;
      }
    });
    return slot;
  }

  /** 撤销入口标题里的槽位名：快速槽与普通槽分开命名（对齐 GameView.saveStateSlotLabel） */
  private undoSlotLabel(slot: number): string {
    return slot === QUICK_SAVE_STATE_SLOT
      ? I18n.t('save_state_quick_slot')
      : I18n.tf1('save_state_slot_fmt', 'slot', slot);
  }

  private moreActions(): MoreMenuAction[] {
    const actions: MoreMenuAction[] = [];
    // 撤销覆盖入口（对齐 nds/retro 暂停菜单撤销存档）：覆盖写档留下内存备份时出现，
    // 恢复最近一次被覆盖的槽位；备份消费后条目自动消失
    const undoSlot = this.latestUndoableSlot();
    if (undoSlot !== undefined) {
      actions.push({
        id: 'undo_save',
        title: I18n.tf1('undo_overwrite_slot_fmt', 'slot', this.undoSlotLabel(undoSlot)),
        icon: $r('sys.symbol.undo'),
        danger: false,
        slot: undoSlot
      });
    }
    actions.push(
      { id: 'screenshot', title: I18n.t('screenshot'), icon: $r('sys.symbol.camera'), danger: false },
      {
        id: 'favorite',
        title: this.isFavorite ? I18n.t('remove_from_favorites') : I18n.t('add_to_favorites'),
        icon: this.isFavorite ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'),
        danger: false,
        accent: this.isFavorite
      },
      { id: 'multiplayer', title: I18n.t('multiplayer'), icon: $r('sys.symbol.wifi'), danger: false },
      { id: 'settings', title: I18n.t('settings'), icon: $r('sys.symbol.gearshape'), danger: false },
      { id: 'amiibo', title: I18n.t('amiibo'), icon: $r('sys.symbol.nfc'), danger: false }
    );
    if (this.movieMode === 'recording') {
      actions.push({ id: 'save_movie', title: I18n.t('movie_save'), icon: $r('sys.symbol.square_and_arrow_down'), danger: false });
      actions.push({ id: 'close_movie', title: I18n.t('movie_close'), icon: $r('sys.symbol.xmark_circle'), danger: true });
    } else if (this.movieMode === 'playing' || this.movieMode === 'finished') {
      actions.push({ id: 'close_movie', title: I18n.t('movie_close'), icon: $r('sys.symbol.xmark_circle'), danger: true });
    }
    actions.push({ id: 'reset', title: I18n.t('reset'), icon: $r('sys.symbol.arrow_counterclockwise'), danger: true });
    return actions;
  }

  @Prop movieMode: string = 'none';

  /** "更多"网格列数：单元格目标宽 ~84vp，按实测宽度自适应，至少 3 列（与 nds 一致） */
  private getMoreMenuColumnCount(): number {
    return this.moreMenuGridWidth > 0 ? Math.max(3, Math.floor(this.moreMenuGridWidth / 84)) : 3;
  }

  private getMoreMenuColumns(): string {
    return new Array<string>(this.getMoreMenuColumnCount()).fill('1fr').join(' ');
  }

  @Builder
  MenuRow(icon: Resource, title: string, danger: boolean, showArrow: boolean, onClick: () => void) {
    // primaryText 无文字色参数——WithTheme 局部注入 fontPrimary，让文案与 leading icon 同走 danger/primary 色
    WithTheme({ theme: { colors: { fontPrimary: danger ? TEXT_DANGER : TEXT_PRIMARY } } }) {
      ComposeListItem({
        contentItem: {
          iconStyle: IconType.SYSTEM_ICON,
          symbolStyle: new SymbolGlyphModifier(icon).fontColor([danger ? TEXT_DANGER : TEXT_PRIMARY]),
          primaryText: title
        },
        operateItem: showArrow ? {
          arrow: { value: $r('sys.symbol.chevron_right') }
        } : undefined
      })
        .onFocus(() => {
          this.soundEffectManager.play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          this.soundEffectManager.play(danger ? SoundEffect.CONFIRM : SoundEffect.DECIDE);
          onClick();
        })
    }
  }

  // 存档槽位行（对齐 nds）：[编号] [封面/灰方块] [操作区：上按钮行 + 下信息行]
  @Builder
  SaveStateSlotRow(slot: number) {
    Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
      Text(`${slot}`)
        .fontSize($r('sys.float.ohos_id_text_size_sub_title1'))
        .fontWeight(FontWeight.Bold)
        .fontFamily('monospace')
        .fontColor(TEXT_PRIMARY)
        .width(26)
        .textAlign(TextAlign.Center)
        .flexShrink(0)

      // 预览：有截图→截图；无截图一律浅色底（对齐 nds）
      // 截图为双屏左右拼接 720x240（恒 3:1），列表只裁剪显示上屏 5:3（完整双屏留给详情弹窗）：
      // ImageFit 的 TOP_START/TOP_END 是不缩放按原尺寸贴边，不能用；这里让图按 3:1 等高渲染（宽 180），
      // Stack 按起端/尾端对齐裁出 100 宽窗口，恰好落在上屏 400px 区域（swap 时上屏在右改用 TopEnd）
      Stack({ alignContent: this.swapScreensEnabled ? Alignment.TopEnd : Alignment.TopStart }) {
        if (this.hasUsableScreenshot(slot)) {
          Image(toImageUri(this.saveStateInfo(slot)!.screenshotPath))
            .height('100%')
            .aspectRatio(3)
            .objectFit(ImageFit.Cover)
            .onError(() => {
              this.markScreenshotFailed(this.saveStateInfo(slot)!.screenshotPath);
            })
        }
      }
      .width(100)
      .height(60)
      .backgroundColor(SURFACE_TRACK)
      .borderRadius(`${this.coverCornerRadius}%`)
      .clip(true)
      .onClick(() => {
        if (this.saveStateInfo(slot)) {
          this.soundEffectManager.play(SoundEffect.DECIDE);
          this.openSaveStateDetail(slot);
        }
      })

      // 操作区：按钮行 + 信息行（仅已有存档显示信息）；存/读档按钮间距走系统元素间水平大间距
      // token（16vp，比 nds 的 12vp 更宽一档），防误触
      Column() {
        Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_l') }) {
          // 圆形 icon 按钮：与首页右上角搜索/更多按钮同规格——40vp 图标热区 + 24vp 标题栏菜单图标
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.save'))
              .fontSize($r('sys.float.ohos_id_navigation_bar_menu_icon_size'))
              .fontColor([TEXT_PRIMARY])
          }
          .width($r('sys.float.ohos_id_textfield_icon_hot_zone_size'))
          .height($r('sys.float.ohos_id_textfield_icon_hot_zone_size'))
          .backgroundColor(BUTTON_BG_SECONDARY)
          .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
          .onFocus(() => {
            this.soundEffectManager.play(SoundEffect.FOCUS);
          })
          .onClick(() => {
            this.soundEffectManager.play(SoundEffect.CONFIRM);
            this.saveStateToSlot(slot);
          })

          if (this.saveStateInfo(slot)) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.upload'))
                .fontSize($r('sys.float.ohos_id_navigation_bar_menu_icon_size'))
                .fontColor([TEXT_PRIMARY])
            }
            .width($r('sys.float.ohos_id_textfield_icon_hot_zone_size'))
            .height($r('sys.float.ohos_id_textfield_icon_hot_zone_size'))
            .backgroundColor(BUTTON_BG_SECONDARY)
            .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
            .onFocus(() => {
              this.soundEffectManager.play(SoundEffect.FOCUS);
            })
            .onClick(() => {
              this.soundEffectManager.play(SoundEffect.CONFIRM);
              this.loadStateFromSlot(slot);
            })
          }
        }

        if (this.saveStateInfo(slot)) {
          Text(`${formatSaveStateTime(this.saveStateInfo(slot)!.time)}${this.saveStateInfo(slot)!.fileSize > 0 ? `（${formatFileSize(this.saveStateInfo(slot)!.fileSize)}）` : ''}`)
            .fontSize($r('sys.float.ohos_id_text_size_body3'))
            .fontFamily('monospace')
            .fontColor(TEXT_SECONDARY)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({
      left: $r('sys.float.ohos_id_default_padding_start'),
      right: $r('sys.float.ohos_id_default_padding_end'),
      top: $r('sys.float.ohos_id_text_paragraph_margin_xs'),
      bottom: $r('sys.float.ohos_id_text_paragraph_margin_xs')
    })
  }

  @Builder
  CardDivider() {
    Divider()
      .strokeWidth('1px')
      .color($r('sys.color.ohos_id_color_list_separator'))
      .margin({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
  }

  // 菜单行：ComposeListItem 标准行；图标不高亮（主文本色）。
  // 窄屏：分区行 chevron_up/down 标记展开态，直跳动作行无箭头；宽屏分栏：分区行无箭头、
  // 当前分区行由外层底纹标记（对齐设置页宽屏分类行），直跳动作行保留右箭头。
  // 展开/激活态必须在 builder 内部读 this.activeSection 实时求值——@Builder 参数按值传递，传值进来不会刷新
  @Builder
  MenuEntry(icon: Resource, title: string, section: string, onClick: () => void) {
    ComposeListItem({
      contentItem: {
        iconStyle: IconType.SYSTEM_ICON,
        symbolStyle: new SymbolGlyphModifier(icon).fontColor([TEXT_PRIMARY]),
        primaryText: title
      },
      operateItem: this.isWideLayout()
        ? (section.length === 0 ? { arrow: { value: $r('sys.symbol.chevron_right') } } : undefined)
        : (section.length === 0 ? undefined : {
          arrow: this.verticalChevron(this.activeSection === section ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        })
    })
      .onFocus(() => { this.soundEffectManager.play(SoundEffect.FOCUS); })
      .onClick(() => {
        this.soundEffectManager.play(SoundEffect.SELECT);
        onClick();
      })
  }



  // ComposeListItem 箭头槽只有 12vp 宽（字形按 24vp 居中绘制，槽右再留 6vp end margin）：
  // 设置页的 chevron_right 是竖向窄字形、墨迹在槽内；chevron_up/down 是横向宽字形，墨迹左右溢出槽外
  // 吃掉 end margin、贴到按压高亮右缘。只左移字形补偿溢出，颜色/字号仍走组件默认（与设置页箭头一致）
  private verticalChevron(res: Resource): OperateIcon {
    return { value: res, symbolStyle: new SymbolGlyphModifier(res).offset({ x: VERTICAL_CHEVRON_OFFSET_X }) };
  }

  // 窄屏菜单行：与设置页同构包进 List > ListItemGroup(CARD) > ListItem——按压高亮由 CARD 组的
  // ListItem 提供（盖满整行、箭头留出间距）；裸 Column 里只剩 ComposeListItem 内部那层贴箭头的高亮。
  // 每行单独成组以便展开区仍作为卡片 Column 的兄弟节点内联；组外边距、内边距全清零
  // （上下 4vp 由卡片 Column 统一垫，左右只留 ComposeListItem 自带的 4vp，同 menuGroupPadding），底色由外层卡片提供
  @Builder
  NarrowMenuRow(icon: Resource, title: string, section: string, onClick: () => void) {
    List() {
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          this.MenuEntry(icon, title, section, onClick)
        }
      }
      .margin(0)
      .padding(0)
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
  }

  /** 手动槽位序列 1..N（槽 0 是快速存/读档专用槽（对齐桌面端），不进手动槽位列表） */
  private manualSlots(): number[] {
    const count = Math.max(1, Math.floor(this.saveStateSlotCount));
    const slots: number[] = [];
    for (let i = 1; i <= count; i++) {
      slots.push(i);
    }
    return slots;
  }

  /** 自动滚动目标下标（对齐 nds/ppsspp）：首个空槽位；全满指向末槽，全空/很少时回 0 不滚动 */
  private savesScrollTargetIndex(): number {
    const slots = this.manualSlots();
    const index = slots.findIndex((slot: number) => this.saveStateInfo(slot) === undefined);
    return index < 0 ? slots.length - 1 : index;
  }

  @Builder
  SavesContent() {
    List({ scroller: this.savesScroller }) {
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ForEach(this.manualSlots(), (slot: number) => {
          ListItem() {
            this.SaveStateSlotRow(slot)
          }
        }, (slot: number) => `${slot}`)
      }
      .divider(settingsGroupDivider())
      .backgroundColor(listCardBgOf(this.uiThemeColors))
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    // END 对齐让首个空槽落在列表底部（对齐 nds）：可见区 = 最近几个已有存档 + 1 个空槽；
    // 目标靠前（如只有槽 1 有档）对齐量钳到 0，列表保持从顶部显示，不会把前面的槽顶出屏幕
    .onAppear(() => {
      const index = this.savesScrollTargetIndex();
      if (index > 0) {
        this.savesScroller.scrollToIndex(index, true, ScrollAlign.END);
      }
    })
  }

  private enabledCheatCount(): number {
    let count = 0;
    this.cheats.forEach((cheat: AzaharCheatInfo) => {
      if (cheat.enabled) {
        count += 1;
      }
    });
    return count;
  }

  // 工具行圆形图标按钮：与详情页金手指 Tab 的 CircleActionButton 同规格
  // （40vp 图标热区 + 标题栏菜单图标 + 白卡磨砂底）
  @Builder
  private CircleActionButton(icon: Resource, onClick: () => void) {
    Button() {
      SymbolGlyph(icon)
        .fontSize($r('sys.float.ohos_id_navigation_bar_menu_icon_size'))
        .fontColor([TEXT_PRIMARY])
    }
    .type(ButtonType.Circle)
    .width($r('sys.float.ohos_id_textfield_icon_hot_zone_size'))
    .height($r('sys.float.ohos_id_textfield_icon_hot_zone_size'))
    .backgroundColor(listCardBgOf(this.uiThemeColors))
    .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN, true))
    .onFocus(() => {
      this.soundEffectManager.play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      this.soundEffectManager.play(SoundEffect.DECIDE);
      onClick();
    })
  }

  // 金手指分区：布局对齐详情页金手指 Tab——顶部警告 + 工具行（启用统计/全部禁用/导入/新增），下方列表
  @Builder
  CheatsContent() {
    Column() {
      Text(I18n.t('cheat_warning'))
        .fontSize($r('sys.float.ohos_id_text_size_body2'))
        .fontColor(TEXT_SECONDARY)
        .width('100%')
        .padding({
          left: $r('sys.float.ohos_id_default_padding_start'),
          right: $r('sys.float.ohos_id_default_padding_end'),
          top: $r('sys.float.ohos_id_elements_margin_vertical_m'),
          bottom: $r('sys.float.ohos_id_elements_margin_vertical_m')
        })

      Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
        Text(I18n.tf2('cheats_enabled_count_fmt', 'enabled', this.enabledCheatCount(), 'total', this.cheats.length))
          .fontSize($r('sys.float.ohos_id_text_size_body2'))
          .fontColor(TEXT_SECONDARY)
          .layoutWeight(1)

        if (this.enabledCheatCount() > 0) {
          this.CircleActionButton($r('sys.symbol.nosign'), () => {
            this.disableAllCheats();
          })
        }
        this.CircleActionButton($r('sys.symbol.square_and_arrow_down'), () => {
          this.importCheats();
        })
        this.CircleActionButton($r('sys.symbol.plus'), () => {
          this.beginAddCheat();
        })
      }
      .width('100%')
      .padding({
        left: $r('sys.float.ohos_id_default_padding_start'),
        right: $r('sys.float.ohos_id_default_padding_end'),
        bottom: $r('sys.float.ohos_id_elements_margin_vertical_m')
      })

      List() {
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ForEach(this.cheats, (cheat: AzaharCheatInfo) => {
            ListItem() {
              ToggleSettingItem({
                title: cheat.name || I18n.t('unnamed_cheat'),
                isOn: cheat.enabled,
                onToggle: (isOn: boolean) => {
                  this.toggleCheat(cheat, isOn);
                }
              })
                .onClick(() => {
                  this.soundEffectManager.play(SoundEffect.DECIDE);
                  this.viewCheatDetail(cheat);
                })
            }
          }, (cheat: AzaharCheatInfo) => `${cheat.index}-${cheat.name}`)
        }
        .padding(menuGroupPadding())
        .divider(settingsGroupDivider())
        .backgroundColor(listCardBgOf(this.uiThemeColors))
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  /** 滤镜网格列数：单元格目标宽 ~150vp 按实测宽度自适应（比设置页 170 略小），至少 2 列 */
  private getFilterGridColumnCount(): number {
    return this.filterGridWidth > 0 ? Math.max(2, Math.floor(this.filterGridWidth / 150)) : 3;
  }

  private getFilterGridColumns(): string {
    return new Array<string>(this.getFilterGridColumnCount()).fill('1fr').join(' ');
  }

  /** 选中滤镜下标；未匹配到（自定义 shader 名等）返回 -1 不滚动 */
  private selectedFilterIndex(): number {
    const list = screenFilterItems();
    for (let i = 0; i < list.length; i++) {
      if (list[i].value === this.screenFilter) {
        return i;
      }
    }
    return -1;
  }

  // 屏幕滤镜：与设置页同款预览卡网格（卡片自带选中态/音效/持久化+applyConfig），
  // 暂停下切换只是写设置，恢复游戏后下一帧生效。
  // 自带滚动的 Grid（scrollToIndex 定位选中卡），与 Scroll 平级不嵌套
  @Builder
  FiltersContent() {
    Grid(this.filterScroller) {
      ForEach(screenFilterItems(), (item: ScreenFilterItem) => {
        GridItem() {
          ScreenFilterCard({ item: item, neutral: true })
        }
      }, (item: ScreenFilterItem) => item.value)
    }
    .columnsTemplate(this.getFilterGridColumns())
    .onAreaChange((_old: Area, area: Area) => {
      const w = Math.round(Number(area.width));
      if (w > 0 && w !== this.filterGridWidth) {
        this.filterGridWidth = w;
      }
    })
    .rowsGap($r('sys.float.ohos_id_card_margin_middle'))
    .columnsGap($r('sys.float.ohos_id_card_margin_middle'))
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .padding({
      left: $r('sys.float.ohos_id_default_padding_start'),
      right: $r('sys.float.ohos_id_default_padding_end'),
      top: $r('sys.float.ohos_id_elements_margin_vertical_m'),
      bottom: $r('sys.float.ohos_id_elements_margin_vertical_m')
    })
    .onAppear(() => {
      const index = this.selectedFilterIndex();
      if (index > 0) {
        this.filterScroller.scrollToIndex(index, false, ScrollAlign.CENTER);
      }
    })
  }

  // 更多菜单：九宫格大图标样式（每行3个）
  @Builder
  MoreContent() {
    Grid() {
      // key 带上 icon id：收藏切换时同一 action.id 的图标变化需要触发重建，否则 ForEach 复用旧项
      ForEach(this.moreActions(), (action: MoreMenuAction) => {
        GridItem() {
          Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
            Stack() {
              SymbolGlyph(action.icon)
                .fontSize(32)
                .fontColor([action.danger ? TEXT_DANGER : action.accent ? controlAccentOf(this.uiThemeColors) : TEXT_PRIMARY])
            }
            .width(56)
            .height(56)
            .backgroundColor(BUTTON_BG_SECONDARY)
            .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
            .borderRadius($r('sys.float.ohos_id_corner_radius_default_m'))

            Text(action.title)
              .fontSize($r('sys.float.ohos_id_text_size_body3'))
              .fontColor(TEXT_PRIMARY)
              .maxLines(2)
              .textAlign(TextAlign.Center)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding($r('sys.float.ohos_id_elements_margin_vertical_m'))
          .useEffect(true)
          .onFocus(() => {
            this.soundEffectManager.play(SoundEffect.FOCUS);
          })
          .onClick(() => {
            this.soundEffectManager.play(action.danger ? SoundEffect.CONFIRM : SoundEffect.DECIDE);
            if (action.id === 'favorite') {
              this.toggleFavorite();
            } else if (action.id === 'multiplayer') {
              this.showMultiplayerSheet = true;
            } else if (action.id === 'amiibo') {
              this.showAmiiboSheet = true;
            } else if (action.id === 'undo_save' && action.slot !== undefined) {
              this.undoSaveState(action.slot);
            } else {
              this.handleRuntimeMenuAction(action.id);
            }
          })
        }
      }, (action: MoreMenuAction) => `${action.id}_${action.icon.id}`)
    }
    .columnsTemplate(this.getMoreMenuColumns())
    .onAreaChange((_old: Area, area: Area) => {
      const w = Math.round(Number(area.width));
      if (w > 0 && w !== this.moreMenuGridWidth) {
        this.moreMenuGridWidth = w;
      }
    })
    .rowsGap($r('sys.float.ohos_id_card_margin_middle'))
    .columnsGap($r('sys.float.ohos_id_card_margin_middle'))
    .width('100%')
    .padding({
      left: $r('sys.float.ohos_id_default_padding_start'),
      right: $r('sys.float.ohos_id_default_padding_end'),
      top: $r('sys.float.ohos_id_elements_margin_vertical_m'),
      bottom: $r('sys.float.ohos_id_elements_margin_vertical_m')
    })
  }

  // 分区内容区：窄屏内联在被点选项下方、宽屏作右栏常驻面板，占满剩余空间，内容内部滚动。
  // saves 用自带滚动的 List（需要 initialIndex 定位首个空槽）、filters 用自带滚动的
  // Grid（scrollToIndex 定位选中滤镜），与 Scroll 平级不嵌套
  @Builder
  ExpandedArea() {
    if (this.panelSection() === 'saves') {
      this.SavesContent()
    } else if (this.panelSection() === 'filters') {
      this.FiltersContent()
    } else {
      Scroll() {
        Column() {
          if (this.panelSection() === 'cheats') {
            this.CheatsContent()
          } else if (this.panelSection() === 'more') {
            this.MoreContent()
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  // 窄屏展开区内联挂点：包一层 Column 统一挂 layoutWeight + 展开/收起过渡
  // （ExpandedArea 各区根节点不同——List/Grid/Scroll，没法单点挂 transition）。
  // 过渡用 scaleY→0 且锚点在顶部边缘：收起时下缘收拢到菜单行下缘（折叠回行内），
  // 不用 move——位移会让整块内容看起来飞向屏幕顶部
  @Builder
  ExpandedAreaWrap() {
    Column() {
      this.ExpandedArea()
    }
    .width('100%')
    .layoutWeight(1)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 1, y: 0, centerX: '50%', centerY: '0%' })))
  }

  // 顶部游戏信息：包体 Icon+标题靠左（窄屏/宽屏左列共用）；与卡片共用 card_margin_start 内边距后
  // 再加 default_padding_start，Icon 落在 ComposeListItem 行图标槽同一起点，标题随 30vp Icon 落在行文字列附近
  @Builder
  MenuHeader() {
    Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
      if (this.gameIcon) {
        Image(this.gameIcon)
          .width(30)
          .height(30)
          .objectFit(ImageFit.Cover)
          .borderRadius(RADIUS_SM)
      }
      Text(this.gameTitle)
        .fontSize($r('sys.float.ohos_id_text_size_sub_title1'))
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_PRIMARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end'), top: $r('sys.float.ohos_id_elements_margin_vertical_m'), bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })
  }

  // 底部固定按钮栏（对齐 nds）：继续游戏强调态 + 返回主菜单危险色文字，一行两个（窄屏布局用；宽屏对齐 nds 改菜单行）
  @Builder
  BottomActions() {
    Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_l') }) {
      Button() {
        Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize($r('sys.float.ohos_id_min_circle_button_icon_size'))
            .fontColor([TEXT_ON_ACCENT])
          Text(I18n.t('pause_action_resume'))
            .fontSize($r('sys.float.ohos_id_text_size_button2'))
            .fontColor(TEXT_ON_ACCENT)
        }
      }
      .type(ButtonType.Capsule)
      .layoutWeight(3)
      .height($r('sys.float.ohos_id_button_height'))
      .backgroundColor(controlAccentOf(this.uiThemeColors))
      .onFocus(() => { this.soundEffectManager.play(SoundEffect.FOCUS); })
      .onClick(() => {
        this.soundEffectManager.play(SoundEffect.BACK);
        this.handleRuntimeMenuAction('resume');
      })

      Button() {
        Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
          SymbolGlyph($r('sys.symbol.arrow_right_and_square'))
            .fontSize($r('sys.float.ohos_id_min_circle_button_icon_size'))
            .fontColor([TEXT_DANGER])
          Text(I18n.t('back_to_main_menu'))
            .fontSize($r('sys.float.ohos_id_text_size_button2'))
            .fontColor(TEXT_DANGER)
        }
      }
      .type(ButtonType.Capsule)
      .layoutWeight(2)
      .height($r('sys.float.ohos_id_button_height'))
      .backgroundColor(BUTTON_BG_SECONDARY)
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
      .onFocus(() => { this.soundEffectManager.play(SoundEffect.FOCUS); })
      .onClick(() => {
        this.soundEffectManager.play(SoundEffect.CONFIRM);
        this.handleRuntimeMenuAction('exit');
      })
    }
    .width('100%')
    .margin({ top: $r('sys.float.ohos_id_card_margin_middle') })
  }

  // 窄屏单列布局：菜单卡内各分区行原位手风琴展开（展开区紧跟被点行、layoutWeight 占满
  // 卡内剩余空间内部自滚动，下方菜单行随之推移）+ 底部按钮栏
  @Builder
  NarrowLayout() {
    Column() {
      this.MenuHeader()

      Column() {
        this.NarrowMenuRow($r('sys.symbol.square_and_arrow_down'), I18n.t('save_states'), 'saves', () => {
          this.toggleMenuSection('saves');
        })
        if (this.activeSection === 'saves') {
          this.ExpandedAreaWrap()
        }
        this.CardDivider()

        this.NarrowMenuRow($r('sys.symbol.hand_raised_fingers_spread'), I18n.t('cheats'), 'cheats', () => {
          this.toggleMenuSection('cheats');
        })
        if (this.activeSection === 'cheats') {
          this.ExpandedAreaWrap()
        }
        this.CardDivider()

        this.NarrowMenuRow($r('sys.symbol.wand_and_stars'), I18n.t('settings_screen_filter'), 'filters', () => {
          this.toggleMenuSection('filters');
        })
        if (this.activeSection === 'filters') {
          this.ExpandedAreaWrap()
        }
        this.CardDivider()

        this.NarrowMenuRow($r('sys.symbol.hand_tap'), I18n.t('touch_controls'), '', () => {
          this.handleRuntimeMenuAction('touch_controls');
        })
        this.CardDivider()

        this.NarrowMenuRow($r('sys.symbol.ellipsis_circle'), I18n.t('comp_more'), 'more', () => {
          this.toggleMenuSection('more');
        })
        if (this.activeSection === 'more') {
          this.ExpandedAreaWrap()
        }
      }
      .layoutWeight(this.activeSection.length > 0 ? 1 : 0)
      .width('100%')
      // 对齐 ListItemGroup CARD 组上下内边距 4vp（左右 4vp 由各行的 CARD 组提供）
      .padding({ top: $r('sys.float.padding_level2'), bottom: $r('sys.float.padding_level2') })
      .backgroundColor(listCardBgOf(this.uiThemeColors))
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
      .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
      .clip(true)

      // 收起态：占位吸掉剩余空间，菜单卡贴合内容高度，底部按钮栏照旧钉底（对齐 nds spacer）
      if (this.activeSection.length === 0) {
        Column()
          .layoutWeight(1)
      }

      this.BottomActions()
    }
    .layoutWeight(1)
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_m'), right: $r('sys.float.ohos_id_elements_margin_horizontal_m'), bottom: $r('sys.float.ohos_id_card_margin_middle') })
  }

  // 宽屏两列布局（对齐 nds）：左列 260/200 菜单面板（信息头 + 继续游戏置顶卡 +
  // 分区菜单卡 + 返回主菜单置底卡，均为设置页同款 List + ListItemGroup CARD），右列当前分区内容卡
  @Builder
  WideLayout() {
    Row({ space: $r('sys.float.ohos_id_card_margin_middle') }) {
      Column() {
        this.MenuHeader()

        // 继续游戏：独立卡钉顶，直接动作行不带右箭头
        List() {
          ListItemGroup({ style: ListItemGroupStyle.CARD }) {
            ListItem() {
              this.MenuRow($r('sys.symbol.play_fill'), I18n.t('pause_action_resume'), false, false, () => {
                this.handleRuntimeMenuAction('resume');
              })
            }
          }
          .backgroundColor(listCardBgOf(this.uiThemeColors))
          .padding(menuGroupPadding())
        }
        .width('100%')
        .scrollBar(BarState.Off)
        .margin({ top: $r('sys.float.ohos_id_card_margin_middle') })

        List() {
          ListItemGroup({ style: ListItemGroupStyle.CARD }) {
            // .selected 系统样式画在 item 满宽矩形、按压高亮在 ComposeListItem 内部左缩 4vp 的区域，
            // 两者几何天然对不齐。解法同设置页宽屏分类行：item 收 4vp 外边距让 selected 矩形=原按压区，
            // 再给行容器 -4vp 负边距推回原位——两态高亮落在同一矩形上（圆角与设置页一致走卡片 token）
            ListItem() {
              Column() {
                this.MenuEntry($r('sys.symbol.square_and_arrow_down'), I18n.t('save_states'), 'saves', () => {
                  this.toggleMenuSection('saves');
                })
              }
              .margin({ left: -4, right: -4 })
            }
            .selected(this.activeSection === 'saves')
            .margin({ left: 4, right: 4 })
            .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
            .clip(true)
            ListItem() {
              Column() {
                this.MenuEntry($r('sys.symbol.hand_raised_fingers_spread'), I18n.t('cheats'), 'cheats', () => {
                  this.toggleMenuSection('cheats');
                })
              }
              .margin({ left: -4, right: -4 })
            }
            .selected(this.activeSection === 'cheats')
            .margin({ left: 4, right: 4 })
            .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
            .clip(true)
            ListItem() {
              Column() {
                this.MenuEntry($r('sys.symbol.wand_and_stars'), I18n.t('settings_screen_filter'), 'filters', () => {
                  this.toggleMenuSection('filters');
                })
              }
              .margin({ left: -4, right: -4 })
            }
            .selected(this.activeSection === 'filters')
            .margin({ left: 4, right: 4 })
            .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
            .clip(true)
            ListItem() {
              this.MenuEntry($r('sys.symbol.hand_tap'), I18n.t('touch_controls'), '', () => {
                this.handleRuntimeMenuAction('touch_controls');
              })
            }
            ListItem() {
              Column() {
                this.MenuEntry($r('sys.symbol.ellipsis_circle'), I18n.t('comp_more'), 'more', () => {
                  this.toggleMenuSection('more');
                })
              }
              .margin({ left: -4, right: -4 })
            }
            .selected(this.activeSection === 'more')
            .margin({ left: 4, right: 4 })
            .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
            .clip(true)
          }
          .divider(settingsGroupDivider())
          .backgroundColor(listCardBgOf(this.uiThemeColors))
          .padding(menuGroupPadding())
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .margin({ top: $r('sys.float.ohos_id_card_margin_middle') })

        // 返回主菜单：独立卡钉底，直接动作行不带右箭头
        List() {
          ListItemGroup({ style: ListItemGroupStyle.CARD }) {
            ListItem() {
              this.MenuRow($r('sys.symbol.arrow_right_and_square'), I18n.t('back_to_main_menu'), true, false, () => {
                this.handleRuntimeMenuAction('exit');
              })
            }
          }
          .backgroundColor(listCardBgOf(this.uiThemeColors))
          .padding(menuGroupPadding())
        }
        .width('100%')
        .scrollBar(BarState.Off)
        .margin({ top: $r('sys.float.ohos_id_card_margin_middle') })
      }
      .width(this.menuPanelWidth())
      .height('100%')
      .flexShrink(0)

      // 右列：当前分区内容卡，底色与设置页分组卡一致
      Column() {
        this.ExpandedArea()
      }
      .layoutWeight(1)
      .height('100%')
      .backgroundColor(listCardBgOf(this.uiThemeColors))
      .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
      .clip(true)
    }
    .width('100%')
    .height('100%')
    .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_m'), right: $r('sys.float.ohos_id_elements_margin_horizontal_m'), top: $r('sys.float.ohos_id_card_margin_middle'), bottom: $r('sys.float.ohos_id_card_margin_middle') })
  }

  build() {
    // 全屏半透明光感覆盖层（对齐 nds 暂停菜单）：半透明底透出冻结画面
    Column() {
      if (this.isWideLayout()) {
        this.WideLayout()
      } else {
        this.NarrowLayout()
      }

      // 联机弹窗组（入口/加入/创建/大厅），与网络设置页共用同一组件
      MultiplayerSheets({ showMultiplayerSheet: this.$showMultiplayerSheet })

      // Amiibo 弹窗（加载/移除入口），样式与联机入口弹窗一致
      AmiiboSheet({
        showAmiiboSheet: this.$showAmiiboSheet,
        onLoad: () => {
          this.handleRuntimeMenuAction('amiibo_load');
        },
        onRemove: () => {
          this.handleRuntimeMenuAction('amiibo_remove');
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.pause_menu_bg'))
    .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
    .transition(TransitionEffect.OPACITY)
  }
}

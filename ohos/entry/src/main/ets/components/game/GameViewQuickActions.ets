/**
 * Azahar - 游戏内快捷操作面板（"更多"按钮弹出的操作菜单）
 *
 * 行为对齐 nds 前端 More 菜单：图标网格列出全部可用快捷动作，
 * 已被当前布局直接放置的动作自动过滤；屏幕方向同为网格项，
 * 点击后由 GameView 弹方向选择列表。
 * 形态对齐 nds MoreMenuOverlay：全屏半透明遮罩 + 居中悬浮面板，
 * 点遮罩/返回键关闭，替代 bindSheet 底部弹窗以保持沉浸感。
 * 单元格尺寸对齐 nds MoreMenuGrid（图 56 / 格高 92 / 目标宽 84vp），列数按面板宽度自适应。
 */
import uiMaterial from '@ohos.arkui.uiMaterial';
import { immersiveMaterial } from '../common/AzaharControls';
import { AzaharFrontendAction, frontendActionToLayoutComponent } from './AzaharVirtualButtonLayer';
import { LayoutComponent } from '../../types/LayoutTypes';
import {
  CARD_BORDER_COLOR,
  DIALOG_SHADOW,
  OVERLAY_MASK,
  RADIUS_LG,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING,
  TEXT_PRIMARY
} from '../../types/UIConstants';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';

/** 网格候选动作顺序与 nds More 菜单一致（方向项与其他动作同为网格图标） */
const QUICK_ACTION_ORDER: AzaharFrontendAction[] = [
  'toggle_soft_input',
  'quick_save',
  'quick_load',
  'pause',
  'fast_forward',
  'slow_motion',
  'swap_screens',
  'reset',
  'toggle_lid',
  'toggle_microphone',
  'open_settings',
  'toggle_screen_orientation',
];

/** 屏幕方向合法取值（与 KEY_SCREEN_ORIENTATION 的存取值一致，面板与直放按钮共用） */
export const ORIENTATION_VALUES: string[] = ['auto', 'portrait', 'landscape'];

/** 面板与单元格规格对齐 nds：悬浮面板宽 86% 封顶 420vp；单元格目标宽 ~84vp，最少 3 列 */
const PANEL_MAX_WIDTH: number = 420;
const CELL_TARGET_WIDTH: number = 84;
const CELL_HEIGHT: number = 92;
const ICON_SIZE: number = 56;
const GRID_GAP: number = 6;
const MIN_COLUMNS: number = 3;

@Component
export struct GameViewQuickActions {
  /** 遮罩点击/返回键关闭需回写父状态，必须 @Link */
  @Link show: boolean;
  /** 当前布局已直接放置的组件：对应动作不再出现在菜单里（对齐 nds 过滤语义） */
  @Prop placedComponents: LayoutComponent[] = [];
  @Prop softInputVisible: boolean = true;
  @Prop fastForwardActive: boolean = false;
  @Prop slowMotionActive: boolean = false;
  @Prop microphoneActive: boolean = false;
  onAction: (action: AzaharFrontendAction) => void = () => {};

  /** 网格实测宽度，驱动列数自适应（对齐 nds MoreMenuOverlay） */
  @State private actionGridWidth: number = 0;

  private isPlaced(action: AzaharFrontendAction): boolean {
    const component = frontendActionToLayoutComponent(action);
    return component !== null && this.placedComponents.indexOf(component) >= 0;
  }

  /** 未直接放置的候选动作；每个动作由同一 @State 组驱动，build 时求值保持状态同步 */
  private menuActions(): AzaharFrontendAction[] {
    return QUICK_ACTION_ORDER.filter((action: AzaharFrontendAction) => !this.isPlaced(action));
  }

  private actionLabel(action: AzaharFrontendAction): string {
    switch (action) {
      case 'toggle_soft_input': return I18n.t('comp_toggle_soft_input');
      case 'quick_save': return I18n.t('comp_quick_save');
      case 'quick_load': return I18n.t('comp_quick_load');
      case 'pause': return I18n.t('comp_pause');
      case 'fast_forward': return I18n.t('comp_fast_forward');
      case 'slow_motion': return I18n.t('comp_slow_motion');
      case 'swap_screens': return I18n.t('comp_swap_screens');
      case 'reset': return I18n.t('comp_reset');
      case 'toggle_lid': return I18n.t('comp_hinge');
      case 'toggle_microphone': return I18n.t('comp_microphone');
      case 'toggle_screen_orientation': return I18n.t('comp_screen_rotation');
      default: return I18n.t('settings');
    }
  }

  private actionImage(action: AzaharFrontendAction): string {
    switch (action) {
      case 'toggle_soft_input':
        return this.softInputVisible ? 'ic_touch_enabled.png' : 'ic_touch_disabled.png';
      case 'quick_save': return 'button_quick_save.png';
      case 'quick_load': return 'button_quick_load.png';
      case 'pause': return 'button_pause.png';
      case 'fast_forward':
        return this.fastForwardActive ? 'button_fast_forward.png' : 'button_fast_forward_disabled.png';
      case 'slow_motion':
        return this.slowMotionActive ? 'button_slow_motion.png' : 'button_slow_motion_disabled.png';
      case 'swap_screens': return 'button_swap_screens.png';
      case 'reset': return 'button_reset.png';
      case 'toggle_lid': return 'button_toggle_lid.png';
      case 'toggle_microphone':
        return this.microphoneActive ? 'button_microphone.png' : 'button_microphone_disabled.png';
      case 'toggle_screen_orientation': return 'button_rotation.png';
      default: return 'setting.png';
    }
  }

  private columnCount(): number {
    return this.actionGridWidth > 0
      ? Math.max(MIN_COLUMNS, Math.floor(this.actionGridWidth / CELL_TARGET_WIDTH))
      : MIN_COLUMNS;
  }

  private gridColumns(): string {
    return new Array<string>(this.columnCount()).fill('1fr').join(' ');
  }

  /** Grid 是滚动容器默认撑满高度，按行数显式约束让面板包住内容（对齐 nds）；空菜单钳到 0 */
  private gridHeight(): number {
    const rows = Math.ceil(this.menuActions().length / this.columnCount());
    return Math.max(0, rows * CELL_HEIGHT + (rows - 1) * GRID_GAP);
  }

  build() {
    if (this.show) {
      Stack({ alignContent: Alignment.Center }) {
        // 半透明遮罩：onTouch 阻断触摸穿透到游戏/按键层，点击关闭
        Column()
          .width('100%')
          .height('100%')
          .onTouch((event: TouchEvent) => { event.stopPropagation(); })
          .onClick(() => {
            SoundEffectManager.getInstance().play(SoundEffect.BACK);
            this.show = false;
          })

        // 居中悬浮面板：底对齐暂停菜单 pause_menu_bg（92%，同 nds 面板 90% 量级），
        // 半透明底让沉浸光感材质透出游戏画面
        Column() {
          Grid() {
            ForEach(this.menuActions(), (action: AzaharFrontendAction) => {
              GridItem() {
                Column() {
                  Image($rawfile(`themes/default/${this.actionImage(action)}`))
                    .width(ICON_SIZE)
                    .height(ICON_SIZE)
                    .objectFit(ImageFit.Contain)
                    .draggable(false)
                  Text(this.actionLabel(action))
                    .fontSize($r('sys.float.ohos_id_text_size_body3'))
                    .fontWeight(FontWeight.Medium)
                    .fontColor(TEXT_PRIMARY)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 6 })
                }
                .width('100%')
                .height(CELL_HEIGHT)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
              }
              .backgroundColor(SHEET_CARD_BG)
              .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
              .stateStyles({
                pressed: {
                  .opacity(0.6)
                },
                normal: {
                  .opacity(1.0)
                }
              })
              .onClick(() => {
                SoundEffectManager.getInstance().play(SoundEffect.SELECT);
                this.show = false;
                this.onAction(action);
              })
            }, (action: AzaharFrontendAction) => action)
          }
          .columnsTemplate(this.gridColumns())
          .columnsGap(GRID_GAP)
          .rowsGap(GRID_GAP)
          .scrollBar(BarState.Off)
          .width('100%')
          .height(this.gridHeight())
          .onAreaChange((_old: Area, newArea: Area) => {
            const w = Math.round(Number(newArea.width));
            if (w > 0 && w !== this.actionGridWidth) {
              this.actionGridWidth = w;
            }
          })
        }
        .width('86%')
        .constraintSize({ maxWidth: PANEL_MAX_WIDTH })
        .padding(SHEET_CONTENT_PADDING)
        .backgroundColor($r('app.color.pause_menu_bg'))
        .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
        .borderRadius(RADIUS_LG)
        .border({ width: '1px', color: CARD_BORDER_COLOR })
        .shadow(DIALOG_SHADOW)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(OVERLAY_MASK)
      .transition(TransitionEffect.OPACITY)
    }
  }
}

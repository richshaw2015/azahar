import { SymbolGlyphModifier, LengthMetrics } from '@kit.ArkUI';

export interface PaddingConfig {
  left: Length;
  right: Length;
  top: Length;
  bottom: Length;
}

export interface ShadowConfig {
  radius: number;
  color: ResourceColor;
  offsetX: number;
  offsetY: number;
}

// ===== 3DS HOME Menu 设计语言 =====
// 浅色底 + 大圆角 + 柔和投影，强调色由主题驱动

// Surfaces —— 颜色一律走系统 token（sys.color）；
// 半透明变体系统没有对应 token，走 app.color 具名资源，不在代码里写字面量。
export const PAGE_BG: Resource = $r('sys.color.ohos_id_color_sub_background');
export const SURFACE_CARD: Resource = $r('sys.color.ohos_id_color_card_bg');
export const SURFACE_TRACK: Resource = $r('sys.color.ohos_id_color_component_normal');
export const OVERLAY_MASK: Resource = $r('app.color.overlay_mask');

// 弹层底/分组卡片：半透明底色，供 systemMaterial 透出
export const SHEET_BG: Resource = $r('app.color.sheet_bg');
export const SHEET_BG_GROUPED: Resource = $r('app.color.sheet_bg_grouped');
export const SHEET_CARD_BG: Resource = $r('app.color.sheet_card_bg');

// Borders / shadows
export const CARD_BORDER_COLOR: ResourceColor = $r('sys.color.ohos_id_color_list_separator');
export const HAIRLINE_COLOR: ResourceColor = $r('sys.color.ohos_id_color_list_separator');
/** bindMenu/bindContextMenu 的 Menu 项间分割线 — 与列表发丝分隔线一致：1px 物理像素 + list_separator */
export const MENU_ITEM_DIVIDER: DividerStyleOptions = {
  strokeWidth: LengthMetrics.px(1),
  color: HAIRLINE_COLOR,
  startMargin: LengthMetrics.vp(16),
  endMargin: LengthMetrics.vp(16)
};
export const CARD_SHADOW: ShadowConfig = { radius: 12, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 3 };
export const TILE_SHADOW: ShadowConfig = { radius: 10, color: $r('app.color.shadow_tile'), offsetX: 0, offsetY: 4 };
export const DIALOG_SHADOW: ShadowConfig = { radius: 28, color: $r('app.color.shadow_dialog'), offsetX: 0, offsetY: 8 };
export const SUBTLE_SHADOW: ShadowConfig = { radius: 6, color: $r('app.color.shadow_subtle'), offsetX: 0, offsetY: 2 };
export const CARTRIDGE_SHELL_SHADOW: ShadowConfig = { radius: 6, color: $r('app.color.shadow_shell'), offsetX: 1, offsetY: 3 };
// 3DS 按键底部"唇边"阴影与按下反馈
export const BUTTON_SHADOW: ShadowConfig = { radius: 4, color: $r('app.color.shadow_button'), offsetX: 0, offsetY: 2 };
export const BUTTON_SHADOW_PRESSED: ShadowConfig = { radius: 1, color: $r('app.color.shadow_button_pressed'), offsetX: 0, offsetY: 0.5 };
export const BUTTON_PRESS_OFFSET: number = 1.5;

// Radii —— 一律走官方圆角 token（跟随设备规范与缩放），3DS 特有形态保留字面量
export const RADIUS_XS: Resource = $r('sys.float.ohos_id_corner_radius_default_xs');
export const RADIUS_SM: Resource = $r('sys.float.ohos_id_corner_radius_default_s');
export const RADIUS_MD: Resource = $r('sys.float.ohos_id_corner_radius_default_m');
export const RADIUS_LG: Resource = $r('sys.float.ohos_id_corner_radius_default_l');
export const RADIUS_XL: Resource = $r('sys.float.ohos_id_corner_radius_default_xl');
export const RADIUS_DIALOG: Resource = $r('sys.float.ohos_id_corner_radius_dialog');
// bindSheet 面板顶角圆角：与系统半模态外壳同一 token（32vp）。
// RADIUS_DIALOG(24vp) 是居中弹窗规格，只留给 CustomDialog/浮层用
export const RADIUS_SHEET: Resource = $r('sys.float.window_radius_small');
export const RADIUS_FULL: number = 999;

// Selected state (3DS 选中图标：主题色描边 + 放大)
export const SELECTED_RING_WIDTH: number = 3;
export const SELECTED_SCALE: number = 1.08;

// 封面圆角：占封面边长的百分比（默认值与历史硬编码 '11%' 一致）
export const COVER_RADIUS_DEFAULT: number = 4;
export const COVER_RADIUS_MAX: number = 50;
// 封面尺寸 — 网格滑杆默认卡宽 160vp；内部卡带元素按旧版 108vp 设计尺寸同比缩放
export const GRID_COVER_BASE: number = 160;
export const GRID_COVER_CONTENT_BASE: number = 108;
export const LIST_COVER_BASE: number = 64;
export const GRID_COVER_SIZE_MIN: number = 80;
export const GRID_COVER_SIZE_MAX: number = 320;
export const LIST_COVER_SIZE_MIN: number = 48;
export const LIST_COVER_SIZE_MAX: number = 192;

// HdsNavigation 悬浮标题栏占位：内容铺满全屏滚动时，滚动内容顶部需垫出标题栏高度
export const NAV_TITLE_SCROLL_SPACE: number = 64;

// HDS 标题栏默认内间距随页面宽度分档（HdsNavigation PaddingOptions 文档）：
// 起始端 <600vp→16，≥840vp→32，其间→24；结束端 <600vp→16，≥800vp→32，其间→24
export function titleBarEdgeInsetVp(pageWidthVp: number, edge: 'start' | 'end'): number {
  const wideBreakpoint = edge === 'start' ? 840 : 800;
  return pageWidthVp >= wideBreakpoint ? 32 : pageWidthVp >= 600 ? 24 : 16;
}

// 标题栏两端圆形按钮槽位：按钮热区 40vp + 与内容的 8vp 间距
const TITLE_BAR_BUTTON_SLOT_VP: number = 48;

// stackBuilder 叠层覆盖整条标题栏，自定义内容避让两端按钮 = 档位内间距 + 按钮槽位；
// <600vp 时为 16+48=64，宽屏档位相应右扩
export function titleBarButtonAvoidVp(pageWidthVp: number, edge: 'start' | 'end'): number {
  return titleBarEdgeInsetVp(pageWidthVp, edge) + TITLE_BAR_BUTTON_SLOT_VP;
}

// 标题栏分段控件（TabSegmentButtonV2 图文混排：图标在上、文字在下）统一规格，
// 首页/游戏详情/手柄设置共用。系统双行默认 item 60/button 64 留白偏多，收紧为
// item 48 + 上下 padding 2 + button 52；栏区 60 = button 52 + 8vp 外边距，
// 与原单行栏区 48 = button 40 + 8 同一约定。列表顶部垫高统一按
// NAV_TITLE_SCROLL_SPACE + SEGMENT_BAR_HEIGHT 预留
export const SEGMENT_BAR_HEIGHT: number = 60;
export const SEGMENT_ITEM_MIN_HEIGHT: LengthMetrics = LengthMetrics.vp(48);
export const SEGMENT_ITEM_PADDING: LocalizedPadding = {
  top: LengthMetrics.vp(2),
  bottom: LengthMetrics.vp(2),
  start: LengthMetrics.vp(8),
  end: LengthMetrics.vp(8)
};
export const SEGMENT_BUTTON_MIN_HEIGHT: LengthMetrics = LengthMetrics.vp(52);
export const SEGMENT_SYMBOL_FONT_SIZE: LengthMetrics = LengthMetrics.vp(18);

export const TITLE_BAR_ICON_COLOR: Resource = $r('sys.color.ohos_id_color_titlebar_icon');

// 统一返回箭头规格：chevron_left 是窄字形，fontSize 30 时油墨高约 50px
//（真机实测对齐系统 HDS 标题栏返回箭头，约为菜单图标油墨高度的 0.78 倍）
export const NAV_BACK_ICON_FONT_SIZE: number = 30;
export function navBackIconModifier(): SymbolGlyphModifier {
  return new SymbolGlyphModifier($r('sys.symbol.chevron_left'))
    .fontSize(NAV_BACK_ICON_FONT_SIZE)
    .fontColor([TITLE_BAR_ICON_COLOR]);
}

// 卡片内行的标准内边距：水平对齐 ComposeListItem 内部 padding（default_padding_*=12vp；
// composeListItem_padding 同为 12vp 但属组件私有资源，应用侧解析为 0 不可用），
// 垂直用大档——卡片分隔线下方的首个元素需要与 ComposeListItem 行的固有间距一致
export const SETTING_ITEM_PADDING: PaddingConfig = {
  left: $r('sys.float.ohos_id_default_padding_start'),
  right: $r('sys.float.ohos_id_default_padding_end'),
  top: $r('sys.float.ohos_id_elements_margin_vertical_l'),
  bottom: $r('sys.float.ohos_id_elements_margin_vertical_l')
};

// 弹层（bindSheet 半模态 / 浮层弹窗）内容边距：四边统一 16vp（padding_level8）。
// 顶/右 16vp 时 40vp 关闭按钮圆心落在 (W−36,36)，相对 RADIUS_SHEET(32vp)
// 圆角弧心 (W−32,32) 外扩 4vp。勿用
// ohos_id_default_padding_top/bottom_fixed（12/24vp，是菜单类弹层的内容规格，
// 用在标题区会显得上宽下坠）
export const SHEET_CONTENT_PADDING: PaddingConfig = {
  left: $r('sys.float.padding_level8'),
  right: $r('sys.float.padding_level8'),
  top: $r('sys.float.padding_level8'),
  bottom: $r('sys.float.padding_level8')
};

export const SETTING_ITEM_BG: Resource = $r('sys.color.ohos_id_color_list_card_bg');
export const TEXT_PRIMARY: Resource = $r('sys.color.ohos_id_color_text_primary');
export const TEXT_SECONDARY: Resource = $r('sys.color.ohos_id_color_text_secondary');
export const TEXT_DISABLED: Resource = $r('sys.color.ohos_fa_text_fourth');
export const TEXT_WARNING: Resource = $r('sys.color.ohos_fa_warning');
export const TEXT_DANGER: Resource = $r('sys.color.ohos_id_color_warning');
export const TEXT_ON_ACCENT: Resource = $r('sys.color.ohos_id_color_text_primary_contrary');

// 字号统一走系统 token，不写死数值：跟随系统字号缩放设置，且与系统组件视觉一致。
export const FONT_SIZE_PAGE_TITLE: Resource = $r('sys.float.ohos_id_text_size_headline8');    // 20
export const FONT_SIZE_SETTING_TITLE: Resource = $r('sys.float.ohos_id_text_size_body1');     // 16
export const FONT_SIZE_SETTING_DESC: Resource = $r('sys.float.ohos_id_text_size_body2');      // 14
export const FONT_SIZE_MIN: Resource = $r('sys.float.ohos_id_text_size_body3');               // 12
// 行内引导图标规格：与系统工具栏/列表图标一致
export const ICON_SIZE_ROW: Resource = $r('sys.float.ohos_id_toolbar_item_icon_size');

export const BUTTON_HEIGHT_SM: Resource = $r('sys.float.control_button_height_small');
// Sheet/弹层底部操作按钮与编辑器底部动作条的统一高度规范（SheetButton 规范）
export const SHEET_BUTTON_HEIGHT: number = 44;
export const BUTTON_BG_SECONDARY: Resource = $r('sys.color.ohos_id_color_button_normal');
export const BUTTON_ICON_SM: Resource = $r('sys.float.ohos_id_min_circle_button_icon_size');

// 输入框规格：全部对齐系统 TextInput 默认尺寸
export const INPUT_HEIGHT: Resource = $r('sys.float.ohos_id_textfield_height');
export const INPUT_BORDER_RADIUS: Resource = $r('sys.float.ohos_id_corner_radius_text_field');
export const INPUT_BG_INLINE: Resource = $r('sys.color.ohos_id_color_text_field_sub_bg');
export const INPUT_FONT_SIZE: Resource = $r('sys.float.ohos_id_text_size_body2');             // 14
export const INPUT_PADDING_H: Resource = $r('sys.float.ohos_id_textfield_padding_horizontal');

export const OPACITY_DISABLED: Resource = $r('sys.float.ohos_id_alpha_disabled');

// ===== 3DS 机身元素 =====
export const BUTTON_3DS_RING: string = 'rgba(0,0,0,0.12)';
export const DPAD_COLOR: string = '#3A3A42';
export const CIRCLE_PAD_COLOR: string = '#CFCFD4';
export const ABXY_BUTTON_BG: string = '#F8F8FA';
export const ABXY_A_COLOR: string = '#E8504E';
export const ABXY_B_COLOR: string = '#F0A020';
export const ABXY_X_COLOR: string = '#3B8FE8';
export const ABXY_Y_COLOR: string = '#58B04C';

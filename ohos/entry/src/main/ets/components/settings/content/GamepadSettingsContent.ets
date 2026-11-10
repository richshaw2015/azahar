import { ColorMetrics, ComposeListItem, SegmentButtonV2Items, SymbolGlyphModifier, TabSegmentButtonV2, uiMaterial } from '@kit.ArkUI';
import { inputDevice } from '@kit.InputKit';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { SliderSettingItem } from '../SliderSettingItem';
import { ToggleSettingItem } from '../ToggleSettingItem';
import { GamepadBindingItem } from '../GamepadBindingItem';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, StaticInfoRow, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { controlAccentOf, immersiveMaterial } from '../../../components/common/AzaharControls';
import { SheetButton, SheetTitleBar } from '../../common/MultiplayerSheets';
import { AzaharKey, AzaharNative } from '../../../types/AzaharNative';
import { I18n } from '../../../utils/I18nManager';
import { SettingsManager } from '../../../utils/SettingsManager';
import { SoundEffect, SoundEffectManager } from '../../../utils/SoundEffectManager';
import { NAV_TITLE_SCROLL_SPACE, RADIUS_SHEET, SEGMENT_BAR_HEIGHT, SEGMENT_BUTTON_MIN_HEIGHT, SEGMENT_ITEM_MIN_HEIGHT, SEGMENT_ITEM_PADDING, SEGMENT_SYMBOL_FONT_SIZE, SHEET_CONTENT_PADDING, TEXT_ON_ACCENT, SHEET_BG_GROUPED, SHEET_CARD_BG, BUTTON_BG_SECONDARY, BUTTON_ICON_SM, FONT_SIZE_SETTING_DESC, FONT_SIZE_SETTING_TITLE, ICON_SIZE_ROW, TEXT_DANGER, TEXT_PRIMARY, TEXT_SECONDARY } from '../../../types/UIConstants';
import { KEY_GAMEPAD_AXIS_MAP, KEY_GAMEPAD_BUTTON_MAP, KEY_GAMEPAD_COMBO, KEY_GAMEPAD_DEADZONE, KEY_GAMEPAD_HOTKEY_MAP, KEY_USE_ARTIC_BASE_CONTROLLER } from '../../../types/SettingsTypes';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { isKeyboardBindableButton, KeyboardBindingManager } from '../../../utils/KeyboardBindingManager';
import { AzaharThemeColors } from '../../../types/ThemeTypes';


// 3DS 手柄按键（与 core Settings::NativeButton 顺序一致）
const NB_A = 0;
const NB_B = 1;
const NB_X = 2;
const NB_Y = 3;
const NB_UP = 4;
const NB_DOWN = 5;
const NB_LEFT = 6;
const NB_RIGHT = 7;
const NB_L = 8;
const NB_R = 9;
const NB_START = 10;
const NB_SELECT = 11;
const NB_ZL = 14;
const NB_ZR = 15;
const NB_HOME = 16;
const NATIVE_BUTTON_COUNT = 18;

// 出厂映射：3DS 按键索引 -> OHOS 手柄键码（与 ohos_gamepad.cpp 中 g_map 默认值一致，-1 未绑定）
const DEFAULT_CODES: number[] = [
  2301, 2302, 2304, 2305, // A B X Y
  2012, 2013, 2014, 2015, // 十字键
  2307, 2308, 2312, 2311, // L R Start Select
  -1, -1, // Debug Gpio14（无物理绑定，占位对齐 native 索引）
  2309, 2310, // ZL ZR
  2313, // Home (BUTTON_MODE, 无 GCK 监视器，经 ArkUI KeyEvent 通道)
  -1 // Power
];

// 覆盖测试的目标物理键（手柄图上可见的 17 个键）
const TEST_KEY_CODES: number[] = [
  2301, 2302, 2304, 2305, 2307, 2308, 2309, 2310, 2311, 2312, 2313, 2314, 2315,
  2012, 2013, 2014, 2015
];
// 顶部分段控件 tab 下标：映射 / 热键 / 测试 / 杂项（独立页面与设置分栏详情共用）
export const GAMEPAD_TAB_MAPPING: number = 0;
export const GAMEPAD_TAB_HOTKEYS: number = 1;
export const GAMEPAD_TAB_TEST: number = 2;
export const GAMEPAD_TAB_SETTINGS: number = 3;

const TEST_POLL_MS = 33;
const TEST_FLASH_MS = 200;
const TEST_LOG_SIZE = 8;
const TEST_TRAIL_SIZE = 30;
// 圆度测试：按角度分 72 个扇区（每 5°）记录到过的最远半径；覆盖 90% 扇区才出结果
const ENVELOPE_BUCKETS = 72;
const ENVELOPE_MIN_COVERAGE = 0.9;
// 摇杆示波器边长（vp）与有效半径
const SCOPE_SIZE = 140;
const SCOPE_RADIUS = 62;

interface TestLogEntry {
  seq: number;
  code: number;
  // 归一前的原始上报码（ButtonC 2303 → HOME 2313 时能看到手柄实际报的码）
  rawCode: number;
  down: boolean;
  timeMs: number;
}

interface ButtonRow {
  title: string;
  nativeButton: number;
}

/** 单条物理输入绑定：kind=pad 进手柄映射表，kind=kbd 进键盘映射表 */
interface BindEntry {
  kind: string;
  code: number;
  label: string;
  icon: Resource;
}

/** 常用键码 → 展示名；未收录的键码显示为 "Key N"（不阻塞绑定，仅影响展示） */
const KEY_NAME_MAP: Record<number, string> = {
  2012: '↑', 2013: '↓', 2014: '←', 2015: '→',
  2017: 'A', 2018: 'B', 2019: 'C', 2020: 'D', 2021: 'E', 2022: 'F', 2023: 'H', 2024: 'G',
  2025: 'I', 2026: 'J', 2027: 'K', 2028: 'L', 2029: 'M', 2030: 'N', 2031: 'O', 2032: 'P',
  2033: 'Q', 2034: 'R', 2035: 'S', 2036: 'T', 2037: 'U', 2038: 'V', 2039: 'W', 2040: 'X',
  2041: 'Y', 2042: 'Z',
  2000: '0', 2001: '1', 2002: '2', 2003: '3', 2004: '4', 2005: '5', 2006: '6', 2007: '7',
  2008: '8', 2009: '9',
  2045: 'Shift L', 2046: 'Shift L', 2047: 'Shift R', 2048: 'Shift R',
  2049: 'Ctrl L', 2050: 'Ctrl R', 2051: 'Alt L', 2052: 'Alt R',
  2054: 'Enter', 2055: 'Space', 2056: 'Tab', 2057: 'Backspace', 2070: 'Esc',
  2067: '-', 2068: '=', 2061: '[', 2062: ']', 2063: '\\', 2066: ';', 2065: "'", 2071: '`',
  2072: ',', 2073: '.', 2074: '/'
};

function keyCodeName(code: number): string {
  return KEY_NAME_MAP[code] ?? `Key ${code}`;
}

/** GameView 硬编码占用的键码：快存/快读/重置在映射表之前被拦截，绑成按键不会生效 */
const RESERVED_KEY_CODES: number[] = [2093, 2094, 2098];

/** 键盘键码范围（<2300 且非手柄来源的 ArkUI 沿按键盘处理） */
const KBD_CODE_MIN = 2000;
const KBD_CODE_MAX = 2299;
const ESC_KEY_CODE = 2070;

const BUTTON_ROWS: ButtonRow[] = [
  { title: 'input_button_a', nativeButton: NB_A },
  { title: 'input_button_b', nativeButton: NB_B },
  { title: 'input_button_x', nativeButton: NB_X },
  { title: 'input_button_y', nativeButton: NB_Y },
  { title: 'input_button_select', nativeButton: NB_SELECT },
  { title: 'input_button_start', nativeButton: NB_START },
  { title: 'button_home', nativeButton: NB_HOME }
];

const TRIGGER_ROWS: ButtonRow[] = [
  { title: 'input_button_l', nativeButton: NB_L },
  { title: 'input_button_r', nativeButton: NB_R },
  { title: 'input_button_zl', nativeButton: NB_ZL },
  { title: 'input_button_zr', nativeButton: NB_ZR }
];

const DPAD_ROWS: ButtonRow[] = [
  { title: 'direction_up', nativeButton: NB_UP },
  { title: 'direction_down', nativeButton: NB_DOWN },
  { title: 'direction_left', nativeButton: NB_LEFT },
  { title: 'direction_right', nativeButton: NB_RIGHT }
];

interface HotkeyRow {
  action: string;
  title: string;
  desc?: string;
}

// 顺序与 Android hotkeyTitles 一致：Hotkey Enable 在最前（绑定后需按住它才能触发其他快捷键）
const HOTKEY_ROWS: HotkeyRow[] = [
  { action: 'enable', title: 'hotkey_enable', desc: 'hotkey_enable_desc' },
  { action: 'swap_screens', title: 'swap_screens' },
  { action: 'cycle_layouts', title: 'hotkey_cycle_layouts' },
  { action: 'close_game', title: 'hotkey_close_game' },
  { action: 'toggle_pause', title: 'hotkey_toggle_pause' },
  { action: 'save_state', title: 'quick_save' },
  { action: 'load_state', title: 'quick_load' },
  { action: 'fast_forward', title: 'fast_forward' }
];

const HOTKEY_ACTIONS: string[] = [
  'enable', 'swap_screens', 'cycle_layouts', 'close_game', 'toggle_pause', 'save_state', 'load_state', 'fast_forward'
];

// 一根 3DS 模拟轴绑定到一个物理来源（左/右摇杆/十字键 Hat）的一个分量。
// 与 ohos_gamepad.cpp 的 AxisBinding 一致：输出 = 分量值 * sign。
class AxisBinding {
  source: number = -1;
  component: number = 0;
  sign: number = 1;
}

// axisBindings 数组槽位顺序（与 gamepad_axis_map 的 JSON 键对应）
const AXIS_SLOT_CIRCLEPAD_H = 0;
const AXIS_SLOT_CIRCLEPAD_V = 1;
const AXIS_SLOT_CSTICK_H = 2;
const AXIS_SLOT_CSTICK_V = 3;
// 十字方向键（轴）：3DS 十字键方向由物理轴驱动（对齐 Android D-Pad (Axis)），
// 与模拟摇杆槽位共用 AxisBinding 存储，native 侧输出按键事件而非模拟量
const AXIS_SLOT_DPAD_V = 4;
const AXIS_SLOT_DPAD_H = 5;
const AXIS_JSON_KEYS: string[] = [
  'circlepad_h', 'circlepad_v', 'cstick_h', 'cstick_v', 'dpad_v', 'dpad_h'
];

const AXIS_SRC_LEFT = 0;
const AXIS_SRC_RIGHT = 1;
const AXIS_SRC_DPAD = 2;
const AXIS_CAPTURE_CODE_BASE = 30000;

interface AxisRow {
  slot: number;
  stickKey: string;
  axisKey: string;
  vertical: boolean;
}

const CIRCLEPAD_AXIS_ROWS: AxisRow[] = [
  { slot: AXIS_SLOT_CIRCLEPAD_V, stickKey: 'gamepad_stick_circlepad', axisKey: 'gamepad_axis_vertical', vertical: true },
  { slot: AXIS_SLOT_CIRCLEPAD_H, stickKey: 'gamepad_stick_circlepad', axisKey: 'gamepad_axis_horizontal', vertical: false }
];

const CSTICK_AXIS_ROWS: AxisRow[] = [
  { slot: AXIS_SLOT_CSTICK_V, stickKey: 'gamepad_stick_cstick', axisKey: 'gamepad_axis_vertical', vertical: true },
  { slot: AXIS_SLOT_CSTICK_H, stickKey: 'gamepad_stick_cstick', axisKey: 'gamepad_axis_horizontal', vertical: false }
];

const DPAD_AXIS_ROWS: AxisRow[] = [
  { slot: AXIS_SLOT_DPAD_V, stickKey: 'gamepad_section_dpad_axis', axisKey: 'gamepad_axis_vertical', vertical: true },
  { slot: AXIS_SLOT_DPAD_H, stickKey: 'gamepad_section_dpad_axis', axisKey: 'gamepad_axis_horizontal', vertical: false }
];

interface ComboSheetOption {
  index: number;
  title: string;
  // 卡片贴图（rawfile themes/default 下的按键美术）；方向键无独立贴图共用十字键
  image: string;
}

/** 贴图上的半透明遮罩区域（归一化坐标） */
interface MaskRect {
  x: string;
  y: string;
  w: string;
  h: string;
}

// 按键集可选成员：Android comboOptions 的 10 项 + 方向键（native 侧按
// AzaharKey 索引逐个上报，方向与按键同按可用于"方向+键"类招式）；
// HOME 是系统键不入选
const COMBO_SHEET_OPTIONS: ComboSheetOption[] = [
  { index: NB_A, title: 'input_button_a', image: 'buttons_A.png' },
  { index: NB_B, title: 'input_button_b', image: 'buttons_B.png' },
  { index: NB_X, title: 'input_button_x', image: 'buttons_X.png' },
  { index: NB_Y, title: 'input_button_y', image: 'buttons_Y.png' },
  { index: NB_UP, title: 'direction_up', image: 'keypad.png' },
  { index: NB_DOWN, title: 'direction_down', image: 'keypad.png' },
  { index: NB_LEFT, title: 'direction_left', image: 'keypad.png' },
  { index: NB_RIGHT, title: 'direction_right', image: 'keypad.png' },
  { index: NB_L, title: 'input_button_l', image: 'button_l.png' },
  { index: NB_R, title: 'input_button_r', image: 'button_r.png' },
  { index: NB_ZL, title: 'input_button_zl', image: 'button_zl.png' },
  { index: NB_ZR, title: 'input_button_zr', image: 'button_zr.png' },
  { index: NB_START, title: 'input_button_start', image: 'button_start.png' },
  { index: NB_SELECT, title: 'input_button_select', image: 'button_select.png' }
];

interface ComboData {
  code: number;
  buttons: number[];
}

function arraysEqual(a: number[], b: number[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

// ArkUI KeyEvent 通道（模块级）：Mode(2313) 等键码没有 GCK 监视器，只经
// KeyEvent 上报；多数按键则 GCK/KeyEvent 双通道都报。由页面根节点在分发前
// 写入，测试 tab 轮询时按时间窗口与 native 事件去重。edges 带时间戳，
// 消费方丢弃过旧的残留事件（非测试/捕获 tab 下的按压不会漏进后续测试）。
interface ArkKeyEdge {
  code: number;
  down: boolean;
  ms: number;
  // 手柄设备来源（十字键码 2012-2015 与键盘方向键同值，需按设备区分）；
  // >=2300 的键码无键盘来源，直接按手柄处理
  pad: boolean;
}

export class GamepadArkKeyState {
  static edges: ArkKeyEdge[] = [];
  static pressed: number[] = [];

  /** 事件是否来自手柄类设备（KeyEvent.deviceId → InputDevice sources） */
  static isGamepadSource(event: KeyEvent): boolean {
    if (event.keyCode >= 2300) {
      return true;
    }
    const deviceId = event.deviceId ?? 0;
    if (deviceId <= 0) {
      return false;
    }
    try {
      const info = inputDevice.getDeviceInfoSync(deviceId);
      return (info.sources ?? []).includes('joystick');
    } catch (_e) {
      return false;
    }
  }

  static record(code: number, down: boolean, pad: boolean): void {
    const edges = GamepadArkKeyState.edges;
    const last = edges.length > 0 ? edges[edges.length - 1] : undefined;
    // onKeyPreIme/onKeyEvent 可能对同一物理沿先后触发，150ms 内同向沿只记一次
    if (last !== undefined && last.code === code && last.down === down &&
      Date.now() - last.ms < 150) {
      return;
    }
    edges.push({ code: code, down: down, ms: Date.now(), pad: pad });
    if (GamepadArkKeyState.edges.length > 64) {
      GamepadArkKeyState.edges.shift();
    }
    // pressed 只追踪手柄来源：键盘方向键不应点亮测试 tab 的十字键
    const i = GamepadArkKeyState.pressed.indexOf(code);
    if (down && i < 0 && pad) {
      GamepadArkKeyState.pressed.push(code);
    } else if (!down && i >= 0 && pad) {
      GamepadArkKeyState.pressed.splice(i, 1);
    }
  }

  static drain(): ArkKeyEdge[] {
    const out = GamepadArkKeyState.edges;
    GamepadArkKeyState.edges = [];
    return out;
  }
}

// 捕获态标志（模块级）：页面 onKeyEvent 读取，避免捕获/测试时 B 键触发返回
export class GamepadCaptureState {
  static active: boolean = false;
}

// ArkUI 焦点轴通道（模块级）：部分设备摇杆/十字键轴不经 GCK 监视器上报，只走
// FocusAxisEvent。该事件沿焦点链冒泡，由页面根节点 onFocusAxisEvent 写入，
// 与当前哪个组件持有焦点无关；测试 tab 轮询时读取。
// 顺序：左摇杆 X/Y、右摇杆 Z/RZ、十字键 HAT0X/HAT0Y
export class GamepadFocusAxisState {
  static axes: number[] = [0, 0, 0, 0, 0, 0];

  static record(event: FocusAxisEvent): void {
    const map = event.axisMap;
    GamepadFocusAxisState.axes = [
      map.get(AxisModel.ABS_X) ?? 0,
      map.get(AxisModel.ABS_Y) ?? 0,
      map.get(AxisModel.ABS_Z) ?? 0,
      map.get(AxisModel.ABS_RZ) ?? 0,
      map.get(AxisModel.ABS_HAT0X) ?? 0,
      map.get(AxisModel.ABS_HAT0Y) ?? 0
    ];
  }
}

// 测试 tab 手柄可视化的设计空间：按参考效果图像素坐标量取（870x740，左右对称，
// 中轴 x=435），渲染时按卡片宽度等比缩放。Path.commands 的坐标单位是 px，
// 由 scaledCommands 再按 vp2px 换算。
const PAD_W: number = 870;
const PAD_H: number = 740;
// 圆槽内按键簇（摇杆/ABXY/十字键）相对效果图的放大倍数，已核算不互相重叠
const PAD_KEY_SCALE: number = 1.15;
// 机身剪影：肩线 → 外侧斜边 → 握把圆底 → 底部中央内凹；两条握把分割线
const PAD_BODY_PATH: string =
  'M250 158 L620 158 C700 158 750 180 770 225 L817 405 C835 465 865 565 865 625 ' +
  'C865 695 825 733 780 730 C740 727 720 695 690 655 L655 605 ' +
  'C635 577 620 565 590 563 L280 563 C250 565 235 577 215 605 L180 655 ' +
  'C150 695 130 727 90 730 C45 733 5 695 5 625 C5 565 35 465 53 405 ' +
  'L100 225 C120 180 170 158 250 158 Z';
const PAD_DIVIDER_PATH: string = 'M53 405 L245 577 M817 405 L625 577';

// 手柄设置顶部分段控件（映射/热键/测试/杂项）：独立页面与设置分栏详情页共用。
// 选中变化时在内部播音效；tab 状态与滚动复位交由宿主回调处理。
@Component
export struct GamepadSegmentBar {
  @Prop selectedIndex: number = GAMEPAD_TAB_MAPPING;
  onSelect: (index: number) => void = () => {};
  private soundEffectManager = SoundEffectManager.getInstance();

  build() {
    Row() {
      TabSegmentButtonV2({
        items: new SegmentButtonV2Items([
          { text: I18n.t('gamepad_section_mapping'), symbol: $r('sys.symbol.arrow_left_arrow_right') },
          { text: I18n.t('gamepad_section_hotkeys'), symbol: $r('sys.symbol.bolt') },
          { text: I18n.t('gamepad_section_test'), symbol: $r('sys.symbol.waveform') },
          { text: I18n.t('gamepad_section_misc'), symbol: $r('sys.symbol.slider_horizontal_2') }
        ]),
        selectedIndex: this.selectedIndex,
        itemMinHeight: SEGMENT_ITEM_MIN_HEIGHT,
        itemPadding: SEGMENT_ITEM_PADDING,
        buttonMinHeight: SEGMENT_BUTTON_MIN_HEIGHT,
        itemSymbolFontSize: SEGMENT_SYMBOL_FONT_SIZE,
        backgroundSystemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true),
        itemSelectedFontColor: ColorMetrics.resourceColor(ThemeManager.getInstance().getControlAccent()),
        itemSelectedSymbolFontColor: ColorMetrics.resourceColor(ThemeManager.getInstance().getControlAccent()),
        itemSelectedBackgroundColor: ColorMetrics.resourceColor($r('sys.color.ohos_id_color_button_normal')),
        enableStateAnimation: true,
        onItemClicked: (index: number) => {
          if (index !== this.selectedIndex) {
            this.soundEffectManager.play(SoundEffect.SELECT);
            this.onSelect(index);
          }
        }
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: $r('sys.float.ohos_id_default_padding_start'), right: $r('sys.float.ohos_id_default_padding_end') })
  }
}

@Component
export struct GamepadSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  @Prop selectedTab: number = 0;
  @State buttonCodes: number[] = [];
  @State hotkeyCodes: number[] = [];
  @State axisBindings: AxisBinding[] = [];
  @State comboCode: number = -1;
  @State comboButtons: number[] = [];
  @State deadzone: number = 10;
  @State useArticBaseController: boolean = false;
  @State capturingTarget: string = '';
  @State captureTitle: string = '';
  @State captureDesc: string = '';
  @State showCaptureSheet: boolean = false;
  @State showComboSheet: boolean = false;
  // 键盘绑定并入映射 tab：kbTick 驱动绑定列表重渲染（绑定表本身非响应式）
  @State kbTick: number = 0;
  // 捕获目标为某按键的键盘绑定时，本次捕获替换掉的旧键码（-1 = 追加新绑定）
  private captureReplaceKbd: number = -1;
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;
  private settingsManager = SettingsManager.getInstance();
  private soundEffectManager = SoundEffectManager.getInstance();
  private bindingManager: KeyboardBindingManager = KeyboardBindingManager.getInstance();
  private captureTimer = 0;
  // 测试 tab 的手柄实时快照（native GCK 监视器原始事件，不经映射）
  @State testPressed: number[] = [];
  @State testAxes: number[] = [0, 0, 0, 0, 0, 0]; // lx ly rx ry hatX hatY
  @State testTriggers: number[] = [0, 0]; // LT RT 行程 0..1
  @State testOnline: boolean = false;
  @State testDeviceName: string = '';
  // 覆盖测试：本轮按过的物理键（对齐 Steam/8BitDo「按遍所有键」）
  @State testTested: number[] = [];
  // 输入日志（最新在前）与 native 时钟（计算「x 秒前」）
  @State testLog: TestLogEntry[] = [];
  @State testNowMs: number = 0;
  // 摇杆轨迹（约 1 秒），用于观察外圈圆度与漂移
  @State leftTrail: number[][] = [];
  @State rightTrail: number[][] = [];
  // 各方向最远半径（圆度测试包络），0 = 该方向未到过
  @State leftEnvelope: number[] = new Array<number>(ENVELOPE_BUCKETS).fill(0);
  @State rightEnvelope: number[] = new Array<number>(ENVELOPE_BUCKETS).fill(0);
  // 可视化缩放：卡片宽度 / 设计宽度（onAreaChange 更新）
  @State padScale: number = 0.4;
  // 快速点按的短暂余辉（由事件队列驱动，不会漏掉短于采样周期的点按）；hat 轴兜底
  @State testFlashing: number[] = [];
  @State hatFallbackPressed: number[] = [];
  private flashExpiry: Map<number, number> = new Map();
  private testSeq: number = 0;
  private testTimer: number = 0;
  // 双通道去重：归一码 -> 最近一次按键沿（通道 'n'=GCK / 'a'=ArkUI KeyEvent、
  // 方向、到达时刻）。同一物理沿 150ms 内经另一通道到达视为重复，不再计
  private lastEdge: Map<number, number[]> = new Map();
  // ArkUI 边写入日志用的本地序号（与 native seq 空间区分开）
  private arkSeq: number = 1000000;

  aboutToAppear() {
    this.loadSettings();
    // 官方示例要求激活焦点分发，游戏手柄轴事件才能走 onFocusAxisEvent
    this.getUIContext().getFocusController().activate(true);
    // ~30fps：摇杆轨迹需要足够采样率；不在测试 tab 时 pollTestState 立即返回
    this.testTimer = setInterval(() => {
      this.pollTestState();
    }, TEST_POLL_MS);
  }

  aboutToDisappear() {
    this.cancelCapture();
    this.getUIContext().getFocusController().activate(false);
    if (this.testTimer !== 0) {
      clearInterval(this.testTimer);
      this.testTimer = 0;
    }
  }

  private pollTestState() {
    if (this.selectedTab !== GAMEPAD_TAB_TEST) {
      return;
    }
    let snapshot: Record<string, Object> | undefined;
    try {
      snapshot = JSON.parse(AzaharNative.getGamepadTestState(this.testSeq)) as Record<string, Object>;
    } catch (e) {
      snapshot = undefined;
    }
    if (!snapshot) {
      return;
    }
    const now = Date.now();
    const nativeNow = (snapshot['now'] ?? 0) as number;
    const tested = this.testTested.slice();
    const log = this.testLog.slice();
    // 事件队列增量消费：每个按下沿都点亮余辉、计入覆盖、写日志
    const events = (snapshot['events'] ?? []) as number[][];
    for (const e of events) {
      const code = this.canonTestCode(e[1]);
      const down = e[2] === 1;
      this.testSeq = Math.max(this.testSeq, e[0]);
      if (this.isDupEdge(code, down, 'n', now)) {
        continue;
      }
      if (down) {
        this.flashExpiry.set(code, now + TEST_FLASH_MS);
        if (!tested.includes(code)) {
          tested.push(code);
        }
      }
      log.unshift({ seq: e[0], code: code, rawCode: e[1], down: down, timeMs: e[3] });
    }
    // ArkUI KeyEvent 兜底：Mode(2313) 等无 GCK 监视器的按键只走这条通道；
    // 双通道都报的按键按 150ms 窗口去重，先到先得；键盘来源沿不计入手柄测试
    for (const edge of GamepadArkKeyState.drain()) {
      if (now - edge.ms > 1500 || !edge.pad) {
        continue; // 非测试/捕获态积累的残留事件
      }
      const code = this.canonTestCode(edge.code);
      if (this.isDupEdge(code, edge.down, 'a', now)) {
        continue;
      }
      if (edge.down) {
        this.flashExpiry.set(code, now + TEST_FLASH_MS);
        if (!tested.includes(code)) {
          tested.push(code);
        }
      }
      log.unshift({ seq: this.arkSeq++, code: code, rawCode: edge.code, down: edge.down, timeMs: nativeNow });
    }
    this.testTested = tested;
    this.testLog = log.slice(0, TEST_LOG_SIZE);
    const flashing: number[] = [];
    this.flashExpiry.forEach((expiry, code) => {
      if (expiry > now) {
        flashing.push(code);
      } else {
        this.flashExpiry.delete(code);
      }
    });
    this.testFlashing = flashing;
    // 按下集合 = native GCK 通道 ∪ ArkUI KeyEvent 通道（2303/2313 归一为 HOME 后取并集）
    const pressedSet: Set<number> = new Set();
    for (const c of (snapshot['pressed'] ?? []) as number[]) {
      pressedSet.add(this.canonTestCode(c));
    }
    for (const c of GamepadArkKeyState.pressed) {
      pressedSet.add(this.canonTestCode(c));
    }
    this.testPressed = Array.from(pressedSet);
    // native GCK 轴与 ArkUI 焦点轴分量级合并，谁有信号用谁
    const nativeAxes = (snapshot['axes'] ?? [0, 0, 0, 0, 0, 0]) as number[];
    const focusAxes = GamepadFocusAxisState.axes;
    const merged: number[] = [];
    for (let i = 0; i < 6; i++) {
      const n = nativeAxes[i] ?? 0;
      const f = focusAxes[i] ?? 0;
      merged.push(Math.abs(n) >= Math.abs(f) ? n : f);
    }
    // hat 轴兜底：只经焦点轴上报十字键的设备，按方向点亮十字键（不计入事件日志）
    const pressedHat: number[] = [];
    if (focusAxes[4] < -0.5) {
      pressedHat.push(2014);
    }
    if (focusAxes[4] > 0.5) {
      pressedHat.push(2015);
    }
    if (focusAxes[5] < -0.5) {
      pressedHat.push(2012);
    }
    if (focusAxes[5] > 0.5) {
      pressedHat.push(2013);
    }
    if (pressedHat.length > 0) {
      const tested = this.testTested.slice();
      for (const code of pressedHat) {
        if (!tested.includes(code)) {
          tested.push(code);
        }
      }
      if (tested.length !== this.testTested.length) {
        this.testTested = tested;
      }
    }
    this.hatFallbackPressed = pressedHat;
    this.testAxes = merged;
    this.leftTrail = this.pushTrail(this.leftTrail, merged[0], merged[1]);
    this.rightTrail = this.pushTrail(this.rightTrail, merged[2], merged[3]);
    const leftEnv = this.updateEnvelope(this.leftEnvelope, merged[0], merged[1]);
    if (leftEnv) {
      this.leftEnvelope = leftEnv;
    }
    const rightEnv = this.updateEnvelope(this.rightEnvelope, merged[2], merged[3]);
    if (rightEnv) {
      this.rightEnvelope = rightEnv;
    }
    this.testTriggers = (snapshot['triggers'] ?? [0, 0]) as number[];
    this.testNowMs = nativeNow;
    this.testOnline = (snapshot['online'] ?? false) as boolean;
    this.testDeviceName = (snapshot['name'] ?? '') as string;
  }

  // ButtonC(2303) 与 Mode(2313) 在不同手柄上都可能是 Guide/Home 键（GCK 有
  // ButtonC 监视器但没有 Mode 监视器），测试视图统一按 2313 处理
  private canonTestCode(code: number): number {
    return code === 2303 ? 2313 : code;
  }

  // 双通道去重并记录按键沿：ch 为 'n'(GCK)/'a'(ArkUI)，返回 true 表示重复
  private isDupEdge(code: number, down: boolean, ch: string, now: number): boolean {
    const last = this.lastEdge.get(code);
    this.lastEdge.set(code, [ch === 'n' ? 1 : 2, down ? 1 : 0, now]);
    return last !== undefined && last[0] !== (ch === 'n' ? 1 : 2) &&
      last[1] === (down ? 1 : 0) && now - last[2] < 150;
  }

  // 轨迹只记录离开中心的采样，静止时自然淡出
  private pushTrail(trail: number[][], x: number, y: number): number[][] {
    const next = trail.slice(trail.length >= TEST_TRAIL_SIZE ? 1 : 0);
    if (Math.abs(x) > 0.02 || Math.abs(y) > 0.02) {
      next.push([x, y]);
    } else if (next.length > 0) {
      next.shift();
    }
    return next;
  }

  // 只记录推到外圈附近（超过 50% 幅度）的采样，返回 undefined 表示无变化（避免每帧刷新）
  private updateEnvelope(env: number[], x: number, y: number): number[] | undefined {
    const r = Math.sqrt(x * x + y * y);
    if (r < 0.5) {
      return undefined;
    }
    const a = Math.atan2(y, x) + Math.PI;
    const i = Math.min(ENVELOPE_BUCKETS - 1, Math.floor(a / (Math.PI * 2) * ENVELOPE_BUCKETS));
    if (r <= env[i]) {
      return undefined;
    }
    const next = env.slice();
    next[i] = r;
    return next;
  }

  private resetTest() {
    AzaharNative.resetGamepadTestState();
    this.testTested = [];
    this.testLog = [];
    this.leftTrail = [];
    this.rightTrail = [];
    this.leftEnvelope = new Array<number>(ENVELOPE_BUCKETS).fill(0);
    this.rightEnvelope = new Array<number>(ENVELOPE_BUCKETS).fill(0);
    this.flashExpiry.clear();
    this.testFlashing = [];
  }

  private isPadPressed(code: number): boolean {
    return this.testPressed.includes(code) || this.testFlashing.includes(code) ||
      this.hatFallbackPressed.includes(code);
  }

  private isPadTested(code: number): boolean {
    return this.testTested.includes(code);
  }

  private testTargetCount(): number {
    let n = 0;
    for (const code of TEST_KEY_CODES) {
      if (this.testTested.includes(code)) {
        n++;
      }
    }
    return n;
  }

  private logAgeText(entry: TestLogEntry): string {
    const age = (this.testNowMs - entry.timeMs) / 1000;
    return age < 1 ? I18n.t('gamepad_test_just_now')
      : I18n.tf1('gamepad_test_seconds_ago_fmt', 'sec', Math.floor(age));
  }

  // 物理键码当前绑定的目标：3DS 按键 / 热键 / 组合按键 / 未绑定
  private boundTargetFor(code: number): string {
    for (const row of BUTTON_ROWS) {
      if (this.buttonCodes[row.nativeButton] === code) {
        return I18n.t(row.title);
      }
    }
    for (const row of TRIGGER_ROWS) {
      if (this.buttonCodes[row.nativeButton] === code) {
        return I18n.t(row.title);
      }
    }
    for (const row of DPAD_ROWS) {
      if (this.buttonCodes[row.nativeButton] === code) {
        return I18n.t(row.title);
      }
    }
    for (let i = 0; i < HOTKEY_ACTIONS.length; i++) {
      if (this.hotkeyCodes[i] === code) {
        return I18n.t(HOTKEY_ROWS[i].title);
      }
    }
    if (this.comboCode === code) {
      return I18n.t('gamepad_combo_button');
    }
    return I18n.t('gamepad_unbound');
  }

  private updateBoolean(key: string, value: boolean) {
    void this.settingsManager.setBoolean(key, value).then(() => {
      AzaharNative.applyConfig();
    });
  }

  private updateNumber(key: string, value: number) {
    void this.settingsManager.setNumber(key, value).then(() => {
      AzaharNative.applyConfig();
    });
  }

  private updateString(key: string, value: string) {
    void this.settingsManager.setString(key, value).then(() => {
      AzaharNative.applyConfig();
    });
  }

  private physKeyLabel(code: number): string {
    switch (code) {
      case 2301: return 'A';
      case 2302: return 'B';
      case 2304: return 'X';
      case 2305: return 'Y';
      case 2307: return 'L1';
      case 2308: return 'R1';
      case 2309: return 'L2';
      case 2310: return 'R2';
      case 2311: return I18n.t('physkey_select');
      case 2312: return I18n.t('physkey_start');
      // BUTTON_MODE(2313)：Guide/Home 键，无 GCK 监视器，经 ArkUI KeyEvent 通道到达；
      // ButtonC(2303) 已由 canonTestCode 归一到此
      case 2313: return I18n.t('physkey_home');
      case 2314: return 'L3';
      case 2315: return 'R3';
      case 2012: return I18n.t('physkey_dpad_up');
      case 2013: return I18n.t('physkey_dpad_down');
      case 2014: return I18n.t('physkey_dpad_left');
      case 2015: return I18n.t('physkey_dpad_right');
      default: return I18n.tf1('physkey_unknown_fmt', 'code', code);
    }
  }

  /** 键盘来源码（非十字键）；十字键码与手柄同值，一律按手柄处理 */
  private isKbdCode(code: number): boolean {
    return code >= KBD_CODE_MIN && code <= KBD_CODE_MAX && (code < 2012 || code > 2015);
  }

  /** 绑定来源图标：与映射 tab 绑定条目同一套 gamecontroller/keyboard 符号 */
  private boundIcon(code: number): Resource {
    return this.isKbdCode(code) ? $r('sys.symbol.keyboard') : $r('sys.symbol.gamecontroller');
  }

  private boundLabel(code: number): string {
    if (code < 0) {
      return I18n.t('gamepad_unbound');
    }
    // 来源已由图标区分，键名与映射行一致显示裸名
    if (this.isKbdCode(code)) {
      return keyCodeName(code);
    }
    return this.physKeyLabel(code);
  }

  // ---- 键盘绑定（与手柄绑定同一行显示，参考 nds/retro 的统一映射页）----

  /** 某按键的全部绑定条目：手柄在前，键盘在后，来源用图标区分（nds/retro 前缀的图标化） */
  private bindingEntries(nb: number): BindEntry[] {
    const _t = this.kbTick;
    const entries: BindEntry[] = [];
    const pad = this.buttonCodeAt(nb);
    if (pad >= 0) {
      entries.push({ kind: 'pad', code: pad, label: this.physKeyLabel(pad), icon: $r('sys.symbol.gamecontroller') });
    }
    for (const code of this.bindingManager.getKeyCodes(nb as AzaharKey)) {
      entries.push({ kind: 'kbd', code: code, label: keyCodeName(code), icon: $r('sys.symbol.keyboard') });
    }
    return entries;
  }

  /** 点击行/添加入口发起统一捕获：手柄输入进手柄表，键盘输入进键盘表。
   *  replaceKbd >=0 表示本次是在重绑某个已存在的键盘键码（nds 点绑定即替换语义） */
  private rebindEntry(row: ButtonRow, typeKey: string, replaceKbd: number = -1) {
    this.captureReplaceKbd = replaceKbd;
    this.beginCapture(`btn:${row.nativeButton}`,
      I18n.tf2('gamepad_bind_title_fmt', 'type', I18n.t(typeKey), 'name', I18n.t(row.title)),
      false, I18n.t('gamepad_capture_kb_desc'));
  }

  private removeBindEntry(nb: number, entry: BindEntry) {
    if (entry.kind === 'pad') {
      const buttons: number[] = [];
      for (const c of this.buttonCodes) {
        buttons.push(c);
      }
      buttons[nb] = -1;
      this.buttonCodes = buttons;
      this.persistAllMaps();
      return;
    }
    this.bindingManager.removeBinding(entry.code, nb as AzaharKey);
    this.kbTick++;
  }

  private decodeButtonMap(raw: string): number[] {
    const codes: number[] = [];
    if (raw === '') {
      for (const code of DEFAULT_CODES) {
        codes.push(code);
      }
      return codes;
    }
    let parsed: Record<string, number> | undefined;
    try {
      parsed = JSON.parse(raw) as Record<string, number>;
    } catch (e) {
      parsed = undefined;
    }
    for (let i = 0; i < NATIVE_BUTTON_COUNT; i++) {
      const code = parsed ? parsed[`${i}`] : undefined;
      codes.push(code !== undefined ? code : -1);
    }
    return codes;
  }

  private encodeButtonMap(codes: number[]): string {
    if (arraysEqual(codes, DEFAULT_CODES)) {
      return '';
    }
    const parts: string[] = [];
    for (let i = 0; i < codes.length; i++) {
      if (codes[i] >= 0) {
        parts.push(`"${i}":${codes[i]}`);
      }
    }
    return '{' + parts.join(',') + '}';
  }

  private saveButtonMap() {
    this.updateString(KEY_GAMEPAD_BUTTON_MAP, this.encodeButtonMap(this.buttonCodes));
  }


  private stripCodeEverywhere(code: number) {
    const buttons: number[] = [];
    for (const c of this.buttonCodes) {
      buttons.push(c);
    }
    for (let i = 0; i < buttons.length; i++) {
      if (buttons[i] === code) {
        buttons[i] = -1;
      }
    }
    this.buttonCodes = buttons;
    const hotkeys: number[] = [];
    for (const c of this.hotkeyCodes) {
      hotkeys.push(c);
    }
    for (let i = 0; i < hotkeys.length; i++) {
      if (hotkeys[i] === code) {
        hotkeys[i] = -1;
      }
    }
    this.hotkeyCodes = hotkeys;
    if (this.comboCode === code) {
      this.comboCode = -1;
    }
  }

  private persistAllMaps() {
    this.saveButtonMap();
    this.updateString(KEY_GAMEPAD_HOTKEY_MAP, this.encodeHotkeyMap());
    this.saveCombo(this.comboCode, this.comboButtons);
    this.saveAxisMap();
  }

  private encodeHotkeyMap(): string {
    const parts: string[] = [];
    for (let i = 0; i < HOTKEY_ACTIONS.length; i++) {
      if (this.hotkeyCodes[i] >= 0) {
        parts.push(`"${HOTKEY_ACTIONS[i]}":${this.hotkeyCodes[i]}`);
      }
    }
    return '{' + parts.join(',') + '}';
  }

  private saveCombo(code: number, buttons: number[]) {
    if (code < 0 && buttons.length === 0) {
      this.updateString(KEY_GAMEPAD_COMBO, '');
      this.comboCode = code;
      this.comboButtons = buttons;
      return;
    }
    // 对齐 Android COMBO_BUTTON_BUTTONS：触发键选择独立于绑定持久化，
    // 允许先配置再绑定（code=-1）
    const data: ComboData = { code: code, buttons: buttons };
    this.updateString(KEY_GAMEPAD_COMBO, JSON.stringify(data));
    this.comboCode = code;
    this.comboButtons = buttons;
  }

  private decodeAxisMap(raw: string): AxisBinding[] {
    const bindings: AxisBinding[] = [
      { source: AXIS_SRC_LEFT, component: 0, sign: 1 },
      { source: AXIS_SRC_LEFT, component: 1, sign: 1 },
      { source: AXIS_SRC_RIGHT, component: 0, sign: 1 },
      { source: AXIS_SRC_RIGHT, component: 1, sign: 1 },
      { source: -1, component: 0, sign: 1 },
      { source: -1, component: 0, sign: 1 }
    ];
    if (raw === '') {
      return bindings;
    }
    let parsed: Record<string, Object> | undefined;
    try {
      parsed = JSON.parse(raw) as Record<string, Object>;
    } catch (e) {
      parsed = undefined;
    }
    if (!parsed) {
      return bindings;
    }
    // 旧格式迁移：{"circlepad":src,"cstick":src} 整杆来源展开为逐轴绑定
    const cpLegacy = parsed['circlepad'];
    if (typeof cpLegacy === 'number' && cpLegacy >= -1 && cpLegacy <= AXIS_SRC_DPAD) {
      bindings[AXIS_SLOT_CIRCLEPAD_H] = { source: cpLegacy, component: 0, sign: 1 };
      bindings[AXIS_SLOT_CIRCLEPAD_V] = { source: cpLegacy, component: 1, sign: 1 };
    }
    const csLegacy = parsed['cstick'];
    if (typeof csLegacy === 'number' && csLegacy >= -1 && csLegacy <= AXIS_SRC_DPAD) {
      bindings[AXIS_SLOT_CSTICK_H] = { source: csLegacy, component: 0, sign: 1 };
      bindings[AXIS_SLOT_CSTICK_V] = { source: csLegacy, component: 1, sign: 1 };
    }
    for (let i = 0; i < AXIS_JSON_KEYS.length; i++) {
      const entry = parsed[AXIS_JSON_KEYS[i]];
      if (typeof entry === 'number' && entry < 0) {
        bindings[i] = { source: -1, component: 0, sign: 1 };
      } else if (Array.isArray(entry) && entry.length === 3) {
        const src = entry[0] as number;
        const comp = entry[1] as number;
        const sign = entry[2] as number;
        if (src >= AXIS_SRC_LEFT && src <= AXIS_SRC_DPAD && (comp === 0 || comp === 1) &&
          (sign === 1 || sign === -1)) {
          bindings[i] = { source: src, component: comp, sign: sign };
        }
      }
    }
    return bindings;
  }

  private encodeAxisMap(): string {
    const parts: string[] = [];
    for (let i = 0; i < AXIS_JSON_KEYS.length; i++) {
      const b = this.axisBindings[i];
      if (!b || b.source < 0) {
        parts.push(`"${AXIS_JSON_KEYS[i]}":-1`);
      } else {
        parts.push(`"${AXIS_JSON_KEYS[i]}":[${b.source},${b.component},${b.sign}]`);
      }
    }
    return '{' + parts.join(',') + '}';
  }

  private saveAxisMap() {
    this.updateString(KEY_GAMEPAD_AXIS_MAP, this.encodeAxisMap());
  }

  private axisLabel(slot: number): string {
    const b = this.axisBindings[slot];
    if (!b || b.source < 0) {
      return I18n.t('gamepad_unbound');
    }
    let source: string;
    switch (b.source) {
      case AXIS_SRC_LEFT:
        source = I18n.t('gamepad_stick_left');
        break;
      case AXIS_SRC_RIGHT:
        source = I18n.t('gamepad_stick_right');
        break;
      default:
        source = I18n.t('gamepad_stick_dpad');
        break;
    }
    return `${source} ${b.sign < 0 ? '-' : ''}${b.component === 0 ? 'X' : 'Y'}`;
  }

  // 捕获到的轴事件编码：30000 + source*100 + component*10 + dir(0负/1正)。
  // 语义对齐 Android：用户推动的方向对应提示方向（垂直=上，水平=右），
  // sign = 提示方向符号 * 实际推动方向符号。
  private applyCapturedAxis(slot: number, code: number) {
    const packed = code - AXIS_CAPTURE_CODE_BASE;
    const source = Math.floor(packed / 100);
    const component = Math.floor((packed % 100) / 10);
    const movedSign = packed % 10 === 1 ? 1 : -1;
    const vertical = slot === AXIS_SLOT_CIRCLEPAD_V || slot === AXIS_SLOT_CSTICK_V ||
      slot === AXIS_SLOT_DPAD_V;
    const promptSign = vertical ? -1 : 1;
    const bindings: AxisBinding[] = [];
    for (const b of this.axisBindings) {
      bindings.push({ source: b.source, component: b.component, sign: b.sign });
    }
    bindings[slot] = { source: source, component: component, sign: promptSign * movedSign };
    this.axisBindings = bindings;
  }

  private pollCapture() {
    let code = AzaharNative.consumeGamepadInputCapture();
    let kbdCode = -1;
    let cancel = false;
    // 按键捕获也看 ArkUI KeyEvent 通道：Mode(2313) 没有 GCK 监视器，
    // 不收这条通道 Guide/Home 键永远无法完成绑定；键盘键码同样只能从这里到达
    for (const edge of GamepadArkKeyState.drain()) {
      if (!edge.down || this.capturingTarget === '' || Date.now() - edge.ms >= 1500) {
        continue;
      }
      if (edge.code === ESC_KEY_CODE) {
        cancel = true;
        continue;
      }
      if (this.capturingTarget.startsWith('axis:')) {
        continue;
      }
      if (edge.pad) {
        if (code < 0) {
          code = edge.code;
        }
      } else if (edge.code >= KBD_CODE_MIN && edge.code <= KBD_CODE_MAX && kbdCode < 0) {
        kbdCode = edge.code;
      }
    }
    if (cancel) {
      this.cancelCapture();
      return;
    }
    const target = this.capturingTarget;
    if (kbdCode >= 0) {
      // 键盘来源的键码是否接受取决于捕获目标；拒绝时提示并继续等待有效输入
      if (this.checkCapturedKeyboard(kbdCode, target)) {
        this.finishCapture();
        this.applyKeyboardBinding(kbdCode, target);
      }
      return;
    }
    if (code < 0) {
      return;
    }
    this.finishCapture();
    if (target.startsWith('axis:')) {
      this.applyCapturedAxis(Number(target.substring(5)), code);
      this.saveAxisMap();
      return;
    }
    this.stripCodeEverywhere(code);
    if (target.startsWith('btn:')) {
      const idx = Number(target.substring(4));
      const buttons: number[] = [];
      for (const c of this.buttonCodes) {
        buttons.push(c);
      }
      buttons[idx] = code;
      this.buttonCodes = buttons;
    } else if (target.startsWith('hotkey:')) {
      const action = target.substring(7);
      const hotkeys: number[] = [];
      for (const c of this.hotkeyCodes) {
        hotkeys.push(c);
      }
      for (let i = 0; i < HOTKEY_ACTIONS.length; i++) {
        if (HOTKEY_ACTIONS[i] === action) {
          hotkeys[i] = code;
        }
      }
      this.hotkeyCodes = hotkeys;
    } else if (target === 'combo') {
      this.comboCode = code;
      this.persistAllMaps();
      // 仅在按键集为空时顺势弹多选引导（空集合等于功能不生效）；已配置过的重绑不打扰
      if (this.comboButtons.length === 0) {
        this.openComboSheet();
      }
      return;
    }
    this.persistAllMaps();
  }

  private finishCapture() {
    if (this.captureTimer !== 0) {
      clearInterval(this.captureTimer);
      this.captureTimer = 0;
    }
    this.capturingTarget = '';
    this.captureReplaceKbd = -1;
    this.showCaptureSheet = false;
    GamepadCaptureState.active = false;
  }

  /** 捕获中收到不合法的键码：提示并继续等待（对齐旧键盘页 KeyCaptureDialog 拒绝逻辑） */
  private rejectCapturedKey(hint: string) {
    this.soundEffectManager.play(SoundEffect.FAIL);
    this.captureDesc = hint;
  }

  /** 键盘来源键码是否适用于当前捕获目标；返回 false 时已给出提示 */
  private checkCapturedKeyboard(code: number, target: string): boolean {
    if (target.startsWith('btn:')) {
      const nb = Number(target.substring(4));
      if (!isKeyboardBindableButton(nb)) {
        this.rejectCapturedKey(I18n.t('gamepad_kb_not_bindable'));
        return false;
      }
      if (RESERVED_KEY_CODES.indexOf(code) >= 0) {
        this.rejectCapturedKey(I18n.t('kb_capture_reserved'));
        return false;
      }
      return true;
    }
    if (target.startsWith('hotkey:')) {
      // 十字键码的键盘来源事件在 GameView 被手柄设备条件过滤，绑成热键不会生效
      if (code >= 2012 && code <= 2015) {
        this.rejectCapturedKey(I18n.t('kb_capture_reserved'));
        return false;
      }
      return true;
    }
    // 组合键触发码经 native GCK 通道消费，键盘码永远到不了
    this.rejectCapturedKey(I18n.t('gamepad_kb_not_bindable'));
    return false;
  }

  private applyKeyboardBinding(code: number, target: string) {
    if (target.startsWith('btn:')) {
      const nb = Number(target.substring(4));
      // 同一键码绑成热键会在 GameView 抢先消费：进键盘表前先清掉热键占用
      this.stripHotkeyCode(code);
      // 从已有绑定行点入的是重绑：先删旧键码再记新键码（nds 点绑定即替换语义）
      if (this.captureReplaceKbd >= 0 && this.captureReplaceKbd !== code) {
        this.bindingManager.removeBinding(this.captureReplaceKbd, nb as AzaharKey);
      }
      this.captureReplaceKbd = -1;
      this.bindingManager.addBinding(code, nb as AzaharKey);
      this.kbTick++;
      return;
    }
    if (target.startsWith('hotkey:')) {
      const action = target.substring(7);
      const hotkeys: number[] = [];
      for (const c of this.hotkeyCodes) {
        hotkeys.push(c);
      }
      for (let i = 0; i < HOTKEY_ACTIONS.length; i++) {
        if (HOTKEY_ACTIONS[i] === action) {
          hotkeys[i] = code;
        } else if (hotkeys[i] === code) {
          hotkeys[i] = -1;
        }
      }
      this.hotkeyCodes = hotkeys;
      // 该键码不再属于键盘映射（热键在 GameView 先于键盘表消费，留着是死绑定）
      this.bindingManager.removeKeyCode(code);
      this.kbTick++;
      this.updateString(KEY_GAMEPAD_HOTKEY_MAP, this.encodeHotkeyMap());
    }
  }

  /** 从热键表移除指定键码（该键改绑普通按键后，热键不再抢占它） */
  private stripHotkeyCode(code: number) {
    const hotkeys: number[] = [];
    for (const c of this.hotkeyCodes) {
      hotkeys.push(c);
    }
    let dirty = false;
    for (let i = 0; i < hotkeys.length; i++) {
      if (hotkeys[i] === code) {
        hotkeys[i] = -1;
        dirty = true;
      }
    }
    if (dirty) {
      this.hotkeyCodes = hotkeys;
      this.updateString(KEY_GAMEPAD_HOTKEY_MAP, this.encodeHotkeyMap());
    }
  }

  /** 组合按键集摘要：已选按键按 "A + B" 形式列出，未配置时返回空串 */
  private comboSummary(): string {
    const names: string[] = [];
    for (const b of this.comboButtons) {
      for (const opt of COMBO_SHEET_OPTIONS) {
        if (opt.index === b) {
          names.push(I18n.t(opt.title));
          break;
        }
      }
    }
    return names.join(' + ');
  }

  // 打开组合按键集面板（对齐 Android Configure Combo Button，sheet 卡片多选）
  private openComboSheet() {
    this.showComboSheet = true;
  }

  // 方向键贴图只有整颗十字键：用浅色遮罩洗白非目标方向的区域来区分
  // 四个方向（深色遮罩压在深灰素材上不明显；臂约占图宽 33%–67%，
  // 一块整半区矩形罩住目标臂以外全部，多块拼接会有接缝盖不到）
  private dpadMasks(index: number): MaskRect[] {
    switch (index) {
      case NB_UP: return [{ x: '0%', y: '33%', w: '100%', h: '67%' }];
      case NB_DOWN: return [{ x: '0%', y: '0%', w: '100%', h: '67%' }];
      case NB_LEFT: return [{ x: '33%', y: '0%', w: '67%', h: '100%' }];
      case NB_RIGHT: return [{ x: '0%', y: '0%', w: '67%', h: '100%' }];
      default: return [];
    }
  }

  /** 切换按键集成员：即时写回（全部取消即清空） */
  private toggleComboButton(index: number) {
    const next: number[] = [];
    for (const b of this.comboButtons) {
      next.push(b);
    }
    const pos = next.indexOf(index);
    if (pos < 0) {
      next.push(index);
    } else {
      next.splice(pos, 1);
    }
    this.soundEffectManager.play(pos < 0 ? SoundEffect.TOGGLE_ON : SoundEffect.TOGGLE_OFF);
    this.saveCombo(this.comboCode, next);
  }

  private beginCapture(target: string, title: string, axis: boolean = false, desc: string = '') {
    if (this.capturingTarget !== '') {
      return;
    }
    const armed = axis ? AzaharNative.startGamepadAxisCapture() : AzaharNative.startGamepadInputCapture();
    if (!armed) {
      return;
    }
    this.capturingTarget = target;
    this.captureTitle = title;
    this.captureDesc = desc === '' ? I18n.t('gamepad_capture_desc') : desc;
    this.showCaptureSheet = true;
    GamepadCaptureState.active = true;
    this.captureTimer = setInterval(() => {
      this.pollCapture();
    }, 50);
  }

  private cancelCapture() {
    this.capturingTarget = '';
    this.captureReplaceKbd = -1;
    this.showCaptureSheet = false;
    GamepadCaptureState.active = false;
    if (this.captureTimer !== 0) {
      clearInterval(this.captureTimer);
      this.captureTimer = 0;
    }
    AzaharNative.cancelGamepadInputCapture();
  }

  // 对应 Android 弹窗里的 Clear 按钮：清除正在捕获目标的现有绑定
  private clearCaptureTarget() {
    const target = this.capturingTarget;
    this.cancelCapture();
    if (target.startsWith('btn:')) {
      const idx = Number(target.substring(4));
      const buttons: number[] = [];
      for (const c of this.buttonCodes) {
        buttons.push(c);
      }
      buttons[idx] = -1;
      this.buttonCodes = buttons;
      this.persistAllMaps();
    } else if (target.startsWith('hotkey:')) {
      const action = target.substring(7);
      const hotkeys: number[] = [];
      for (const c of this.hotkeyCodes) {
        hotkeys.push(c);
      }
      for (let i = 0; i < HOTKEY_ACTIONS.length; i++) {
        if (HOTKEY_ACTIONS[i] === action) {
          hotkeys[i] = -1;
        }
      }
      this.hotkeyCodes = hotkeys;
      this.updateString(KEY_GAMEPAD_HOTKEY_MAP, this.encodeHotkeyMap());
    } else if (target === 'combo') {
      this.saveCombo(-1, []);
    } else if (target.startsWith('axis:')) {
      const slot = Number(target.substring(5));
      const bindings: AxisBinding[] = [];
      for (const b of this.axisBindings) {
        bindings.push({ source: b.source, component: b.component, sign: b.sign });
      }
      bindings[slot] = { source: -1, component: 0, sign: 1 };
      this.axisBindings = bindings;
      this.saveAxisMap();
    }
  }

  private applyDefaultMapping() {
    const defaults: number[] = [];
    for (const c of DEFAULT_CODES) {
      defaults.push(c);
    }
    this.buttonCodes = defaults;
    this.saveButtonMap();
    // 键盘与手柄映射已合并管理：恢复默认一并重置键盘绑定表
    this.bindingManager.resetToDefaults();
    this.kbTick++;
  }


  private loadSettings() {
    this.bindingManager.migrateLegacyNativeButtonIndexes();
    this.bindingManager.load();
    const buttonMapRaw = this.settingsManager.getString(KEY_GAMEPAD_BUTTON_MAP);
    this.buttonCodes = this.decodeButtonMap(buttonMapRaw);

    const hotkeyMapRaw = this.settingsManager.getString(KEY_GAMEPAD_HOTKEY_MAP);
    let hotkeyParsed: Record<string, number> | undefined;
    try {
      hotkeyParsed = hotkeyMapRaw === '' ? undefined : JSON.parse(hotkeyMapRaw) as Record<string, number>;
    } catch (e) {
      hotkeyParsed = undefined;
    }
    const hotkeys: number[] = [];
    for (const action of HOTKEY_ACTIONS) {
      const code = hotkeyParsed ? hotkeyParsed[action] : undefined;
      hotkeys.push(code !== undefined ? code : -1);
    }
    this.hotkeyCodes = hotkeys;

    const axisRaw = this.settingsManager.getString(KEY_GAMEPAD_AXIS_MAP);
    this.axisBindings = this.decodeAxisMap(axisRaw);

    const comboRaw = this.settingsManager.getString(KEY_GAMEPAD_COMBO);
    try {
      if (comboRaw !== '') {
        const parsed = JSON.parse(comboRaw) as ComboData;
        if (typeof parsed.code === 'number' && Array.isArray(parsed.buttons)) {
          this.comboCode = parsed.code;
          const buttons: number[] = [];
          for (const b of parsed.buttons) {
            buttons.push(b);
          }
          this.comboButtons = buttons;
        }
      }
    } catch (e) {
      console.warn(`load settings failed: ${(e as Error)?.message}`);
    }

    this.deadzone = this.settingsManager.getNumber(KEY_GAMEPAD_DEADZONE);
    this.useArticBaseController = this.settingsManager.getBoolean(KEY_USE_ARTIC_BASE_CONTROLLER);
  }

  @Builder
  private SectionHeader(title: string, desc: string = '') {
    SettingsSectionHeader({ title: title, desc: desc })
  }

  @Builder
  private BindingRows(rows: ButtonRow[], typeKey: string) {
    ForEach(rows, (row: ButtonRow) => {
      ListItem() {
        this.BindingRowItem(row, typeKey)
      }
    }, (row: ButtonRow) => `${row.nativeButton}`)
  }

  /** 单行按键映射（nds/retro 样式）：标题居左，右侧逐条列出全部绑定，
   *  点绑定名重绑该条、行尾圆形删除键单独删除；点击行或「添加绑定」直接进统一捕获，
   *  按下手柄键存手柄表、按下键盘键存键盘表 */
  @Builder
  private BindingRowItem(row: ButtonRow, typeKey: string) {
    Row() {
      Text(I18n.t(row.title))
        .fontSize(FONT_SIZE_SETTING_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_PRIMARY)
        .width(84)
      Column() {
        if (this.capturingTarget === `btn:${row.nativeButton}`) {
          Text(I18n.t('gamepad_binding_listening'))
            .fontSize(FONT_SIZE_SETTING_DESC)
            .fontColor(ThemeManager.getInstance().getControlAccent())
            .height(40)
        } else {
          if (this.bindingEntries(row.nativeButton).length === 0) {
            Text(I18n.t('gamepad_unbound'))
              .fontSize(FONT_SIZE_SETTING_DESC)
              .fontColor(TEXT_SECONDARY)
              .height(40)
          }
          ForEach(this.bindingEntries(row.nativeButton), (entry: BindEntry) => {
            Row({ space: 8 }) {
              SymbolGlyph(entry.icon)
                .fontSize(ICON_SIZE_ROW)
                .fontColor([TEXT_SECONDARY])
              Text(entry.label)
                .fontSize(FONT_SIZE_SETTING_TITLE)
                .fontColor(TEXT_PRIMARY)
                .layoutWeight(1)
                .onClick(() => {
                  this.soundEffectManager.play(SoundEffect.DECIDE);
                  this.rebindEntry(row, typeKey, entry.kind === 'kbd' ? entry.code : -1);
                })
              // 逐条删除：圆形次级底按钮 + 警示色图标（与编辑器圆形按钮同款规格）
              Button({ type: ButtonType.Circle }) {
                SymbolGlyph($r('sys.symbol.trash'))
                  .fontSize(BUTTON_ICON_SM)
                  .fontColor([TEXT_SECONDARY])
              }
              .width(32)
              .height(32)
              .buttonStyle(ButtonStyleMode.NORMAL)
              .backgroundColor(BUTTON_BG_SECONDARY)
              .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
              .onFocus(() => {
                this.soundEffectManager.play(SoundEffect.FOCUS);
              })
              .onClick(() => {
                this.soundEffectManager.play(SoundEffect.CONFIRM);
                this.removeBindEntry(row.nativeButton, entry);
              })
            }
            .height(40)
            .alignItems(VerticalAlign.Center)
          }, (entry: BindEntry) => `${entry.kind}_${entry.code}`)
          if (isKeyboardBindableButton(row.nativeButton)) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.plus'))
                .fontSize(16)
                .fontColor([TEXT_SECONDARY])
              Text(I18n.t('kb_add_binding'))
                .fontSize(FONT_SIZE_SETTING_DESC)
                .fontColor(TEXT_SECONDARY)
            }
            .height(32)
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.soundEffectManager.play(SoundEffect.DECIDE);
              this.rebindEntry(row, typeKey);
            })
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    // 水平对齐 ComposeListItem 内边距；垂直用中档 margin 收紧多绑定行的高度
    .padding({
      left: $r('sys.float.ohos_id_default_padding_start'),
      right: $r('sys.float.ohos_id_default_padding_end'),
      top: $r('sys.float.ohos_id_elements_margin_vertical_m'),
      bottom: $r('sys.float.ohos_id_elements_margin_vertical_m')
    })
    .onFocus(() => {
      this.soundEffectManager.play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      this.soundEffectManager.play(SoundEffect.DECIDE);
      this.rebindEntry(row, typeKey);
    })
  }

  @Builder
  private AxisBindingRows(rows: AxisRow[]) {
    ForEach(rows, (row: AxisRow) => {
      ListItem() {
        GamepadBindingItem({
          title: I18n.t(row.axisKey),
          value: this.axisLabel(row.slot),
          // 轴来源只有手柄摇杆/十字 Hat，固定手柄图标
          icon: this.axisBindings[row.slot] !== undefined && this.axisBindings[row.slot].source >= 0 ?
            $r('sys.symbol.gamecontroller') : null,
          listening: this.capturingTarget === `axis:${row.slot}`,
          listeningText: I18n.t('gamepad_binding_listening'),
          deletable: this.axisBindings[row.slot] !== undefined && this.axisBindings[row.slot].source >= 0,
          onSelect: () => {
            this.beginCapture(`axis:${row.slot}`,
              I18n.tf2('gamepad_bind_title_fmt', 'type', I18n.t(row.stickKey), 'name', I18n.t(row.axisKey)),
              true, I18n.t(row.vertical ? 'gamepad_capture_axis_v' : 'gamepad_capture_axis_h'));
          },
          onClear: () => {
            const bindings: AxisBinding[] = [];
            for (const b of this.axisBindings) {
              bindings.push({ source: b.source, component: b.component, sign: b.sign });
            }
            bindings[row.slot] = { source: -1, component: 0, sign: 1 };
            this.axisBindings = bindings;
            this.saveAxisMap();
          }
        })
      }
    }, (row: AxisRow) => `${row.slot}`)
  }

  // ---- 测试 tab：手柄可视化（轮廓式，参考主流手柄测试器）----

  // 设计空间坐标 → vp
  private ps(v: number): number {
    return v * this.padScale;
  }

  // Path.commands 坐标单位是 px：设计空间坐标 × 缩放 × vp2px
  private scaledCommands(base: string): string {
    const s = this.getUIContext().vp2px(1) * this.padScale;
    return base.replace(/-?\d+(?:\.\d+)?/g, (match: string) =>
      (parseFloat(match) * s).toFixed(1));
  }

  // 按键三态：未测（白）→ 按下（实心强调色）→ 已测（强调色描边 + 强调色字）
  private padAccent(): ResourceColor {
    return ThemeManager.getInstance().getControlAccent();
  }

  private padKeyBg(code: number): ResourceColor {
    return this.isPadPressed(code) ? this.padAccent() : $r('sys.color.ohos_id_color_card_bg');
  }

  private padKeyFg(code: number): ResourceColor {
    if (this.isPadPressed(code)) {
      return $r('sys.color.ohos_id_color_text_primary_contrary');
    }
    return this.isPadTested(code) ? this.padAccent() : $r('sys.color.ohos_id_color_text_primary');
  }

  private padKeyStrokeWidth(code: number): number {
    return this.isPadTested(code) ? 2 : 1;
  }

  private padKeyBorder(code: number): ResourceColor {
    return this.isPadTested(code) && !this.isPadPressed(code)
      ? this.padAccent() : $r('sys.color.ohos_id_color_list_separator');
  }

  // 圆槽：摇杆/ABXY/十字键/HOME 外圈
  @Builder
  private VizWell(cx: number, cy: number, r: number) {
    Circle()
      .width(this.ps(r * 2))
      .height(this.ps(r * 2))
      .fill($r('sys.color.ohos_id_color_component_normal'))
      .stroke($r('sys.color.ohos_id_color_text_secondary'))
      .strokeOpacity(0.35)
      .strokeWidth(1.5)
      .position({ x: this.ps(cx - r), y: this.ps(cy - r) })
  }

  // 圆形字母键（ABXY）
  @Builder
  private VizCircleButton(cx: number, cy: number, r: number, code: number, label: string) {
    Stack() {
      Circle()
        .width(this.ps(r * 2))
        .height(this.ps(r * 2))
        .fill(this.padKeyBg(code))
        .stroke(this.padKeyBorder(code))
        .strokeWidth(this.padKeyStrokeWidth(code) + 0.5)
      Text(label)
        .fontSize(this.ps(r * 1.05))
        .fontWeight(FontWeight.Bold)
        .fontColor(this.padKeyFg(code))
    }
    .width(this.ps(r * 2))
    .height(this.ps(r * 2))
    .position({ x: this.ps(cx - r), y: this.ps(cy - r) })
  }

  // 圆形图标键（HOME/View/Menu）
  @Builder
  private VizSymbolButton(cx: number, cy: number, r: number, code: number, symbol: Resource) {
    Stack() {
      Circle()
        .width(this.ps(r * 2))
        .height(this.ps(r * 2))
        .fill(this.padKeyBg(code))
        .stroke(this.padKeyBorder(code))
        .strokeWidth(this.padKeyStrokeWidth(code) + 0.5)
      SymbolGlyph(symbol)
        .fontSize(this.ps(r * 1.1))
        .fontColor([this.padKeyFg(code)])
        .opacity(code < 0 ? 0.4 : 1)
    }
    .width(this.ps(r * 2))
    .height(this.ps(r * 2))
    .position({ x: this.ps(cx - r), y: this.ps(cy - r) })
  }

  // 扳机（LT/RT）：顶部全圆、底部小圆角的竖向键帽，内部自下而上按线性行程填充
  @Builder
  private VizTrigger(x: number, y: number, w: number, h: number, code: number, index: number) {
    // 注意：@Builder 多参数按值传递，动态值必须在内部读状态，不能作为参数传入
    Stack() {
      Column()
        .width('100%')
        .height(this.ps(h * Math.min(Math.max(this.triggerTravel(index, code), 0), 1)))
        .backgroundColor(this.padAccent())
        .opacity(0.45)
        .position({ x: 0, y: this.ps(h * (1 - Math.min(Math.max(this.triggerTravel(index, code), 0), 1))) })
    }
    .width(this.ps(w))
    .height(this.ps(h))
    .clip(true)
    .backgroundColor(this.padKeyBg(code))
    .borderRadius({
      topLeft: this.ps(w / 2),
      topRight: this.ps(w / 2),
      bottomLeft: this.ps(14),
      bottomRight: this.ps(14)
    })
    .border({ width: this.padKeyStrokeWidth(code) + 0.5, color: this.padKeyBorder(code) })
    .position({ x: this.ps(x), y: this.ps(y) })
  }

  // 肩键（LB/RB）：圆角矩形 + 标签
  @Builder
  private VizBumper(x: number, y: number, w: number, h: number, code: number, label: string) {
    Row() {
      Text(label)
        .fontSize(this.ps(h * 0.62))
        .fontWeight(FontWeight.Bold)
        .fontColor(this.padKeyFg(code))
        .maxLines(1)
    }
    .width(this.ps(w))
    .height(this.ps(h))
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.padKeyBg(code))
    .borderRadius(this.ps(10))
    .border({ width: this.padKeyStrokeWidth(code) + 0.5, color: this.padKeyBorder(code) })
    .position({ x: this.ps(x), y: this.ps(y) })
  }

  // 十字键已测描边：只画外侧三边（接十字中心的内边不画），与其他键帽同款
  // 「已测试=强调色描边」规范；未测宽度为 0 保持十字无缝
  private dpadEdgeWidths(code: number, outer: string): EdgeWidths {
    const w = this.isPadTested(code) ? this.padKeyStrokeWidth(code) + 0.5 : 0;
    return {
      left: outer === 'right' ? 0 : w,
      right: outer === 'left' ? 0 : w,
      top: outer === 'bottom' ? 0 : w,
      bottom: outer === 'top' ? 0 : w
    };
  }

  // 十字键一段（设计空间左上角 + 尺寸 + 外侧朝向），无描边以拼成一体十字
  @Builder
  private VizDpadSeg(x: number, y: number, w: number, h: number, code: number, outer: string) {
    Row() {
    }
    .width(this.ps(w))
    .height(this.ps(h))
    .backgroundColor(this.padKeyBg(code))
    .borderRadius(this.ps(3))
    .border({ width: this.dpadEdgeWidths(code, outer), color: this.padKeyBorder(code) })
    .position({ x: this.ps(x), y: this.ps(y) })
  }

  // 十字键：圆槽 + 中心块 + 四向臂（臂宽 30、全长 108，按 PAD_KEY_SCALE 放大）
  @Builder
  private VizDpad(cx: number, cy: number) {
    this.VizWell(cx, cy, 76 * PAD_KEY_SCALE)
    this.VizDpadSeg(cx - 15 * PAD_KEY_SCALE, cy - 15 * PAD_KEY_SCALE,
      30 * PAD_KEY_SCALE, 30 * PAD_KEY_SCALE, -1, '')
    this.VizDpadSeg(cx - 15 * PAD_KEY_SCALE, cy - 54 * PAD_KEY_SCALE,
      30 * PAD_KEY_SCALE, 40 * PAD_KEY_SCALE, 2012, 'top')
    this.VizDpadSeg(cx - 15 * PAD_KEY_SCALE, cy + 14 * PAD_KEY_SCALE,
      30 * PAD_KEY_SCALE, 40 * PAD_KEY_SCALE, 2013, 'bottom')
    this.VizDpadSeg(cx - 54 * PAD_KEY_SCALE, cy - 15 * PAD_KEY_SCALE,
      40 * PAD_KEY_SCALE, 30 * PAD_KEY_SCALE, 2014, 'left')
    this.VizDpadSeg(cx + 14 * PAD_KEY_SCALE, cy - 15 * PAD_KEY_SCALE,
      40 * PAD_KEY_SCALE, 30 * PAD_KEY_SCALE, 2015, 'right')
  }

  // 摇杆：圆槽 + 随轴移动的摇杆帽（帽内细环模拟防滑纹）；L3/R3 按压时帽变强调色
  @Builder
  private VizStick(cx: number, cy: number, axis: number, clickCode: number) {
    this.VizWell(cx, cy, 76 * PAD_KEY_SCALE)
    Stack() {
      Circle()
        .width(this.ps(108 * PAD_KEY_SCALE))
        .height(this.ps(108 * PAD_KEY_SCALE))
        .fill(this.padKeyBg(clickCode))
        .stroke(this.padKeyBorder(clickCode))
        .strokeWidth(this.padKeyStrokeWidth(clickCode) + 0.5)
      Circle()
        .width(this.ps(88 * PAD_KEY_SCALE))
        .height(this.ps(88 * PAD_KEY_SCALE))
        .fillOpacity(0)
        .stroke($r('sys.color.ohos_id_color_text_secondary'))
        .strokeOpacity(0.2)
        .strokeWidth(1)
    }
    .width(this.ps(108 * PAD_KEY_SCALE))
    .height(this.ps(108 * PAD_KEY_SCALE))
    .position({ x: this.ps(cx - 54 * PAD_KEY_SCALE), y: this.ps(cy - 54 * PAD_KEY_SCALE) })
    // 帽中心最大位移 = 槽半径 - 帽半径，保证帽不出槽
    .translate({
      x: this.ps(this.testAxes[axis] * 22 * PAD_KEY_SCALE),
      y: this.ps(this.testAxes[axis + 1] * 22 * PAD_KEY_SCALE)
    })
  }

  // ABXY：圆槽 + 菱形四键（Xbox 布局：Y 上 X 左 B 右 A 下）
  @Builder
  private VizFaceButtons(cx: number, cy: number) {
    this.VizWell(cx, cy, 76 * PAD_KEY_SCALE)
    this.VizCircleButton(cx, cy - 39 * PAD_KEY_SCALE, 26 * PAD_KEY_SCALE, 2305, 'Y')
    this.VizCircleButton(cx - 39 * PAD_KEY_SCALE, cy, 26 * PAD_KEY_SCALE, 2304, 'X')
    this.VizCircleButton(cx + 39 * PAD_KEY_SCALE, cy, 26 * PAD_KEY_SCALE, 2302, 'B')
    this.VizCircleButton(cx, cy + 39 * PAD_KEY_SCALE, 26 * PAD_KEY_SCALE, 2301, 'A')
  }

  @Builder
  private LegendDot(fill: ResourceColor, stroke: ResourceColor, label: string) {
    Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_s') }) {
      Circle()
        .width(10)
        .height(10)
        .fill(fill)
        .stroke(stroke)
        .strokeWidth(1.5)
      Text(label)
        .fontSize($r('sys.float.ohos_id_text_size_body3'))
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
    }
  }

  @Builder
  private GamepadDiagram() {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
      Stack() {
        // 机身剪影 + 握把分割线
        Path()
          .commands(this.scaledCommands(PAD_BODY_PATH))
          .fill($r('sys.color.ohos_id_color_sub_background'))
          .stroke($r('sys.color.ohos_id_color_text_secondary'))
          .strokeOpacity(0.45)
          .strokeWidth(2)
          .width(this.ps(PAD_W))
          .height(this.ps(PAD_H))
        Path()
          .commands(this.scaledCommands(PAD_DIVIDER_PATH))
          .fillOpacity(0)
          .stroke($r('sys.color.ohos_id_color_text_secondary'))
          .strokeOpacity(0.3)
          .strokeWidth(1.5)
          .width(this.ps(PAD_W))
          .height(this.ps(PAD_H))
        // 扳机 LT/RT（机身上方竖键，按行程填充）+ 肩键 LB/RB（扳机正下方）
        this.VizTrigger(243, 5, 58, 95, 2309, 0)
        this.VizTrigger(569, 5, 58, 95, 2310, 1)
        this.VizBumper(228, 108, 89, 37, 2307, 'LB')
        this.VizBumper(553, 108, 89, 37, 2308, 'RB')
        // HOME（中轴上方，带圆槽）+ View / Menu 横排（Share 无 GCK 键码，不绘制）
        this.VizWell(435, 225, 30)
        this.VizSymbolButton(435, 225, 23, 2313, $r('sys.symbol.house'))
        this.VizSymbolButton(405, 299, 20, 2311, $r('sys.symbol.rectangle_on_rectangle'))
        this.VizSymbolButton(465, 299, 20, 2312, $r('sys.symbol.line_3_horizontal'))
        // 左摇杆（左上）/ ABXY（右上）/ 十字键（左下）/ 右摇杆（右下），左右镜像
        this.VizStick(222, 295, 0, 2314)
        this.VizFaceButtons(648, 295)
        this.VizDpad(327, 450)
        this.VizStick(543, 450, 2, 2315)
      }
      .width(this.ps(PAD_W))
      .height(this.ps(PAD_H))
      // 图例：按下 / 已测试 / 未测试
      Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_l') }) {
        this.LegendDot(this.padAccent(), this.padAccent(), I18n.t('gamepad_test_legend_pressed'))
        this.LegendDot($r('sys.color.ohos_id_color_card_bg'), this.padAccent(),
          I18n.t('gamepad_test_legend_tested'))
        this.LegendDot($r('sys.color.ohos_id_color_card_bg'), $r('sys.color.ohos_id_color_list_separator'),
          I18n.t('gamepad_test_legend_idle'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: $r('sys.float.ohos_id_default_padding_top'), bottom: $r('sys.float.ohos_id_card_margin_middle'), left: $r('sys.float.ohos_id_elements_margin_horizontal_m'), right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
    // 按卡片可用宽度等比缩放整张手柄图，铺满卡片
    .onAreaChange((_old: Area, area: Area) => {
      const inner = Number(area.width) - 16;
      if (inner > 0) {
        this.padScale = inner / PAD_W;
      }
    })
  }

  // 扳机行程：优先线性轴；只有数字扳机的手柄按下即视为满行程
  private triggerTravel(index: number, code: number): number {
    const v = this.testTriggers[index] ?? 0;
    return this.testPressed.includes(code) ? Math.max(v, 1) : v;
  }

  // 摇杆示波器（对齐 gamepad-tester）：
  // 量程圈 + 死区圈 + 十字线 + 最大范围包络（圆度测试）+ 连续轨迹线 + 实时点 + 读数
  @Builder
  private StickScope(title: string, axis: number) {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
      Stack() {
        // 最大范围包络：各方向到过的最远点连成闭合多边形，越接近量程圈圆度越好
        Path()
          .commands(this.envelopeCommands(axis))
          .fill(this.padAccent())
          .fillOpacity(0.12)
          .stroke(this.padAccent())
          .strokeOpacity(0.5)
          .strokeWidth(1)
          .strokeLineJoin(LineJoinStyle.Round)
          .width(SCOPE_SIZE)
          .height(SCOPE_SIZE)
        Circle()
          .width(SCOPE_RADIUS * 2)
          .height(SCOPE_RADIUS * 2)
          .fillOpacity(0)
          .stroke($r('sys.color.ohos_id_color_text_secondary'))
          .strokeOpacity(0.35)
          .strokeWidth(1)
        Circle()
          .width(SCOPE_RADIUS * 2 * this.deadzone / 100)
          .height(SCOPE_RADIUS * 2 * this.deadzone / 100)
          .fill($r('sys.color.ohos_id_color_component_normal'))
        Column()
          .width(1)
          .height(SCOPE_RADIUS * 2)
          .backgroundColor($r('sys.color.ohos_id_color_list_separator'))
        Column()
          .width(SCOPE_RADIUS * 2)
          .height(1)
          .backgroundColor($r('sys.color.ohos_id_color_list_separator'))
        // 连续轨迹线（约 1 秒）：单个 Path 绘制，不存在逐点节点复用导致的闪烁
        Path()
          .commands(this.trailCommands(axis))
          .fillOpacity(0)
          .stroke(this.padAccent())
          .strokeOpacity(0.6)
          .strokeWidth(2)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
          .width(SCOPE_SIZE)
          .height(SCOPE_SIZE)
        Circle()
          .width(12)
          .height(12)
          .fill(this.stickMagnitude(this.testAxes[axis], this.testAxes[axis + 1]) * 100 > this.deadzone
            ? this.padAccent() : $r('sys.color.ohos_id_color_text_secondary'))
          .position({
            x: SCOPE_SIZE / 2 + this.clampUnit(this.testAxes[axis]) * SCOPE_RADIUS - 6,
            y: SCOPE_SIZE / 2 + this.clampUnit(this.testAxes[axis + 1]) * SCOPE_RADIUS - 6
          })
      }
      .width(SCOPE_SIZE)
      .height(SCOPE_SIZE)
      .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
      .borderRadius($r('sys.float.ohos_id_corner_radius_default_m'))
      Text(title)
        .fontSize($r('sys.float.ohos_id_text_size_body1'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
      Text(`X ${this.testAxes[axis].toFixed(2)}  Y ${this.testAxes[axis + 1].toFixed(2)}  ${Math.round(this.stickMagnitude(this.testAxes[axis], this.testAxes[axis + 1]) * 100)}%`)
        .fontSize($r('sys.float.ohos_id_text_size_body3'))
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Text(this.circularityText(axis))
        .fontSize($r('sys.float.ohos_id_text_size_body3'))
        .fontColor(this.circularityError(axis) >= 0 ? this.padAccent() : $r('sys.color.ohos_id_color_text_secondary'))
    }
    .alignItems(HorizontalAlign.Center)
  }

  // 摇杆坐标（单位圆）→ 示波器内 px 坐标；Path.commands 的单位是 px
  private scopePoint(x: number, y: number, limit: number): string {
    const k = this.getUIContext().vp2px(1);
    const m = Math.sqrt(x * x + y * y);
    const s = m > limit ? limit / m : 1;
    const px = (SCOPE_SIZE / 2 + x * s * SCOPE_RADIUS) * k;
    const py = (SCOPE_SIZE / 2 + y * s * SCOPE_RADIUS) * k;
    return `${px.toFixed(1)} ${py.toFixed(1)}`;
  }

  private trailCommands(axis: number): string {
    const trail = axis === 0 ? this.leftTrail : this.rightTrail;
    if (trail.length < 2) {
      return '';
    }
    let cmd = `M${this.scopePoint(trail[0][0], trail[0][1], 1)}`;
    for (let i = 1; i < trail.length; i++) {
      cmd += ` L${this.scopePoint(trail[i][0], trail[i][1], 1)}`;
    }
    return cmd;
  }

  // 包络允许超出量程圈（方形门限的手柄斜角可达 1.41），绘制时限制在示波器内
  private envelopeCommands(axis: number): string {
    const env = axis === 0 ? this.leftEnvelope : this.rightEnvelope;
    const limit = SCOPE_SIZE / 2 / SCOPE_RADIUS;
    let cmd = '';
    let count = 0;
    for (let i = 0; i < ENVELOPE_BUCKETS; i++) {
      if (env[i] <= 0) {
        continue;
      }
      const a = (i + 0.5) / ENVELOPE_BUCKETS * Math.PI * 2 - Math.PI;
      const p = this.scopePoint(Math.cos(a) * env[i], Math.sin(a) * env[i], limit);
      cmd += count === 0 ? `M${p}` : ` L${p}`;
      count++;
    }
    return count >= 3 ? `${cmd} Z` : '';
  }

  // 圆度误差（gamepad-tester 的 average error）：覆盖足够方向后，各方向最远半径与
  // 理想圆（1.0）的平均偏差；覆盖不足返回 -1
  private circularityError(axis: number): number {
    const env = axis === 0 ? this.leftEnvelope : this.rightEnvelope;
    let sum = 0;
    let filled = 0;
    for (const r of env) {
      if (r > 0) {
        sum += Math.abs(r - 1);
        filled++;
      }
    }
    return filled >= ENVELOPE_BUCKETS * ENVELOPE_MIN_COVERAGE ? sum / filled * 100 : -1;
  }

  private circularityText(axis: number): string {
    const err = this.circularityError(axis);
    if (err >= 0) {
      return I18n.tf1('gamepad_test_circularity_fmt', 'err', err.toFixed(1));
    }
    const env = axis === 0 ? this.leftEnvelope : this.rightEnvelope;
    const filled = env.filter((r: number) => r > 0).length;
    return I18n.tf1('gamepad_test_circularity_hint_fmt', 'pct',
      Math.round(filled / (ENVELOPE_BUCKETS * ENVELOPE_MIN_COVERAGE) * 100));
  }

  @Builder
  private TriggerBar(label: string, index: number, code: number) {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
      Row() {
        Text(label)
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Blank()
        Text(`${Math.round(this.triggerTravel(index, code) * 100)}%`)
          .fontSize($r('sys.float.ohos_id_text_size_body2'))
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      }
      .width('100%')
      Progress({ value: Math.round(this.triggerTravel(index, code) * 100), total: 100, type: ProgressType.Linear })
        .color(this.padAccent())
        .width('100%')
    }
    .layoutWeight(1)
  }

  @Builder
  private SticksPanel() {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_l') }) {
      Row() {
        this.StickScope(I18n.t('gamepad_test_left_stick'), 0)
        this.StickScope(I18n.t('gamepad_test_right_stick'), 2)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
      Row({ space: $r('sys.float.ohos_id_text_paragraph_margin_l') }) {
        this.TriggerBar('LT', 0, 2309)
        this.TriggerBar('RT', 1, 2310)
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('sys.float.ohos_id_card_margin_start'))
  }

  private clampUnit(v: number): number {
    return Math.max(-1, Math.min(1, v));
  }

  private stickMagnitude(x: number, y: number): number {
    return Math.min(Math.sqrt(x * x + y * y), 1);
  }

  private buttonCodeAt(index: number): number {
    if (index < 0 || index >= this.buttonCodes.length) {
      return -1;
    }
    return this.buttonCodes[index];
  }

  private hotkeyCodeAt(action: string): number {
    for (let i = 0; i < HOTKEY_ACTIONS.length; i++) {
      if (HOTKEY_ACTIONS[i] === action) {
        return this.hotkeyCodes[i];
      }
    }
    return -1;
  }

  @Builder
  private CaptureSheet() {
    Column() {
      SheetTitleBar(this.captureTitle, () => {
        this.cancelCapture();
      })
      Text(this.captureDesc)
        .fontSize($r('sys.float.ohos_id_text_size_body1'))
        .fontColor(TEXT_SECONDARY)
        .width('100%')
      Row() {
        SheetButton(I18n.t('clear'), false, true, this.padAccent(), () => {
          this.clearCaptureTarget();
        })
      }
      .width('100%')
      .margin({ top: $r('sys.float.ohos_id_elements_margin_vertical_m') })
    }
    .width('100%')
    .padding({
      left: SHEET_CONTENT_PADDING.left,
      right: SHEET_CONTENT_PADDING.right,
      top: SHEET_CONTENT_PADDING.top,
      bottom: this.safeAreaBottomVp
    })
    .backgroundColor(SHEET_BG_GROUPED)
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  /** 组合按键集面板：对齐布局编辑器"添加组件"的 Grid 卡片样式（卡片更小、
   *  多选切换而非单选添加），点选即时写回，全部取消即清空，无需确认按钮 */
  @Builder
  private ComboSheet() {
    Column() {
      SheetTitleBar(I18n.t('gamepad_combo_configure'), () => {
        this.showComboSheet = false;
      })

      Grid() {
        ForEach(COMBO_SHEET_OPTIONS, (opt: ComboSheetOption) => {
          GridItem() {
            Stack({ alignContent: Alignment.TopEnd }) {
              Column() {
                Stack() {
                  Image($rawfile(`themes/default/${opt.image}`))
                    .width('100%')
                    .height('100%')
                    .objectFit(ImageFit.Contain)
                    .draggable(false)
                  ForEach(this.dpadMasks(opt.index), (r: MaskRect) => {
                    Column()
                      .width(r.w)
                      .height(r.h)
                      .position({ x: r.x, y: r.y })
                      .backgroundColor($r('app.color.dpad_dim'))
                  }, (r: MaskRect) => `${opt.index}_${r.x}_${r.y}`)
                }
                .width('80%')
                .aspectRatio(1)
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              if (this.comboButtons.includes(opt.index)) {
                // 与屏幕滤镜卡片一致：描边 + 右上角主题色对号
                SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                  .fontSize(18)
                  .fontColor([ThemeManager.getInstance().getControlAccent()])
                  .margin({ top: 4, right: 4 })
              }
            }
            .width('100%')
          }
          .accessibilityText(I18n.t(opt.title))
          .aspectRatio(1)
          .backgroundColor(SHEET_CARD_BG)
          .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
          .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
          // 选中描边对齐屏幕滤镜卡片：2vp outline（画在卡片外沿不占内容）
          .outline({
            width: this.comboButtons.includes(opt.index) ? 2 : 0,
            color: ThemeManager.getInstance().getControlAccent(),
            radius: $r('sys.float.ohos_id_corner_radius_default_s')
          })
          .stateStyles({
            pressed: {
              .opacity(0.6)
            },
            normal: {
              .opacity(1.0)
            }
          })
          .onFocus(() => {
            this.soundEffectManager.play(SoundEffect.FOCUS);
          })
          .onClick(() => {
            this.toggleComboButton(opt.index);
          })
        }, (opt: ComboSheetOption) => `${opt.index}`)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(12)
      .rowsGap(12)
      // 2vp 内边距给选中描边（outline 画在卡片外沿）留位，否则贴边卡片的描边被裁
      .padding(2)
      .width('100%')
    }
    .width('100%')
    .padding({
      left: SHEET_CONTENT_PADDING.left,
      right: SHEET_CONTENT_PADDING.right,
      top: SHEET_CONTENT_PADDING.top,
      bottom: this.safeAreaBottomVp
    })
    .backgroundColor(SHEET_BG_GROUPED)
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Stack({ alignContent: Alignment.Top }) {
        SettingsList({ scroller: this.scroller, topSpace: NAV_TITLE_SCROLL_SPACE + SEGMENT_BAR_HEIGHT }) {
      if (this.selectedTab === GAMEPAD_TAB_MAPPING) {
      // 分区顺序对齐 Android addControlsSettings：
      // 按键 → Circle Pad → C-Stick → 十字方向键(轴) → 十字方向键(按键) → 双肩按键
      ListItem() {
        this.SectionHeader(I18n.t('gamepad_section_buttons'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        this.BindingRows(BUTTON_ROWS, 'gamepad_type_button')
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('gamepad_stick_circlepad'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        this.AxisBindingRows(CIRCLEPAD_AXIS_ROWS)
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('gamepad_stick_cstick'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        this.AxisBindingRows(CSTICK_AXIS_ROWS)
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('gamepad_section_dpad_axis'), I18n.t('gamepad_section_dpad_axis_desc'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        this.AxisBindingRows(DPAD_AXIS_ROWS)
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('gamepad_section_dpad_button'), I18n.t('gamepad_section_dpad_button_desc'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        this.BindingRows(DPAD_ROWS, 'gamepad_type_dpad')
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('gamepad_section_triggers'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        this.BindingRows(TRIGGER_ROWS, 'gamepad_type_trigger')
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 恢复默认映射（对应 Android 的 Auto-Map Controller；不常用，置底）
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ComposeListItem({
            contentItem: {
              primaryText: I18n.t('gamepad_restore_default'),
              secondaryText: I18n.t('gamepad_auto_map_desc')
            }
          })
            .onClick(() => {
              this.soundEffectManager.play(SoundEffect.DECIDE);
              // 批量重置无撤销路径，先弹确认（对齐 GameConfigSettings 的确认框写法）
              this.getUIContext().showAlertDialog({
                title: I18n.t('gamepad_restore_default'),
                message: I18n.t('gamepad_restore_default_confirm'),
                autoCancel: true,
                alignment: DialogAlignment.Center,
                primaryButton: {
                  value: I18n.t('gamepad_restore_default'),
                  fontColor: TEXT_DANGER,
                  action: () => {
                    this.soundEffectManager.play(SoundEffect.CONFIRM);
                    this.applyDefaultMapping();
                  }
                },
                secondaryButton: {
                  value: I18n.t('cancel'),
                  fontColor: controlAccentOf(this.themeColors),
                  action: () => {
                    this.soundEffectManager.play(SoundEffect.BACK);
                  }
                },
                cancel: () => {
                  this.soundEffectManager.play(SoundEffect.BACK);
                }
              });
            })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      }
      if (this.selectedTab === GAMEPAD_TAB_SETTINGS) {
      ListItem() {
        this.SectionHeader(I18n.t('gamepad_section_sticks'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          SliderSettingItem({
            title: I18n.t('settings_joystick_dead_zone'),
            description: I18n.t('gamepad_deadzone_desc'),
            value: this.deadzone,
            min: 0,
            max: 50,
            step: 1,
            formatValue: (value: number): string => `${value}%`,
            onChange: (value: number) => {
              this.deadzone = value;
              this.updateNumber(KEY_GAMEPAD_DEADZONE, value);
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      }
      if (this.selectedTab === GAMEPAD_TAB_HOTKEYS) {
      ListItem() {
        this.SectionHeader(I18n.t('gamepad_section_hotkeys'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ForEach(HOTKEY_ROWS, (row: HotkeyRow) => {
          ListItem() {
            GamepadBindingItem({
              title: I18n.t(row.title),
              description: row.desc !== undefined ? I18n.t(row.desc) : '',
              value: this.boundLabel(this.hotkeyCodeAt(row.action)),
              icon: this.hotkeyCodeAt(row.action) >= 0 ? this.boundIcon(this.hotkeyCodeAt(row.action)) : null,
              listening: this.capturingTarget === `hotkey:${row.action}`,
              listeningText: I18n.t('gamepad_binding_listening'),
              deletable: this.hotkeyCodeAt(row.action) >= 0,
              onSelect: () => {
                this.beginCapture(`hotkey:${row.action}`,
                  I18n.tf2('gamepad_bind_title_fmt', 'type', I18n.t('gamepad_type_hotkey'), 'name', I18n.t(row.title)),
                  false, I18n.t('gamepad_capture_kb_desc'));
              },
              onClear: () => {
                const hotkeys: number[] = [];
                for (const c of this.hotkeyCodes) {
                  hotkeys.push(c);
                }
                for (let i = 0; i < HOTKEY_ACTIONS.length; i++) {
                  if (HOTKEY_ACTIONS[i] === row.action) {
                    hotkeys[i] = -1;
                  }
                }
                this.hotkeyCodes = hotkeys;
                this.updateString(KEY_GAMEPAD_HOTKEY_MAP, this.encodeHotkeyMap());
              }
            })
          }
        }, (row: HotkeyRow) => row.action)
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 组合按键独立分组：绑定行 + 配置行放在一起（对齐 Android 的
      // Hotkey Button Combo + Configure Combo Button 两个入口）
      ListItem() {
        this.SectionHeader(I18n.t('gamepad_section_combo'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          GamepadBindingItem({
            title: I18n.t('gamepad_combo_button'),
            description: I18n.t('gamepad_combo_button_desc'),
            value: this.boundLabel(this.comboCode),
            icon: this.comboCode >= 0 ? this.boundIcon(this.comboCode) : null,
            listening: this.capturingTarget === 'combo',
            listeningText: I18n.t('gamepad_binding_listening'),
            deletable: this.comboCode >= 0,
            onSelect: () => {
              // 与其他绑定行一致：点按永远进入捕获（重绑触发键）
              this.beginCapture('combo', I18n.t('gamepad_bind_combo_title'));
            },
            onClear: () => {
              this.saveCombo(-1, []);
            }
          })
        }
        // 对齐 Android Configure Combo Button：多选组合触发的 3DS 键，
        // 独立于绑定可配置（允许先配目标、后绑触发键）
        ListItem() {
          ComposeListItem({
            contentItem: {
              primaryText: I18n.t('gamepad_combo_configure'),
              secondaryText: this.comboSummary() !== '' ? this.comboSummary() : I18n.t('gamepad_combo_configure_desc')
            }
          })
            .onClick(() => {
              this.soundEffectManager.play(SoundEffect.DECIDE);
              this.openComboSheet();
            })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())

      }
      if (this.selectedTab === GAMEPAD_TAB_SETTINGS) {
      // 杂项卡不再加分区头（Tab 名即"杂项"）
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('use_artic_base_controller'),
            description: I18n.t('use_artic_base_controller_desc'),
            isOn: this.useArticBaseController,
            requiresRestart: true,
            onToggle: (value: boolean) => {
              this.useArticBaseController = value;
              this.updateBoolean(KEY_USE_ARTIC_BASE_CONTROLLER, value);
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      }
      if (this.selectedTab === GAMEPAD_TAB_TEST) {
      // 测试 tab（对齐 gamepad-tester / Steam / 8BitDo 测试器）：
      // 设备与覆盖进度 → 手柄图（三态 + 映射视图）→ 摇杆示波器与扳机 → 输入日志
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ComposeListItem({
            contentItem: {
              icon: $r('sys.symbol.gamecontroller'),
              symbolStyle: new SymbolGlyphModifier($r('sys.symbol.gamecontroller')),
              primaryText: this.testOnline
                ? (this.testDeviceName.length > 0 ? this.testDeviceName : I18n.t('gamepad_test_device_generic'))
                : I18n.t('gamepad_test_offline'),
              secondaryText: this.testOnline
                ? I18n.tf2('gamepad_test_progress_fmt', 'done', this.testTargetCount(), 'total',
                  TEST_KEY_CODES.length)
                : I18n.t('gamepad_test_connect_hint')
            },
            operateItem: {
              text: `${this.testTargetCount()}/${TEST_KEY_CODES.length}`
            }
          })
        }
        ListItem() {
          ComposeListItem({
            contentItem: {
              icon: $r('sys.symbol.arrow_clockwise'),
              symbolStyle: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise')),
              primaryText: I18n.t('gamepad_test_reset'),
              secondaryText: I18n.t('gamepad_test_reset_desc')
            }
          })
            .onClick(() => {
              this.soundEffectManager.play(SoundEffect.CONFIRM);
              this.resetTest();
            })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          this.GamepadDiagram()
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('gamepad_test_section_sticks'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          this.SticksPanel()
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .margin(menuGroupMargin())

      ListItem() {
        this.SectionHeader(I18n.t('gamepad_test_section_log'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        if (this.testLog.length === 0) {
          ListItem() {
            // 纯信息展示行，无点击事件——用无按压态的静态行
            StaticInfoRow({ title: I18n.t('gamepad_test_log_empty') })
          }
        }
        ForEach(this.testLog, (entry: TestLogEntry) => {
          ListItem() {
            StaticInfoRow({
              title: `${this.physKeyLabel(entry.code)} (${entry.rawCode}) · ${entry.down
                ? I18n.t('gamepad_test_down') : I18n.t('gamepad_test_up')}`,
              desc: `→ ${this.boundTargetFor(entry.code)}`,
              value: this.logAgeText(entry)
            })
          }
        }, (entry: TestLogEntry) => `${entry.seq}_${Math.floor((this.testNowMs - entry.timeMs) / 1000)}`)
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())
      }
        }
      }
      .width('100%')
      .height('100%')
      // 每个 bindSheet 各占一个宿主节点（与 LayoutEditorSheets 同款空 Column 挂载）
      Column()
        .bindSheet($$this.showCaptureSheet, this.CaptureSheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK),
          onWillDismiss: () => {
          },
          onDisappear: () => {
            this.cancelCapture();
          }
        })
      Column()
        .bindSheet($$this.showComboSheet, this.ComboSheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
        })
    }
    .width('100%')
    .height('100%')
  }

}

/**
 * Azahar - 触屏按键布局管理设置页面
 *
 * 移植自 NDS 项目的布局管理功能:
 * - 布局列表: 默认布局 + 自定义布局，RadioButton 选择，+ 创建，MoreVert 编辑/删除
 * - 布局编辑器: 全屏黑色背景，组件拖拽，底部控制栏(添加组件+菜单)，缩放控制面板
 * - 属性对话框: 名称、按键透明度滑块
 * - 菜单: 属性、撤销更改、重置默认、保存并退出、退出不保存
 */

import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { FloatTilesBackground } from '../../components/theme/FloatTilesBackground';
import { ThemeManager } from '../../utils/ThemeManager';
import { AzaharLoadingDialog } from '../../components/common/AzaharLoadingDialog';
import { AzaharThemeColors, AzaharTheme } from '../../types/ThemeTypes';
import { LayoutConfigManager } from '../../utils/LayoutConfigManager';
import { LayoutConfiguration, LayoutComponent, PositionedLayoutComponent, LayoutRect, LayoutOrientation, ALL_LAYOUT_COMPONENTS, isScreenComponent, getComponentDisplayName, getComponentImageName, UILayoutVariant, Orientation, variantToKey, BackgroundMode, LayoutBackground, THEME_COLOR_BG_URI, isRawfileBgUri, rawfileBgPath, BUILTIN_BACKGROUNDS, BuiltinLayoutBackground,  } from '../../types/LayoutTypes';
import { SoundEffectManager, SoundEffect } from '../../utils/SoundEffectManager';
import { I18n } from '../../utils/I18nManager';
import { PAGE_TRANSITION_DURATION } from '../../utils/PageTransitionHelper';

import { LayoutBackgroundDialogs } from '../../components/settings/layouts/LayoutBackgroundDialogs';
import { LayoutEditorSheets } from '../../components/settings/layouts/LayoutEditorSheets';
import { LayoutListSection } from '../../components/settings/layouts/LayoutListSection';
import { LayoutPreviewThumbnail } from '../../components/settings/LayoutPreviewThumbnail';
import { AzaharEmptySlot } from '../../components/game/AzaharEmptySlot';
import { SnapGuideSystem, SnapGuideLine } from '../../utils/SnapGuideSystem';
import { picker } from '@kit.CoreFileKit';
import { SettingsManager } from '../../utils/SettingsManager';
import { createScrollSource, setScrollSourceActive } from '../../utils/ScrollAnimationState';
import { themedImagePath, designedButtonRect, ButtonRect, normalizeRectToTheme, getOverlayThemeNameKey, getThemeAbxy, AbxyButtonSpec, getOverlayControlSizes } from '../../utils/OverlayThemeHelper';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { AzaharNavPage } from '../../components/common/AzaharNavPage';
import { immersiveMaterial } from '../../components/common/AzaharControls';
import { SettingsList, settingsGroupDivider } from '../../components/settings/SettingsList';
import {
  BUTTON_BG_SECONDARY,
  RADIUS_SHEET,
  SHEET_BG_GROUPED,
  SHEET_BUTTON_HEIGHT,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING,
  TEXT_DANGER,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';
import { KEY_IGNORE_SAFE_AREA, KEY_LAYOUT_EDITOR_GRID_SIZE, KEY_OVERLAY_THEME } from '../../types/SettingsTypes';

const BACKGROUND_LIST_KEY: string = 'background_list';

const DOMAIN = 0xFF00;
const TAG = 'Azahar_LayoutsSettings';
const BUILTIN_DEFAULT_ID = '__builtin_default__';

const GAME_RATIO = 400 / 240; // 3DS 上屏 5:3
const WIDESCREEN_RATIO = 16 / 9;
const MIN_COMPONENT_SIZE = 30;
const DEFAULT_COMPONENT_WIDTH = 100;

// ============================================================================
// 页面状态枚举
// ============================================================================

enum PageMode {
  LIST = 'list',
  EDITOR = 'editor',
}

interface SafeBounds {
  left: number
  top: number
  right: number
  bottom: number
  width: number
  height: number
}

/**
 * 路由参数接口
 * selectMode: 从 GameConfigSettings 跳转时为 true，选择后回传 layoutId
 * currentLayoutId: 当前 ROM 配置的 layoutId (用于高亮当前选中项)
 */
interface LayoutsSettingsRouterParams {
  selectMode?: boolean;
  currentLayoutId?: string | null;
}

@Entry
@Component
struct LayoutsSettings {
  @State private mode: PageMode = PageMode.LIST;
  @State private isLoading: boolean = true;
  @StorageLink('safeAreaTopVp') safeAreaTopVp: number = 0;
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;
  @State private layouts: LayoutConfiguration[] = [];
  @State private selectedLayoutId: string = BUILTIN_DEFAULT_ID;
  @State private refreshKey: number = 0;

  // 选择器模式: 从 GameConfigSettings 跳转过来选择布局 (对齐 Android ActionLauncherItem -> LayoutSelector)
  private isSelectMode: boolean = false;
  private selectModeCurrentId: string | null = null;

  // 编辑器状态
  @State private editingLayout: LayoutConfiguration | null = null;
  @State private initialLayout: LayoutConfiguration | null = null; // 用于撤销
  @State private editorComponents: PositionedLayoutComponent[] = [];
  @State private selectedComponentId: string = '';  // LayoutComponent enum value, '' = none
  @State private editorWidth: number = 360;
  @State private editorHeight: number = 640;
  @State @Watch('onGridSizeChanged') private gridSize: number = SnapGuideSystem.GRID_SIZE;
  @State private gridCanvasWidth: number = 0;
  @State private gridCanvasHeight: number = 0;
  private gridCanvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private gridCanvasContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.gridCanvasSettings);
  // 当前编辑器的布局变体 (对齐 Android LayoutEditorViewModel.currentLayoutVariant)
  private currentVariant: UILayoutVariant | null = null;

  // 安全区域偏移 (vp) - 参考 GameView.updateSafeAreaOffsets
  @State private safeTop: number = 0;
  @State private safeBottom: number = 0;
  @State private safeLeft: number = 0;
  @State private safeRight: number = 0;
  // 是否忽略安全区域 (用户设置)
  private ignoreSafeArea: boolean = false;
  // 按键遮罩主题
  @State private overlayTheme: string = 'default';

  // 拖拽状态 (对齐 Android LayoutEditorView 的 touch handling)
  // Android: ACTION_DOWN 记录 downOffsetX/Y, ACTION_MOVE 判断距离>25开始拖拽, ACTION_UP 未拖拽则选中
  private touchDownX: number = 0; // 窗口坐标系下的触摸起始位置
  private touchDownY: number = 0;
  private dragCompStartX: number = 0;
  private dragCompStartY: number = 0;
  private isDragging: boolean = false;
  @State private touchedId: string = ''; // 当前触摸中的组件 (对齐 Android alpha=1 + highlighted)
  // 拖拽偏移量 - 使用 translate 实现视觉移动，避免 ForEach 重建组件导致触摸序列中断
  @State private dragOffsetX: number = 0;
  @State private dragOffsetY: number = 0;
  @State private dragTargetId: string = ''; // 当前正在拖拽的组件

  // 缩放控制状态 (对齐 Android LayoutEditorManagerView 的状态变量)
  @State private showScalingControls: boolean = false;
  @State private showBottomControls: boolean = true;
  @State private currentWidthScale: number = 0;
  @State private currentHeightScale: number = 0;
  @State private selectedViewIsScreen: boolean = false;
  // 对齐 Android: selectedViewMinSize, seekBarWidth.max, seekBarHeight.max
  @State private selectedViewMinSize: number = MIN_COMPONENT_SIZE;
  @State private scalingMaxWidth: number = 0; // 对齐 Android seekBarWidth.max = canvas width (vp)
  @State private scalingMaxHeight: number = 0; // 对齐 Android seekBarHeight.max = canvas height (vp)
  // 对齐 Android: selectedViewAnchor (缩放锚点，基于组件离哪个角最近)
  private selectedViewAnchor: number = 0; // 0=TOP_LEFT, 1=TOP_RIGHT, 2=BOTTOM_LEFT, 3=BOTTOM_RIGHT
  // 组件原始宽高比 (用于缩放时保持比例)
  private selectedComponentRatio: number = 1;
  // 长按 ± 按钮连续触发
  private repeatTimerId: number = -1;
  private repeatCount: number = 0;

  // 吸附系统
  private snapSystem: SnapGuideSystem = new SnapGuideSystem();
  @State private snapGuideLines: SnapGuideLine[] = [];

  // 对话框状态
  @State private showAddComponentDialog: boolean = false;
  @State private showGridSizeDialog: boolean = false;
  @State private showPropertiesDialog: boolean = false;
  @State private showBackgroundDialog: boolean = false;
  @State private dialogBackgroundUri: string = '';
  @State private dialogBackgroundMode: BackgroundMode = BackgroundMode.FIT_CENTER;
  // 背景管理页面状态 (对齐 Android BackgroundsActivity)
  @State private showBackgroundManager: boolean = false;
  @State private backgroundList: LayoutBackground[] = [];
  @State private selectedBackgroundId: string = '';
  @State private showBackgroundPreview: boolean = false;
  @State private previewBackground: LayoutBackground | null = null;
  @State private showBackgroundNameInput: boolean = false;
  @State private backgroundNameInputText: string = '';
  @State private pendingBackgroundUri: string = '';
  @State private showNameInputDialog: boolean = false;
  @State private showMenuSheet: boolean = false;
  @State private nameInputText: string = I18n.t('custom_layout');
  @State private dialogLayoutName: string = '';
  @State private dialogUseCustomOpacity: boolean = false;
  @State private dialogOpacity: number = 50;
  @State private dialogSecondaryScreenOpacity: number = 100;
  @State private dialogTargetLayout: LayoutConfiguration | null = null;

  // 主题
  @State private themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();
  @StorageLink('isWaveAnimationPlaying') isWaveAnimationPlaying: boolean = false;

  private layoutManager: LayoutConfigManager = LayoutConfigManager.getInstance();
  private themeManager: ThemeManager = ThemeManager.getInstance();
  private listScroller: Scroller = new Scroller();
  private dialogScrollSourceId: number = createScrollSource();
  private themeChangeListener: ((theme: AzaharTheme) => void) | null = null;
  private confirmDialogController: CustomDialogController | null = null;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private windowClass: window.Window | null = null;
  private windowInitPromise: Promise<void> | null = null;
  private displayChangeCallback: ((displayId: number) => void) | null = null;

  aboutToAppear(): void {
    // 读取路由参数: 是否为选择器模式 (从 GameConfigSettings 跳转)
    const params = router.getParams() as LayoutsSettingsRouterParams | undefined;
    if (params?.selectMode) {
      this.isSelectMode = true;
      this.selectModeCurrentId = params.currentLayoutId ?? null;
    }

    this.themeColors = this.themeManager.getCurrentColors();
    this.themeChangeListener = (_theme: AzaharTheme) => {
      this.themeColors = this.themeManager.getCurrentColors();
    };
    this.themeManager.addListener(this.themeChangeListener);
    this.ignoreSafeArea = SettingsManager.getInstance().getSync<boolean>(KEY_IGNORE_SAFE_AREA, false);
    this.overlayTheme = SettingsManager.getInstance().getSync<string>(KEY_OVERLAY_THEME, 'default');
    this.setGridSize(SettingsManager.getInstance().getSync<number>(
      KEY_LAYOUT_EDITOR_GRID_SIZE, SnapGuideSystem.GRID_SIZE));
    this.detectScreenSize();
    this.initSafeAreaMonitoring();
    this.registerDisplayChangeListener();
    this.initAndLoad();
  }

  aboutToDisappear(): void {
    setScrollSourceActive(this.dialogScrollSourceId, false);
    if (this.repeatTimerId !== -1) {
      clearInterval(this.repeatTimerId);
      this.repeatTimerId = -1;
    }
    if (this.themeChangeListener) {
      this.themeManager.removeListener(this.themeChangeListener);
      this.themeChangeListener = null;
    }
    if (this.windowClass) {
      try {
        this.windowClass.off('avoidAreaChange');
      } catch (_e) { /* ignore */ }
    }
    this.unregisterDisplayChangeListener();
  }

  /**
   * 拦截系统返回键 (对齐 Android LayoutEditorActivity.onBackPressedDispatcher)
   * 编辑器模式下: 弹出菜单而不是直接退出
   * 列表模式下: 正常返回
   */
  onBackPress(): boolean {
    if (this.mode === PageMode.EDITOR) {
      if (this.showGridSizeDialog) {
        this.showGridSizeDialog = false;
        this.showBottomControls = true;
        return true;
      }
      this.storeLayoutChanges();
      this.showEditorMenuSheet();
      return true; // 消费事件，阻止默认返回
    }
    return false; // 列表模式，走默认返回
  }

  private detectScreenSize(): void {
    // 优先使用窗口实际尺寸 (支持分屏/自由多窗)
    if (this.windowClass) {
      try {
        const props = this.windowClass.getWindowProperties();
        // drawableRect (API 11+) 排除窗口装饰栏 (自由多窗标题栏)
        const rect = (props.drawableRect && props.drawableRect.width > 0) ? props.drawableRect : props.windowRect;
        const dp = display.getDefaultDisplaySync().densityPixels || 1;
        this.editorWidth = Math.round(rect.width / dp);
        this.editorHeight = Math.round(rect.height / dp);
        return;
      } catch (_e) { /* fall through to display */ }
    }
    try {
      const d = display.getDefaultDisplaySync();
      const dp = d.densityPixels || 1;
      const isDeviceLandscape = d.orientation === display.Orientation.LANDSCAPE
        || d.orientation === display.Orientation.LANDSCAPE_INVERTED;
      const w = isDeviceLandscape ? Math.max(d.width, d.height) : Math.min(d.width, d.height);
      const h = isDeviceLandscape ? Math.min(d.width, d.height) : Math.max(d.width, d.height);
      this.editorWidth = Math.round(w / dp);
      this.editorHeight = Math.round(h / dp);
    } catch (_e) {
      this.editorWidth = 360;
      this.editorHeight = 640;
    }
  }

  // 编辑器旋转前的方向 (用于检测方向是否真正变化)
  private lastEditorOrientation: string = '';

  /**
   * 注册显示变化监听器 (对齐 GameView.registerDisplayListener)
   * 当设备旋转时，更新编辑器尺寸和当前变体，重新加载组件
   */
  private registerDisplayChangeListener(): void {
    this.displayChangeCallback = (_displayId: number) => {
      // display.on('change') 回调可能在方向数据更新前触发
      // 始终延迟一帧确保 display/window 数据完全更新 (对齐 GameView.registerDisplayListener)
      setTimeout(() => {
        try {
          this.handleOrientationOrSizeChange();
        } catch (e) {
          hilog.error(DOMAIN, TAG, 'Failed to handle display change: %{public}s', (e as Error).message);
        }
      }, 50);
    };
    try {
      display.on('change', this.displayChangeCallback);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to register display change listener: %{public}s', (e as Error).message);
    }
  }

  /**
   * 统一处理方向变化或窗口尺寸变化
   * 由 display.on('change') (延迟后) 和 window.on('windowSizeChange') 共同调用
   * 使用实际窗口尺寸判断方向，不依赖 display.orientation (可能延迟更新)
   */
  private handleOrientationOrSizeChange(): void {
    const prevWidth = this.editorWidth;
    const prevHeight = this.editorHeight;

    if (this.mode === PageMode.EDITOR && this.editingLayout) {
      // 先探测新的窗口尺寸 (不更新 editorWidth/editorHeight)
      let newW = this.editorWidth;
      let newH = this.editorHeight;
      if (this.windowClass) {
        try {
          const props = this.windowClass.getWindowProperties();
          const rect = (props.drawableRect && props.drawableRect.width > 0) ? props.drawableRect : props.windowRect;
          const dp = display.getDefaultDisplaySync().densityPixels || 1;
          newW = Math.round(rect.width / dp);
          newH = Math.round(rect.height / dp);
        } catch (_e) { /* keep previous */ }
      }
      const newOrientation = newW > newH ? 'LANDSCAPE' : 'PORTRAIT';

      if (newOrientation !== this.lastEditorOrientation) {
        // 方向变化: 先保存旧变体 (此时 editorWidth/editorHeight 和组件还是旧方向的)
        this.storeLayoutChanges();
        // 再更新尺寸和安全区域
        this.updateSafeAreaOffsets();
        this.lastEditorOrientation = newOrientation;
        this.currentVariant = this.resolveEditorVariant();
        this.loadEditorComponents();
        this.selectedComponentId = '';
        this.showScalingControls = false;
      } else {
        this.updateSafeAreaOffsets();
        if (prevWidth !== this.editorWidth || prevHeight !== this.editorHeight) {
          // 同方向但尺寸变化: 超出容差(折叠/展开、分屏)切换变体，容差内仅 clamp
          const next = LayoutConfigManager.buildVariant(this.editorWidth, this.editorHeight);
          if (this.currentVariant && !LayoutConfigManager.isSameVariantSize(next, this.currentVariant)) {
            this.storeLayoutChanges(); // 组件仍是旧尺寸，写回旧变体 key
            this.currentVariant = this.resolveEditorVariant();
            this.loadEditorComponents();
            this.selectedComponentId = '';
            this.showScalingControls = false;
          } else {
            this.clampAllComponentsToSafeBounds();
          }
        }
      }
    } else {
      this.updateSafeAreaOffsets();
      if (prevWidth !== this.editorWidth || prevHeight !== this.editorHeight) {
        // 列表模式下窗口尺寸变化 (折叠/展开、分屏): 触发预览缩略图按新设备尺寸重算
        this.refreshKey++;
      }
    }
  }

  private unregisterDisplayChangeListener(): void {
    if (this.displayChangeCallback) {
      try {
        display.off('change', this.displayChangeCallback);
      } catch (_e) { /* ignore */ }
      this.displayChangeCallback = null;
    }
    // 移除窗口尺寸变化监听
    if (this.windowClass) {
      try {
        this.windowClass.off('windowSizeChange');
      } catch (_e) { /* ignore */ }
    }
  }

  // ============================================================================
  // 主题感知颜色工具 (对齐 Index.ets HowToGetGamesDialog / UploadDialog)
  // ============================================================================

  /** 将 hex 颜色字符串转为 number (用于 linearGradient) */
  private hexToNumber(hexColor: string): number {
    const hex = hexColor.startsWith('#') ? hexColor.slice(1) : hexColor;
    return parseInt(hex, 16);
  }

  private getLuminance(hex: string): number {
    const r = parseInt(hex.slice(1, 3), 16) / 255;
    const g = parseInt(hex.slice(3, 5), 16) / 255;
    const b = parseInt(hex.slice(5, 7), 16) / 255;
    const toLinear = (c: number): number => c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    return 0.2126 * toLinear(r) + 0.7152 * toLinear(g) + 0.0722 * toLinear(b);
  }

  /**
   * 根据主题色亮度计算 noise 纹理透明度 (对齐 iPod 项目 DeviceColorStyle.noiseOpacity)
   *
   * iPod 的规律:
   *   浅色主题 (silver/pink/orange/yellow 等) → noiseOpacity = 1.0
   *   中间色 (blue/brown/green)              → noiseOpacity = 0.6~0.8
   *   深色主题 (black)                        → noiseOpacity = 0.3
   *
   * noise.webp 是白色像素+随机低 alpha 的纹理，深色背景上白色噪点过于突兀需要降低 opacity。
   * 这里基于 gradientStart 亮度线性映射到 [0.3, 1.0] 区间。
   */
  private getNoiseOpacity(): number {
    const lum = this.getLuminance(this.themeColors.gradientStart);
    // lum 范围 [0, 1]，映射到 opacity [0.3, 1.0]
    return 0.3 + lum * 0.7;
  }

  private darkenColor(hex: string, factor: number): string {
    const r = Math.round(parseInt(hex.slice(1, 3), 16) * factor);
    const g = Math.round(parseInt(hex.slice(3, 5), 16) * factor);
    const b = Math.round(parseInt(hex.slice(5, 7), 16) * factor);
    const toHex = (v: number): string => Math.min(255, v).toString(16).padStart(2, '0');
    return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
  }

  private lightenColor(hex: string, minVal: number): string {
    const r = Math.max(parseInt(hex.slice(1, 3), 16), minVal);
    const g = Math.max(parseInt(hex.slice(3, 5), 16), minVal);
    const b = Math.max(parseInt(hex.slice(5, 7), 16), minVal);
    const toHex = (v: number): string => Math.min(255, v).toString(16).padStart(2, '0');
    return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
  }

  private getContrast(hex1: string, hex2: string): number {
    const l1 = this.getLuminance(hex1);
    const l2 = this.getLuminance(hex2);
    return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
  }

  /** 弹窗背景色: 基于 gradientEnd 压暗/提亮 */
  private getThemedDialogBg(): string {
    const base = this.themeColors.gradientEnd;
    const lum = this.getLuminance(base);
    if (lum > 0.05) return this.darkenColor(base, 0.35);
    if (lum < 0.02) return this.lightenColor(base, 0x30);
    return base;
  }

  /** 按钮背景色: 基于 primary + alpha, 对比度不足时回退半透明白 */
  private getThemedButtonBg(): ResourceColor {
    const bgColor = this.getThemedDialogBg();
    const contrast = this.getContrast(this.themeColors.primary, bgColor);
    if (contrast >= 2.0) {
      return '#40' + this.themeColors.primary.slice(1);
    }
    return $r('sys.color.ohos_id_color_button_normal');
  }

  /** 列表项背景色: 比按钮更淡 */
  private getThemedItemBg(): ResourceColor {
    const bgColor = this.getThemedDialogBg();
    const contrast = this.getContrast(this.themeColors.primary, bgColor);
    if (contrast >= 1.5) {
      return '#25' + this.themeColors.primary.slice(1);
    }
    return $r('app.color.editor_divider_dark');
  }

  /** 底部控制栏背景: 基于 gradientEnd 深度压暗 */
  private getThemedBarBg(): ResourceColor {
    const base = this.themeColors.gradientEnd;
    const lum = this.getLuminance(base);
    if (lum > 0.03) return this.darkenColor(base, 0.25) + 'CC';
    return $r('app.color.editor_bar_scrim');
  }

  /** 编辑器是否使用了亮色背景 (主题色或自定义图片) */
  private hasLightEditorBackground(): boolean {
    if (!this.editingLayout?.backgroundUri) return false;
    if (this.editingLayout.backgroundUri === THEME_COLOR_BG_URI) {
      // 主题色背景: 根据渐变起始色亮度判断
      return this.getLuminance(this.themeColors.gradientStart) > 0.15;
    }
    // 自定义图片背景: 保守地认为可能是亮色
    return true;
  }

  /** 网格点颜色: 暗底用半透明白，亮底用半透明黑（Canvas fillStyle 只收 string，保留字面量） */
  private getGridDotColor(): string {
    return this.hasLightEditorBackground() ? '#55000000' : '#40FFFFFF';
  }

  /** 画布中心十字线颜色（Canvas fillStyle 只收 string，保留字面量） */
  private getCenterCrossColor(): string {
    return this.hasLightEditorBackground() ? '#50FF6600' : '#35FFFF00';
  }

  /** 吸附辅助线颜色 (网格类型) */
  private getGridGuideColor(): ResourceColor {
    return this.hasLightEditorBackground() ? $r('app.color.grid_guide_on_light') : $r('app.color.grid_guide_on_dark');
  }

  private initSafeAreaMonitoring(): void {
    void this.ensureWindowReady();
  }

  private async ensureWindowReady(): Promise<void> {
    if (this.windowClass) return;
    if (this.windowInitPromise) {
      await this.windowInitPromise;
      return;
    }
    this.windowInitPromise = window.getLastWindow(this.context).then((mainWindow: window.Window) => {
      this.windowClass = mainWindow;
      this.updateSafeAreaOffsets();
      try {
        this.windowClass.off('avoidAreaChange');
      } catch (_e) { /* ignore */ }
      this.windowClass.on('avoidAreaChange', (_data) => {
        this.updateSafeAreaOffsets();
      });
      // 监听窗口尺寸变化 (分屏/自由多窗模式，以及旋转时窗口尺寸变化)
      this.windowClass.on('windowSizeChange', (size: window.Size) => {
        hilog.debug(DOMAIN, TAG, 'Window size changed: %{public}dx%{public}d', size.width, size.height);
        this.handleOrientationOrSizeChange();
      });
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'Failed to init safe area monitoring: %{public}s', err.message);
    }).finally(() => {
      this.windowInitPromise = null;
    });
    await this.windowInitPromise;
  }

  private updateSafeAreaOffsets(): void {
    if (!this.windowClass) return;
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      const densityPixels = defaultDisplay.densityPixels || 1;
      // 优先使用窗口实际尺寸 (分屏/自由多窗下窗口尺寸 ≠ 屏幕尺寸)
      let screenWidthPx: number;
      let screenHeightPx: number;
      try {
        const props = this.windowClass.getWindowProperties();
        // drawableRect (API 11+) 排除窗口装饰栏，是实际可绘制区域
        const rect = (props.drawableRect && props.drawableRect.width > 0) ? props.drawableRect : props.windowRect;
        screenWidthPx = rect.width;
        screenHeightPx = rect.height;
      } catch (_e) {
        const physicalW = defaultDisplay.width;
        const physicalH = defaultDisplay.height;
        const isDeviceLandscape = defaultDisplay.orientation === display.Orientation.LANDSCAPE
          || defaultDisplay.orientation === display.Orientation.LANDSCAPE_INVERTED;
        screenWidthPx = isDeviceLandscape ? Math.max(physicalW, physicalH) : Math.min(physicalW, physicalH);
        screenHeightPx = isDeviceLandscape ? Math.min(physicalW, physicalH) : Math.max(physicalW, physicalH);
      }

      this.editorWidth = Math.round(screenWidthPx / densityPixels);
      this.editorHeight = Math.round(screenHeightPx / densityPixels);

      // “忽略安全区域”仅忽略系统避让；全局自定义底部安全区始终生效。
      if (this.ignoreSafeArea) {
        this.safeTop = 0;
        this.safeBottom = this.editorWidth > this.editorHeight ? 0 : this.safeAreaBottomVp;
        this.safeLeft = 0;
        this.safeRight = 0;
        if (this.mode === PageMode.EDITOR) {
          this.clampAllComponentsToSafeBounds();
        }
        hilog.debug(DOMAIN, TAG, 'Safe area ignored by user setting');
        return;
      }

      const isLandscape = this.editorWidth > this.editorHeight;

      const capInset = (value: number, max: number, name: string): number => {
        if (value <= 0) return 0;
        if (value > max / 2) {
          hilog.warn(DOMAIN, TAG, 'Inset too large (%{public}s=%{public}d, max=%{public}d), capping', name, value, max);
          return Math.floor(max / 2);
        }
        return value;
      };

      const systemArea = this.windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutoutArea = this.windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      let navIndicatorArea: window.AvoidArea | null = null;
      try {
        navIndicatorArea = this.windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      } catch (_e) { /* ignore */ }

      const toPx = (raw: number): number => {
        if (raw > 0 && raw !== Math.floor(raw)) {
          return Math.round(raw * densityPixels);
        }
        return raw;
      };

      const boundedEdgeInset = (edgeInset: number, sizeInset: number, max: number): number => {
        const edgePx = toPx(edgeInset);
        const sizePx = toPx(sizeInset);
        if (edgePx <= 0) return sizePx;
        // getCutoutInfo/AvoidArea can report physical-display coordinates while the editor uses
        // the current window coordinate space. Only trust edge-derived insets when they are close
        // to the reported unsafe rect size or otherwise within a plausible screen-edge band.
        const plausibleEdgeMax = Math.max(sizePx * 2, Math.min(screenWidthPx, screenHeightPx) * 0.35);
        return edgePx <= Math.min(max / 2, plausibleEdgeMax) ? edgePx : sizePx;
      };

      const avoidTop = toPx(Math.max(systemArea.topRect.height, cutoutArea.topRect.height));
      const avoidBottom = toPx(Math.max(
        systemArea.bottomRect.height,
        navIndicatorArea ? navIndicatorArea.bottomRect.height : 0
      ));
      const avoidLeft = toPx(Math.max(
        boundedEdgeInset(systemArea.leftRect.left + systemArea.leftRect.width, systemArea.leftRect.width, screenWidthPx),
        boundedEdgeInset(cutoutArea.leftRect.left + cutoutArea.leftRect.width, cutoutArea.leftRect.width, screenWidthPx),
        navIndicatorArea ? boundedEdgeInset(
          navIndicatorArea.leftRect.left + navIndicatorArea.leftRect.width,
          navIndicatorArea.leftRect.width,
          screenWidthPx
        ) : 0
      ));
      const avoidRight = toPx(Math.max(
        boundedEdgeInset(screenWidthPx - systemArea.rightRect.left, systemArea.rightRect.width, screenWidthPx),
        boundedEdgeInset(screenWidthPx - cutoutArea.rightRect.left, cutoutArea.rightRect.width, screenWidthPx),
        navIndicatorArea ? boundedEdgeInset(
          screenWidthPx - navIndicatorArea.rightRect.left,
          navIndicatorArea.rightRect.width,
          screenWidthPx
        ) : 0
      ));

      if (isLandscape) {
        const symmetricOffset = capInset(Math.max(avoidLeft, avoidRight), screenWidthPx, 'symmetric_avoid');
        this.safeTop = 0;
        this.safeBottom = 0;
        this.safeLeft = symmetricOffset / densityPixels;
        this.safeRight = symmetricOffset / densityPixels;
      } else {
        this.safeTop = capInset(avoidTop, screenHeightPx, 'top_avoid') / densityPixels;
        this.safeBottom = Math.max(
          capInset(avoidBottom, screenHeightPx, 'bottom_avoid') / densityPixels,
          this.safeAreaBottomVp
        );
        this.safeLeft = 0;
        this.safeRight = 0;
      }
      if (this.mode === PageMode.EDITOR) {
        this.clampAllComponentsToSafeBounds();
      }

      // 检测多窗口模式: 使用官方 getWindowStatus() API (API 12+)
      // FLOATING(4)=自由悬浮窗口, SPLIT_SCREEN(5)=分屏 -> 无需适配安全区域
      const windowStatus = this.windowClass!.getWindowStatus();
      const isMultiWindow = (windowStatus === 4 || windowStatus === 5);
      if (isMultiWindow) {
        this.safeTop = 0;
        this.safeBottom = isLandscape ? 0 : this.safeAreaBottomVp;
        this.safeLeft = 0;
        this.safeRight = 0;
        if (this.mode === PageMode.EDITOR) {
          this.clampAllComponentsToSafeBounds();
        }
        return;
      }

      defaultDisplay.getCutoutInfo().then((cutoutInfo: display.CutoutInfo) => {
        let cutoutTop = 0;
        let cutoutBottom = 0;
        let cutoutLeft = 0;
        let cutoutRight = 0;
        if (cutoutInfo.boundingRects && cutoutInfo.boundingRects.length > 0) {
          for (const rect of cutoutInfo.boundingRects) {
            const centerX = rect.left + rect.width / 2;
            const centerY = rect.top + rect.height / 2;
            if (centerY <= screenHeightPx / 2) {
              cutoutTop = Math.max(cutoutTop, boundedEdgeInset(rect.top + rect.height, rect.height, screenHeightPx));
            } else {
              cutoutBottom = Math.max(cutoutBottom, boundedEdgeInset(screenHeightPx - rect.top, rect.height, screenHeightPx));
            }
            if (centerX <= screenWidthPx / 2) {
              cutoutLeft = Math.max(cutoutLeft, boundedEdgeInset(rect.left + rect.width, rect.width, screenWidthPx));
            } else {
              cutoutRight = Math.max(cutoutRight, boundedEdgeInset(screenWidthPx - rect.left, rect.width, screenWidthPx));
            }
          }
        }

        let waterfallTop = 0;
        let waterfallBottom = 0;
        let waterfallLeft = 0;
        let waterfallRight = 0;
        if (cutoutInfo.waterfallDisplayAreaRects) {
          const w = cutoutInfo.waterfallDisplayAreaRects;
          waterfallTop = boundedEdgeInset(w.top.top + w.top.height, w.top.height, screenHeightPx);
          waterfallBottom = w.bottom.height > 0 ? boundedEdgeInset(screenHeightPx - w.bottom.top, w.bottom.height, screenHeightPx) : 0;
          waterfallLeft = boundedEdgeInset(w.left.left + w.left.width, w.left.width, screenWidthPx);
          waterfallRight = w.right.width > 0 ? boundedEdgeInset(screenWidthPx - w.right.left, w.right.width, screenWidthPx) : 0;
        }

        const topOffsetPx = capInset(Math.max(avoidTop, cutoutTop, waterfallTop), screenHeightPx, 'top');
        const bottomOffsetPx = capInset(Math.max(avoidBottom, cutoutBottom, waterfallBottom), screenHeightPx, 'bottom');
        const leftOffsetPx = capInset(Math.max(avoidLeft, cutoutLeft, waterfallLeft), screenWidthPx, 'left');
        const rightOffsetPx = capInset(Math.max(avoidRight, cutoutRight, waterfallRight), screenWidthPx, 'right');

        if (isLandscape) {
          const symmetricOffset = capInset(Math.max(leftOffsetPx, rightOffsetPx), screenWidthPx, 'symmetric');
          this.safeTop = 0;
          this.safeBottom = 0;
          this.safeLeft = symmetricOffset / densityPixels;
          this.safeRight = symmetricOffset / densityPixels;
        } else {
          this.safeTop = topOffsetPx / densityPixels;
          this.safeBottom = Math.max(bottomOffsetPx / densityPixels, this.safeAreaBottomVp);
          this.safeLeft = 0;
          this.safeRight = 0;
        }

        if (this.mode === PageMode.EDITOR) {
          this.clampAllComponentsToSafeBounds();
        }
      }).catch((_err: Error) => {
        return;
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to get safe area: %{public}s', (err as Error).message);
    }
  }

  /**
   * 共用的面板锚定算法 — 参考点 Y 在画布下半部分时面板锚顶部，否则锚底部。
   * 缩放面板用 "选中组件中心 Y"，底部控制栏用"所有非屏幕组件中心 Y 的中位数"。
   */
  private alignmentForReferenceY(referenceY: number): Alignment {
    return referenceY > this.editorHeight / 2 ? Alignment.Top : Alignment.Bottom;
  }

  /** 缩放/删除面板锚定 — 避免遮挡当前选中组件 */
  private getScalingPanelAlignment(): Alignment {
    if (!this.selectedComponentId) return Alignment.Bottom;
    const comp = this.editorComponents.find(
      (c: PositionedLayoutComponent) => c.component === this.selectedComponentId
    );
    if (!comp) return Alignment.Bottom;
    return this.alignmentForReferenceY(comp.rect.y + comp.rect.height / 2);
  }

  /**
   * 底部控制栏 (添加组件 / 菜单) 锚定 — 与缩放面板同套算法，
   * 但参考点为画布上所有非屏幕组件中心 Y 的中位数。
   * 默认布局 (DPad/ABXY/SS 多在底部) 时中位数偏下 → 控制栏自动让到顶部，
   * 用户把组件挪到顶部后中位数偏上 → 控制栏自动回到底部。
   */
  private getBottomControlsAlignment(): Alignment {
    const ys: number[] = [];
    for (const c of this.editorComponents) {
      if (isScreenComponent(c.component)) continue;
      ys.push(c.rect.y + c.rect.height / 2);
    }
    if (ys.length === 0) return Alignment.Bottom;
    ys.sort((a: number, b: number) => a - b);
    const medianY = ys[Math.floor(ys.length / 2)];
    return this.alignmentForReferenceY(medianY);
  }

  private getSafeBounds(): SafeBounds {
    const left = this.safeLeft;
    const top = this.safeTop;
    const right = this.editorWidth - this.safeRight;
    const bottom = this.editorHeight - this.safeBottom;
    const bounds: SafeBounds = {
      left,
      top,
      right,
      bottom,
      width: Math.max(0, right - left),
      height: Math.max(0, bottom - top),
    };
    return bounds;
  }

  private buildDefaultPortraitComponentsForCurrentSafeArea(): PositionedLayoutComponent[] {
    const b = this.getSafeBounds();
    // 对齐 native CalculateScreenLayout: availableH = viewportHeight - screenTopOffset - screenGap
    // 屏幕高度计算不应减去 safeBottom，否则编辑器中的 3DS 屏幕会比游戏内更矮
    // 按钮超出安全区域的部分由 clampAllComponentsToSafeBounds 处理
    const layoutHeight = this.editorHeight - this.safeTop;
    const base = this.layoutManager.buildDefaultPortraitLayout(b.width, layoutHeight, this.overlayTheme);
    const mapped = base.map((c: PositionedLayoutComponent): PositionedLayoutComponent => {
      return {
        rect: {
          x: Math.round(c.rect.x + b.left),
          y: Math.round(c.rect.y + b.top),
          width: c.rect.width,
          height: c.rect.height,
        },
        component: c.component
      };
    });

    return mapped;
  }

  private buildDefaultLandscapeComponentsForCurrentSafeArea(): PositionedLayoutComponent[] {
    const b = this.getSafeBounds();
    const base = this.layoutManager.buildDefaultLandscapeLayout(b.width, b.height, this.overlayTheme);
    return base.map((c: PositionedLayoutComponent): PositionedLayoutComponent => {
      return {
        rect: {
          x: Math.round(c.rect.x + b.left),
          y: Math.round(c.rect.y + b.top),
          width: c.rect.width,
          height: c.rect.height,
        },
        component: c.component
      };
    });
  }

  private clampAllComponentsToSafeBounds(): void {
    const b = this.getSafeBounds();
    const updated: PositionedLayoutComponent[] = [];
    let changed = false;
    const selectComponent = this.editorComponents.find(
      (item: PositionedLayoutComponent) => item.component === LayoutComponent.BUTTON_SELECT);
    const startComponent = this.editorComponents.find(
      (item: PositionedLayoutComponent) => item.component === LayoutComponent.BUTTON_START);
    let stackedButtonShiftY: number | null = null;
    if (selectComponent && startComponent && Math.abs(selectComponent.rect.x - startComponent.rect.x) < 1) {
      const selectBottom = selectComponent.rect.y + selectComponent.rect.height;
      const startBottom = startComponent.rect.y + startComponent.rect.height;
      const pairTop = Math.min(selectComponent.rect.y, startComponent.rect.y);
      const pairBottom = Math.max(selectBottom, startBottom);
      const verticallyStacked = selectBottom <= startComponent.rect.y || startBottom <= selectComponent.rect.y;
      if (verticallyStacked) {
        const pairHeight = pairBottom - pairTop;
        const clampedTop = Math.max(b.top, Math.min(pairTop, b.bottom - pairHeight));
        stackedButtonShiftY = clampedTop - pairTop;
      }
    }
    for (const item of this.editorComponents) {
      const maxX = b.right - item.rect.width;
      const maxY = b.bottom - item.rect.height;
      const nextX = Math.round(Math.max(b.left, Math.min(item.rect.x, maxX)));
      const isStackedSelectStart = stackedButtonShiftY !== null &&
        (item.component === LayoutComponent.BUTTON_SELECT || item.component === LayoutComponent.BUTTON_START);
      const nextY = isStackedSelectStart
        ? Math.round(item.rect.y + stackedButtonShiftY!)
        : Math.round(Math.max(b.top, Math.min(item.rect.y, maxY)));
      if (nextX !== item.rect.x || nextY !== item.rect.y) {
        changed = true;
        updated.push({
          rect: { x: nextX, y: nextY, width: item.rect.width, height: item.rect.height },
          component: item.component
        });
      } else {
        updated.push(item);
      }
    }
    if (changed) {
      this.editorComponents = updated;
      this.refreshKey++;
    }
  }

  @Builder
  private buildLoadingDialog(): void {
    AzaharLoadingDialog({
      text: I18n.t('loading')
    })
  }

  private async initAndLoad(): Promise<void> {
    try {
      if (!this.layoutManager.isInitialized()) {
        await this.layoutManager.init(this.context);
      }
      this.reloadLayouts();
      this.loadBackgroundList();
      this.isLoading = false;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Init failed: %{public}s', (err as Error).message);
      this.isLoading = false;
    }
  }

  private reloadLayouts(): void {
    this.layouts = this.layoutManager.getLayouts().slice();
    if (this.isSelectMode) {
      // 选择器模式: 高亮当前 ROM 配置的 layoutId
      // null 表示"使用全局布局"，用空字符串标识
      this.selectedLayoutId = this.selectModeCurrentId ?? '';
    } else {
      this.selectedLayoutId = this.layoutManager.getDefaultLayoutId();
    }
    this.refreshKey++;
  }

  // ============================================================================
  // 列表操作 (对齐 Android LayoutsScreen)
  // ============================================================================

  private async onSetSelected(id: string): Promise<void> {
    if (this.isSelectMode) {
      // 选择器模式: 将选中的 layoutId 存入 AppStorage 并返回
      // 空字符串表示"使用全局布局" (对齐 Android: layoutId=null)
      // 非空字符串表示使用指定布局 (包括 BUILTIN_DEFAULT_ID)
      AppStorage.setOrCreate('layoutPickerResult', id);
      router.back();
      return;
    }
    await this.layoutManager.setDefaultLayoutId(id);
    this.reloadLayouts();
  }

  private async onDeleteLayout(): Promise<void> {
    if (!this.dialogTargetLayout) return;
    await this.layoutManager.deleteLayout(this.dialogTargetLayout.id);
    this.reloadLayouts();
    this.dialogTargetLayout = null;
    SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
  }

  // ============================================================================
  // 编辑器操作 (对齐 Android LayoutEditorActivity / LayoutEditorViewModel)
  // ============================================================================

  /** 打开编辑器 - 新建布局 (对齐 Android: + 按钮直接打开编辑器，无名称对话框) */
  private async openEditorForNew(): Promise<void> {
    await this.ensureWindowReady();
    this.updateSafeAreaOffsets();
    const layout = await this.layoutManager.createLayout('', this.editorWidth, this.editorHeight);
    // 新建布局: layoutVariants 为空，编辑器通过 getOptimalLayoutForVariant 获取默认布局
    this.editingLayout = JSON.parse(JSON.stringify(layout)) as LayoutConfiguration;
    this.initialLayout = JSON.parse(JSON.stringify(layout)) as LayoutConfiguration;
    this.currentVariant = this.resolveEditorVariant();
    this.lastEditorOrientation = this.editorWidth > this.editorHeight ? 'LANDSCAPE' : 'PORTRAIT';
    this.loadEditorComponents();
    this.selectedComponentId = '';
    this.showScalingControls = false;
    this.showBottomControls = true;
    this.updateSafeAreaOffsets();
    this.mode = PageMode.EDITOR;
  }

  /** 删除布局确认弹窗 - 菜单项在 LayoutListSection 内构建，确认后走 onDeleteLayout */
  private async confirmDeleteLayout(layout: LayoutConfiguration): Promise<void> {
    this.dialogTargetLayout = layout;
    const result = await promptAction.showDialog({
      title: I18n.t('delete_layout'),
      message: I18n.tf1('layout_delete_confirm_fmt', 'name', layout.name),
      buttons: [
        { text: I18n.t('cancel'), color: this.themeManager.getControlAccent() },
        { text: I18n.t('delete'), color: TEXT_DANGER }
      ]
    });
    if (result.index === 1) {
      SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
      this.onDeleteLayout();
    } else {
      SoundEffectManager.getInstance().play(SoundEffect.BACK);
    }
  }

  /** 打开编辑器 - 编辑已有布局 */
  private async openEditorForEdit(layout: LayoutConfiguration): Promise<void> {
    await this.ensureWindowReady();
    this.updateSafeAreaOffsets();
    this.editingLayout = JSON.parse(JSON.stringify(layout)) as LayoutConfiguration;
    this.initialLayout = JSON.parse(JSON.stringify(layout)) as LayoutConfiguration;
    this.currentVariant = this.resolveEditorVariant();
    this.lastEditorOrientation = this.editorWidth > this.editorHeight ? 'LANDSCAPE' : 'PORTRAIT';
    this.loadEditorComponents();
    this.selectedComponentId = '';
    this.showScalingControls = false;
    this.showBottomControls = true;
    this.updateSafeAreaOffsets();
    this.mode = PageMode.EDITOR;
  }

  /**
   * 解析当前编辑器应使用的变体: 优先沿用容差内的已存变体，
   * 避免尺寸微小变化时创建近似重复变体
   */
  private resolveEditorVariant(): UILayoutVariant {
    if (this.editingLayout) {
      const tolerant = this.layoutManager.findToleranceVariant(this.editingLayout, this.editorWidth, this.editorHeight);
      if (tolerant) return tolerant;
    }
    return LayoutConfigManager.buildVariant(this.editorWidth, this.editorHeight);
  }

  private loadEditorComponents(): void {
    if (!this.editingLayout || !this.currentVariant) return;
    const key = variantToKey(this.currentVariant);
    const hasSavedVariant = !!this.editingLayout.layoutVariants[key];

    let components: PositionedLayoutComponent[];
    // 已存矩形配置时所用的主题 — 用于按"相对设计尺寸"换算 L/R、SELECT/START
    // 旧数据无 theme 字段 → 按当前主题处理 (仅按素材重算宽高比，保持视觉大小)
    let srcTheme: string = this.overlayTheme;
    if (hasSavedVariant) {
      // 有保存的变体，直接使用
      const saved = this.editingLayout.layoutVariants[key];
      components = saved.components;
      srcTheme = saved.theme ?? this.overlayTheme;
    } else {
      // 无保存的变体，检查是否有同方向的其他尺寸变体可回退
      const similar = this.layoutManager.getOptimalLayoutForVariant(this.editingLayout, this.currentVariant, false, this.overlayTheme);
      // 判断是否命中了已保存的变体 (非默认生成)
      const hasAnySavedForOrientation = this.layoutManager.hasUsableVariant(this.editingLayout, this.currentVariant);
      if (hasAnySavedForOrientation) {
        // 有同方向的已保存变体，使用回退结果 (getOptimalLayoutForVariant 内部已按来源主题归一化)
        components = similar;
      } else {
        // 完全没有该方向的变体，使用安全区域感知的默认布局 (已按当前主题生成)
        if (this.currentVariant.orientation === Orientation.LANDSCAPE) {
          components = this.buildDefaultLandscapeComponentsForCurrentSafeArea();
        } else {
          components = this.buildDefaultPortraitComponentsForCurrentSafeArea();
        }
      }
    }

    this.editorComponents = components.map(
      (c: PositionedLayoutComponent): PositionedLayoutComponent => {
        const nr = normalizeRectToTheme(c.component, c.rect, srcTheme, this.overlayTheme);
        const rect = nr ?? { x: c.rect.x, y: c.rect.y, width: c.rect.width, height: c.rect.height };
        return {
          rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
          component: c.component
        };
      }
    );
    this.clampAllComponentsToSafeBounds();
    this.refreshKey++;
  }

  /** 保存当前编辑器组件到布局配置 (对齐 Android saveLayoutToCurrentConfiguration) */
  private storeLayoutChanges(): void {
    if (!this.editingLayout || !this.currentVariant) return;
    const key = variantToKey(this.currentVariant);
    const components = this.editorComponents.map(
      (c: PositionedLayoutComponent): PositionedLayoutComponent => {
        return {
          rect: { x: c.rect.x, y: c.rect.y, width: c.rect.width, height: c.rect.height },
          component: c.component
        };
      }
    );
    this.editingLayout.layoutVariants[key] = { components: components, theme: this.overlayTheme };
  }

  /** 保存并退出 (对齐 Android MenuOption.SAVE_AND_EXIT) */
  private async saveAndExit(): Promise<void> {
    this.storeLayoutChanges();
    if (this.editingLayout) {
      // 如果没有名称，使用默认名称
      if (!this.editingLayout.name || this.editingLayout.name.trim().length === 0) {
        this.editingLayout.name = I18n.t('custom_layout');
      }
      this.editingLayout.updatedAt = Date.now();
      await this.layoutManager.updateLayout(this.editingLayout);
    }
    this.reloadLayouts();
    this.mode = PageMode.LIST;
  }

  /** 退出不保存 (对齐 Android MenuOption.EXIT_WITHOUT_SAVING) */
  private async exitWithoutSaving(): Promise<void> {
    // 如果是新建的布局且没有保存过，删除它
    if (this.editingLayout && this.initialLayout) {
      if (!this.initialLayout.name || this.initialLayout.name.trim().length === 0) {
        // 新建的布局，删除
        await this.layoutManager.deleteLayout(this.editingLayout.id);
      } else {
        // 已有布局，恢复初始状态
        await this.layoutManager.updateLayout(this.initialLayout);
      }
    }
    this.reloadLayouts();
    this.mode = PageMode.LIST;
  }

  /** 撤销更改 (对齐 Android MenuOption.REVERT) */
  private revertChanges(): void {
    if (this.initialLayout) {
      this.editingLayout = JSON.parse(JSON.stringify(this.initialLayout)) as LayoutConfiguration;
      this.loadEditorComponents();
      this.selectedComponentId = '';
      this.showScalingControls = false;
      this.showBottomControls = true;
    }
  }

  /** 重置默认 (对齐 Android MenuOption.RESET → LayoutEditorViewModel.resetLayout) */
  private async resetToDefault(): Promise<void> {
    if (!this.editingLayout) return;
    this.editingLayout.orientation = LayoutOrientation.FOLLOW_SYSTEM;
    this.editingLayout.useCustomOpacity = false;
    this.editingLayout.opacity = 50;
    this.editingLayout.secondaryScreenOpacity = 100;
    // 对齐 Android: resetLayout() 清空 layoutVariants，让 getOptimalLayoutForVariant 回退到默认布局
    this.editingLayout.layoutVariants = {};
    this.loadEditorComponents();
    this.selectedComponentId = '';
    this.showScalingControls = false;
    this.showBottomControls = true;
  }

  // ============================================================================
  // 组件操作 (对齐 Android LayoutEditorView)
  // ============================================================================

  /** 添加组件 (对齐 Android addLayoutComponent) */
  private addComponent(component: LayoutComponent): void {
    const compRect = this.getDefaultComponentRect(component);
    const b = this.getSafeBounds();
    const newComp: PositionedLayoutComponent = {
      rect: { x: Math.round(b.left), y: Math.round(b.top), width: compRect.width, height: compRect.height },
      component: component,
    };
    this.editorComponents = this.editorComponents.concat([newComp]);
    this.refreshKey++;
  }

  private getComponentAspectRatio(component: LayoutComponent): number {
    if (isScreenComponent(component)) {
      return component === LayoutComponent.TOP_SCREEN ? (400 / 240) : (320 / 240); // 上屏 5:3，下屏 4:3
    }
    if (component === LayoutComponent.DPAD || component === LayoutComponent.BUTTONS) return 1.0;
    return 1.0; // 默认正方形
  }

  /**
   * 获取组件默认矩形 (对齐 LayoutConfigManager 默认布局，L/R 与 SELECT/START 按主题素材宽高比拉伸)
   */
  private getDefaultComponentRect(component: LayoutComponent): ButtonRect {
    const controlSizes = getOverlayControlSizes(this.overlayTheme);
    if (isScreenComponent(component)) {
      const w = DEFAULT_COMPONENT_WIDTH;
      const aspect = component === LayoutComponent.TOP_SCREEN ? (400 / 240) : (320 / 240);
      const h = Math.round(w / aspect);
      return { width: w, height: h };
    }
    if (component === LayoutComponent.DPAD || component === LayoutComponent.BUTTONS) {
      const s = component === LayoutComponent.DPAD ? controlSizes.dpad : controlSizes.abxy;
      return { width: Math.round(s), height: Math.round(s) };
    }
    if (component === LayoutComponent.STICK) {
      const s = Math.round(controlSizes.stick);
      return { width: s, height: s };
    }
    if (component === LayoutComponent.CSTICK) {
      const s = Math.round(controlSizes.cStick);
      return { width: s, height: s };
    }
    if (component === LayoutComponent.BUTTON_HOME) {
      const s = Math.round(controlSizes.action);
      return { width: s, height: s };
    }
    if (component === LayoutComponent.BUTTON_PAUSE || component === LayoutComponent.BUTTON_MORE) {
      const s = Math.round(controlSizes.action);
      return { width: s, height: s };
    }
    if (component === LayoutComponent.BUTTON_FAST_FORWARD_TOGGLE) {
      const s = Math.round(controlSizes.action);
      return { width: s, height: s };
    }
    if (component === LayoutComponent.BUTTON_L || component === LayoutComponent.BUTTON_R ||
      component === LayoutComponent.BUTTON_ZL || component === LayoutComponent.BUTTON_ZR) {
      const r = designedButtonRect(this.overlayTheme, 'lr');
      return { width: Math.round(r.width), height: Math.round(r.height) };
    }
    if (component === LayoutComponent.BUTTON_SELECT || component === LayoutComponent.BUTTON_START) {
      return { width: Math.round(controlSizes.ssWidth), height: Math.round(controlSizes.ssHeight) };
    }
    return { width: 40, height: 40 }; // 其它 small 按钮 (HINGE, 麦克风, 快进等) 保持正方形
  }

  /** @deprecated 保留向后兼容；新增组件请改用 getDefaultComponentRect */
  private getDefaultComponentSize(component: LayoutComponent): number {
    return this.getDefaultComponentRect(component).width;
  }

  /** 判断当前选中组件是否不可删除 (更多按钮 + 屏幕组件) */
  private isComponentUndeletable(): boolean {
    if (!this.selectedComponentId) return false;
    return this.selectedComponentId === LayoutComponent.BUTTON_MORE ||
      isScreenComponent(this.selectedComponentId as LayoutComponent);
  }

  /** 删除选中组件 (对齐 Android deleteSelectedView) */
  private deleteSelectedComponent(): void {
    if (!this.selectedComponentId) return;
    // 更多按钮和屏幕组件不可删除
    if (this.selectedComponentId === LayoutComponent.BUTTON_MORE) return;
    if (isScreenComponent(this.selectedComponentId as LayoutComponent)) return;
    this.editorComponents = this.editorComponents.filter(
      (c: PositionedLayoutComponent) => c.component !== this.selectedComponentId
    );
    this.selectedComponentId = '';
    this.showScalingControls = false;
    this.showBottomControls = true;
    this.refreshKey++;
  }

  /**
   * 选中组件 (严格对齐 Android LayoutEditorView.selectView)
   *
   * Android 逻辑:
   *   1. 计算组件到四个角的距离，选择最近的角作为缩放锚点
   *   2. 计算 widthScale / heightScale
   *   3. 调用 onViewSelectedListener(view, widthScale, heightScale, width, height, minComponentSize)
   *   4. ManagerView.showScalingControls 设置 seekBar.max = maxWidth/maxHeight
   */
  private selectComponent(index: number): void {
    if (index < 0 || index >= this.editorComponents.length) return;
    const comp = this.editorComponents[index];
    this.selectedComponentId = comp.component;
    this.selectedViewIsScreen = isScreenComponent(comp.component);

    const b = this.getSafeBounds();
    const canvasW = b.width;
    const canvasH = b.height;

    // === 计算缩放锚点 (对齐 Android selectView 的 anchorDistances) ===
    const x = comp.rect.x;
    const y = comp.rect.y;
    const w = comp.rect.width;
    const h = comp.rect.height;

    // 计算组件原始宽高比
    this.selectedComponentRatio = w / h;

    const distTopLeft = (x - b.left) * (x - b.left) + (y - b.top) * (y - b.top);
    const distTopRight = (b.right - (x + w)) * (b.right - (x + w)) + (y - b.top) * (y - b.top);
    const distBottomLeft = (x - b.left) * (x - b.left) + (b.bottom - (y + h)) * (b.bottom - (y + h));
    const distBottomRight = (b.right - (x + w)) * (b.right - (x + w)) + (b.bottom - (y + h)) * (b.bottom - (y + h));

    let minDist = distTopLeft;
    this.selectedViewAnchor = 0; // TOP_LEFT
    if (distTopRight < minDist) { minDist = distTopRight; this.selectedViewAnchor = 1; } // TOP_RIGHT
    if (distBottomLeft < minDist) { minDist = distBottomLeft; this.selectedViewAnchor = 2; } // BOTTOM_LEFT
    if (distBottomRight < minDist) { this.selectedViewAnchor = 3; } // BOTTOM_RIGHT

    // === 计算缩放比例 (对齐 Android: widthScale = (view.getWidth() - minComponentSize) / (width - minComponentSize)) ===
    const widthScale = (w - MIN_COMPONENT_SIZE) / Math.max(1, canvasW - MIN_COMPONENT_SIZE);
    const heightScale = (h - MIN_COMPONENT_SIZE) / Math.max(1, canvasH - MIN_COMPONENT_SIZE);

    // === 对齐 Android ManagerView.showScalingControls 参数 ===
    this.scalingMaxWidth = canvasW;
    this.scalingMaxHeight = canvasH;
    this.selectedViewMinSize = MIN_COMPONENT_SIZE;
    this.currentWidthScale = widthScale;
    this.currentHeightScale = heightScale;

    // 不再设置 selectedAspectRatio, selectedAlpha, selectedOnTop，因为 UI 已简化

    this.showScalingControls = true;
    this.showBottomControls = false;
  }

  /** 取消选中 (对齐 Android deselectCurrentView) */
  private deselectComponent(): void {
    this.selectedComponentId = '';
    this.showScalingControls = false;
    this.showBottomControls = true;
  }

  /** 水平居中 (对齐 Android centerSelectedViewHorizontally) */
  private centerHorizontally(): void {
    const idx = this.editorComponents.findIndex((c: PositionedLayoutComponent) => c.component === this.selectedComponentId);
    if (idx < 0) return;
    const comp = this.editorComponents[idx];
    const b = this.getSafeBounds();
    const centerX = Math.round(b.left + (b.width - comp.rect.width) / 2);
    this.updateComponentPosition(idx, centerX, comp.rect.y);
  }

  /** 垂直居中 (对齐 Android centerSelectedViewVertically) */
  private centerVertically(): void {
    const idx = this.editorComponents.findIndex((c: PositionedLayoutComponent) => c.component === this.selectedComponentId);
    if (idx < 0) return;
    const comp = this.editorComponents[idx];
    const b = this.getSafeBounds();
    const centerY = Math.round(b.top + (b.height - comp.rect.height) / 2);
    this.updateComponentPosition(idx, comp.rect.x, centerY);
  }

  /** 更新组件位置 */
  private updateComponentPosition(index: number, newX: number, newY: number): void {
    const updated: PositionedLayoutComponent[] = [];
    for (let i = 0; i < this.editorComponents.length; i++) {
      if (i === index) {
        const comp = this.editorComponents[i];
        updated.push({
          rect: { x: Math.round(newX), y: Math.round(newY), width: comp.rect.width, height: comp.rect.height },
          component: comp.component
        });
      } else {
        updated.push(this.editorComponents[i]);
      }
    }
    this.editorComponents = updated;
    this.refreshKey++;
  }

  /**
   * 缩放选中组件 (严格对齐 Android LayoutEditorView.scaleSelectedView)
   *
   * Android 逻辑:
   *   根据 selectedViewAnchor 决定缩放时哪个角固定:
   *   - TOP_LEFT: 左上角固定，右下角移动
   *   - TOP_RIGHT: 右上角固定，左下角移动 (viewX = oldX + oldW - newW)
   *   - BOTTOM_LEFT: 左下角固定，右上角移动 (viewY = oldY + oldH - newH)
   *   - BOTTOM_RIGHT: 右下角固定，左上角移动 (viewX/Y 都调整)
   *   然后边界检查确保不超出画布
   */
  private scaleSelectedView(widthScale: number, heightScale: number): void {
    const idx = this.editorComponents.findIndex((c: PositionedLayoutComponent) => c.component === this.selectedComponentId);
    if (idx < 0) return;
    const comp = this.editorComponents[idx];

    const canvasW = this.scalingMaxWidth;
    const canvasH = this.scalingMaxHeight;
    const minSize = this.selectedViewMinSize;

    const newW = Math.round((canvasW - minSize) * widthScale + minSize);
    const newH = Math.round((canvasH - minSize) * heightScale + minSize);

    let viewX: number;
    let viewY: number;
    const b = this.getSafeBounds();

    if (this.selectedViewAnchor === 0) {
      // TOP_LEFT: 左上角固定
      viewX = comp.rect.x;
      viewY = comp.rect.y;
      if (viewX + newW > b.right) viewX = b.right - newW;
      if (viewY + newH > b.bottom) viewY = b.bottom - newH;
    } else if (this.selectedViewAnchor === 1) {
      // TOP_RIGHT: 右上角固定
      viewX = comp.rect.x + comp.rect.width - newW;
      viewY = comp.rect.y;
      if (viewX < b.left) viewX = b.left;
      if (viewY + newH > b.bottom) viewY = b.bottom - newH;
    } else if (this.selectedViewAnchor === 2) {
      // BOTTOM_LEFT: 左下角固定
      viewX = comp.rect.x;
      viewY = comp.rect.y + comp.rect.height - newH;
      if (viewX + newW > b.right) viewX = b.right - newW;
      if (viewY < b.top) viewY = b.top;
    } else {
      // BOTTOM_RIGHT: 右下角固定
      viewX = comp.rect.x + comp.rect.width - newW;
      viewY = comp.rect.y + comp.rect.height - newH;
      if (viewX < b.left) viewX = b.left;
      if (viewY < b.top) viewY = b.top;
    }

    const updated: PositionedLayoutComponent[] = [];
    for (let i = 0; i < this.editorComponents.length; i++) {
      if (i === idx) {
        updated.push({
          rect: { x: Math.round(viewX), y: Math.round(viewY), width: newW, height: newH },
          component: comp.component
        });
      } else {
        updated.push(this.editorComponents[i]);
      }
    }
    this.editorComponents = updated;
    this.refreshKey++;
  }

  /** 获取未添加的组件列表 (对齐 Android openButtonsMenu) */
  private getAvailableComponents(): LayoutComponent[] {
    const instantiated = new Set<string>();
    for (const comp of this.editorComponents) {
      instantiated.add(comp.component);
    }
    return ALL_LAYOUT_COMPONENTS.filter((c: LayoutComponent) => !instantiated.has(c));
  }

  /** 更新编辑器网格大小，并持久化到全局设置。 */
  private setGridSize(value: number): void {
    let normalized = Math.round(value / SnapGuideSystem.GRID_SIZE_STEP) * SnapGuideSystem.GRID_SIZE_STEP;
    normalized = Math.max(SnapGuideSystem.MIN_GRID_SIZE,
      Math.min(SnapGuideSystem.MAX_GRID_SIZE, normalized));
    this.gridSize = normalized;
    this.snapSystem.gridEnabled = normalized > 0;
    this.snapSystem.centerEnabled = normalized > 0;
    this.snapSystem.elementEnabled = normalized > 0;
    void SettingsManager.getInstance().setNumber(KEY_LAYOUT_EDITOR_GRID_SIZE, normalized);
  }

  private onGridSizeChanged(): void {
    this.snapSystem.gridSize = this.gridSize;
    this.snapSystem.gridEnabled = this.gridSize > 0;
    this.snapSystem.centerEnabled = this.gridSize > 0;
    this.snapSystem.elementEnabled = this.gridSize > 0;
    this.clampAllComponentsToSafeBounds();
    this.drawGridCanvas();
  }

  // ============================================================================
  // 构建 UI
  // ============================================================================

  private getComponentIcon(comp: LayoutComponent): Resource {
    if (isScreenComponent(comp)) return $r('sys.symbol.rectangle_on_rectangle');
    if (comp === LayoutComponent.DPAD) return $r('sys.symbol.gamecontroller');
    if (comp === LayoutComponent.BUTTONS) return $r('sys.symbol.gamecontroller');
    if (comp === LayoutComponent.BUTTON_L || comp === LayoutComponent.BUTTON_R) return $r('sys.symbol.gamecontroller');
    if (comp === LayoutComponent.BUTTON_ZL || comp === LayoutComponent.BUTTON_ZR) return $r('sys.symbol.gamecontroller');
    if (comp === LayoutComponent.BUTTON_START || comp === LayoutComponent.BUTTON_SELECT) return $r('sys.symbol.play');
    if (comp === LayoutComponent.BUTTON_FAST_FORWARD_TOGGLE) return $r('sys.symbol.play');
    if (comp === LayoutComponent.BUTTON_SLOW_MOTION_TOGGLE) return $r('sys.symbol.play');
    if (comp === LayoutComponent.BUTTON_TOGGLE_SOFT_INPUT) return $r('sys.symbol.hand_tap');
    if (comp === LayoutComponent.BUTTON_RESET) return $r('sys.symbol.arrow_clockwise');
    if (comp === LayoutComponent.BUTTON_PAUSE) return $r('sys.symbol.pause');
    if (comp === LayoutComponent.BUTTON_SWAP_SCREENS) return $r('sys.symbol.arrow_up');
    if (comp === LayoutComponent.BUTTON_QUICK_SAVE) return $r('sys.symbol.arrow_down');
    if (comp === LayoutComponent.BUTTON_QUICK_LOAD) return $r('sys.symbol.arrow_up');
    if (comp === LayoutComponent.BUTTON_MORE) return $r('sys.symbol.dot_grid_2x2');
    if (comp === LayoutComponent.BUTTON_SETTINGS) return $r('sys.symbol.gearshape');
    if (comp === LayoutComponent.BUTTON_SCREEN_ROTATION) return $r('sys.symbol.arrow_clockwise');
    if (comp === LayoutComponent.STICK || comp === LayoutComponent.CSTICK) return $r('sys.symbol.gamecontroller');
    if (comp === LayoutComponent.BUTTON_HOME) return $r('sys.symbol.square_grid_2x2');
    return $r('sys.symbol.plus');
  }

  private getEditorBackgroundAlignment(): Alignment {
    const mode = this.editingLayout?.backgroundMode ?? BackgroundMode.FIT_CENTER;
    switch (mode) {
      case BackgroundMode.STRETCH: return Alignment.Center;
      case BackgroundMode.FIT_CENTER: return Alignment.Center;
      case BackgroundMode.FIT_TOP: return Alignment.Top;
      case BackgroundMode.FIT_LEFT: return Alignment.Start;
      case BackgroundMode.FIT_BOTTOM: return Alignment.Bottom;
      case BackgroundMode.FIT_RIGHT: return Alignment.End;
      default: return Alignment.Center;
    }
  }

  private isEditorLandscape(): boolean {
    return this.editorWidth >= 600;
  }

  private isLargeComponent(comp: LayoutComponent): boolean {
    return comp === LayoutComponent.TOP_SCREEN || comp === LayoutComponent.BOTTOM_SCREEN ||
      comp === LayoutComponent.DPAD || comp === LayoutComponent.BUTTONS;
  }

  private menuSaveAndExit(): void {
    if (this.editingLayout?.name && this.editingLayout.name.trim().length > 0) {
      this.saveAndExit();
    } else {
      this.showLayoutNameInputDialog();
    }
  }

  private openBackgroundDialog(): void {
    this.storeLayoutChanges();
    if (this.editingLayout) {
      this.dialogBackgroundUri = this.editingLayout.backgroundUri ?? '';
      this.dialogBackgroundMode = this.editingLayout.backgroundMode ?? BackgroundMode.FIT_CENTER;
    }
    this.showBackgroundDialog = true;
  }

  private openPropertiesDialog(): void {
    if (!this.editingLayout) return;
    this.storeLayoutChanges();
    this.dialogLayoutName = this.editingLayout.name || '';
    this.dialogUseCustomOpacity = this.editingLayout.useCustomOpacity;
    this.dialogOpacity = this.editingLayout.opacity;
    this.dialogSecondaryScreenOpacity = this.editingLayout.secondaryScreenOpacity ?? 100;
    this.showPropertiesDialog = true;
  }

  private showEditorMenuSheet(): void {
    this.storeLayoutChanges();
    this.showMenuSheet = true;
  }

  private showLayoutNameInputDialog(): void {
    this.nameInputText = I18n.t('custom_layout');
    this.showNameInputDialog = true;
  }

  @Builder
  DialogCloseButton(onClose: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize($r('sys.float.window_close_icon_width'))
        .fontColor([TEXT_SECONDARY])
    }
    .width($r('sys.float.sheet_close_icon_button_width'))
    .height($r('sys.float.sheet_close_icon_button_width'))
    .backgroundColor(BUTTON_BG_SECONDARY)
    .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      SoundEffectManager.getInstance().play(SoundEffect.BACK);
      onClose();
    })
  }

  @Builder
  AddComponentDialog() {
      Column() {
        // 标题栏: icon + 标题 + 关闭按钮
        Row() {          Text(I18n.t('select_component'))
            .fontSize($r("sys.float.ohos_id_text_size_headline8")).fontWeight(FontWeight.Bold).fontColor($r("sys.color.ohos_id_color_text_primary"))
            .layoutWeight(1)
          this.DialogCloseButton(() => { this.showAddComponentDialog = false; })
        }
        .width('100%')
                .margin({ bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })

        Grid() {
          ForEach(this.getAvailableComponents(), (comp: LayoutComponent) => {
            GridItem() {
              Column() {
                if (getComponentImageName(comp)) {
                  Image($rawfile(themedImagePath(getComponentImageName(comp), this.overlayTheme)))
                    .width(56)
                    .height(56)
                    .objectFit(ImageFit.Contain)
                } else {
                  SymbolGlyph(this.getComponentIcon(comp))
                    .fontSize(34)
                    .fontColor([$r('sys.color.ohos_id_color_text_primary')])
                }
                Text(getComponentDisplayName(comp))
                  .fontSize($r('sys.float.ohos_id_text_size_body2'))
                  .fontColor($r('sys.color.ohos_id_color_text_primary'))
                  .maxLines(1)
                  .margin({ top: $r('sys.float.ohos_id_elements_margin_vertical_m') })
              }
              .width('100%')
              .height(92)
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
              this.addComponent(comp);
              this.showAddComponentDialog = false;
            })
          }, (comp: LayoutComponent) => comp)
        }
        .columnsTemplate(this.isEditorLandscape() ? '1fr 1fr 1fr 1fr 1fr' : '1fr 1fr 1fr')
        .columnsGap($r('sys.float.ohos_id_elements_margin_horizontal_m'))
        .rowsGap($r('sys.float.ohos_id_elements_margin_vertical_m'))
        .scrollBar(BarState.Auto)
        .width('100%')
        // FIT_CONTENT 半模态内不能用百分比高度（父容器随内容定高会形成循环布局），用 editorHeight 折算
        .constraintSize({ maxHeight: this.isEditorLandscape() ? Math.round(this.editorHeight * 0.6) : 400 })

        if (this.getAvailableComponents().length === 0) {
          // 无可添加组件的空态与首页/详情页统一走 AzaharEmptySlot
          Column() {
            AzaharEmptySlot({ title: I18n.t('no_more_components') })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: $r('sys.float.ohos_id_elements_margin_vertical_l'), bottom: $r('sys.float.ohos_id_elements_margin_vertical_l') })
        }
      }
      .width('100%')
      .padding(SHEET_CONTENT_PADDING)
      .backgroundColor(SHEET_BG_GROUPED)
      .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  build() {
    Stack() {
      Column()
        .bindContentCover($$this.isLoading, this.buildLoadingDialog(), {
          modalTransition: ModalTransition.NONE
        })

      if (this.mode === PageMode.LIST) {
        FloatTilesBackground({
          themeColors: this.themeColors,
          isPlaying: this.isWaveAnimationPlaying
        })

        AzaharNavPage({
          title: I18n.t('layout_manager_title'),
          scrollers: [this.listScroller],
          onBack: () => {
            SoundEffectManager.getInstance().play(SoundEffect.BACK);
            router.back();
          },
          menuItems: [
            {
              icon: $r('sys.symbol.plus'),
              action: () => {
                SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
                this.openEditorForNew();
              }
            }
          ]
        }) {
          LayoutListSection({
            scroller: this.listScroller,
            isLoading: this.isLoading,
            isSelectMode: this.isSelectMode,
            layouts: this.layouts,
            refreshKey: this.refreshKey,
            selectedLayoutId: this.selectedLayoutId,
            overlayTheme: this.overlayTheme,
            onEdit: (layout: LayoutConfiguration) => {
              this.openEditorForEdit(layout);
            },
            onDelete: (layout: LayoutConfiguration) => {
              this.confirmDeleteLayout(layout);
            },
            onSetSelected: (id: string) => {
              this.onSetSelected(id);
            }
          })
        }
      } else {
        Column() {
          this.EditorModeUI()
        }
        .width('100%')
        .height('100%')
      }

      // 对话框层 — sheet 形式由根节点 bindSheet 挂载；全屏管理器/预览保留条件渲染

    }
    .width('100%')
    .height('100%')
  }

  // ============================================================================
  // 列表模式 UI (对齐 Android LayoutsScreen，壳走 AzaharNavPage 悬浮标题栏)
  // ============================================================================

  @Builder
  EditorModeUI() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 全屏黑色背景 (对齐 Android RelativeLayout android:background="@android:color/black")
      Column()
        .width('100%').height('100%')
        .backgroundColor(Color.Black)

      // 布局背景图片层 (对齐 Android LayoutEditorView 中的背景渲染)
      // 仅填充实际可用的渲染区域 (安全区域内)，不延伸到状态栏/导航栏区域
      if (this.editingLayout?.backgroundUri === THEME_COLOR_BG_URI) {
        // 系统主题色背景: 渐变 + 颗粒感纹理 (参考 iPod 项目 DeviceFrame + noise texture)
        // 填充整个可渲染区域，参考主页 WaveBackground 的全屏显示
        // iPod 项目: noise.webp 是白色像素+随机alpha(0~20%)的纹理图，
        // 外层 noiseOpacity 范围 0.3~1.0，这里使用 0.6 获得适中的颗粒感
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: [
                [this.hexToNumber(this.themeColors.gradientStart), 0.0],
                [this.hexToNumber(this.themeColors.gradientEnd), 0.6],
                [this.hexToNumber(this.themeColors.accent), 1.0]
              ]
            })
          Image($rawfile('noise_texture.webp'))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .opacity(this.getNoiseOpacity())
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      } else if (isRawfileBgUri(this.editingLayout?.backgroundUri)) {
        // 内置皮肤背景 (rawfile 打包素材)
        Stack({ alignContent: this.getEditorBackgroundAlignment() }) {
          Image($rawfile(rawfileBgPath(this.editingLayout!.backgroundUri!)))
            .objectFit((this.editingLayout!.backgroundMode ?? BackgroundMode.FIT_CENTER) === BackgroundMode.STRETCH
              ? ImageFit.Fill : ImageFit.Contain)
            .objectRepeat(ImageRepeat.NoRepeat)
            .constraintSize({ maxWidth: '100%', maxHeight: '100%' })
        }
        .width(this.editorWidth - this.safeLeft - this.safeRight)
        .height(this.editorHeight - this.safeTop - this.safeBottom)
        .position({ x: this.safeLeft, y: this.safeTop })
        .hitTestBehavior(HitTestMode.None)
      } else if (this.editingLayout?.backgroundUri) {
        Stack({ alignContent: this.getEditorBackgroundAlignment() }) {
          Image(this.editingLayout.backgroundUri)
            .objectFit((this.editingLayout.backgroundMode ?? BackgroundMode.STRETCH) === BackgroundMode.STRETCH
              ? ImageFit.Fill : ImageFit.Contain)
            .objectRepeat(ImageRepeat.NoRepeat)
            .constraintSize({ maxWidth: '100%', maxHeight: '100%' })
        }
        .width(this.editorWidth - this.safeLeft - this.safeRight)
        .height(this.editorHeight - this.safeTop - this.safeBottom)
        .position({ x: this.safeLeft, y: this.safeTop })
        .hitTestBehavior(HitTestMode.None)
      }

      // 编辑器画布 (对齐 Android LayoutEditorView)
      Column() {
        Stack() {
          // 网格背景点
            this.GridDotsOverlay()

          ForEach(this.editorComponents, (comp: PositionedLayoutComponent) => {
            this.EditorComponentItem(comp)
          }, (comp: PositionedLayoutComponent) =>
            `editor_${comp.component}_${comp.rect.x}_${comp.rect.y}_${comp.rect.width}_${comp.rect.height}`)

          // 吸附辅助线 (拖拽时显示)
          ForEach(this.snapGuideLines, (line: SnapGuideLine, idx: number) => {
            if (line.direction === 'vertical') {
              Column()
                .width(1)
                .height('100%')
                .backgroundColor(line.type === 'center' ? $r('app.color.guide_center') :
                  line.type === 'element' ? $r('app.color.guide_element') : this.getGridGuideColor())
                .position({ x: line.position, y: 0 })
                .hitTestBehavior(HitTestMode.None)
            } else {
              Column()
                .width('100%')
                .height(1)
                .backgroundColor(line.type === 'center' ? $r('app.color.guide_center') :
                  line.type === 'element' ? $r('app.color.guide_element') : this.getGridGuideColor())
                .position({ x: 0, y: line.position })
                .hitTestBehavior(HitTestMode.None)
            }
          }, (line: SnapGuideLine, idx: number) => `guide_${line.direction}_${line.position}_${line.type}_${idx}`)
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      // 空白区域点击 (对齐 Android LayoutEditorView init setOnClickListener)
      // 使用 onTouch 代替 onClick，避免与子组件 onTouch 冲突
      .onTouch((event: TouchEvent) => {
        this.handleCanvasTouch(event);
      })

      // 缩放控制面板 — 根据所选组件位置动态吸顶 / 吸底，避免遮挡选中项
      // (对齐 Android layout_scaling_container 默认底部行为，但选中底部组件时改为顶部)
      if (this.showScalingControls) {
        Stack({ alignContent: this.getScalingPanelAlignment() }) {
          Scroll() {
            this.ScalingControlsPanel()
          }
          .width('100%')
          .scrollBar(BarState.Auto)
          .constraintSize({ maxHeight: '50%' })
          .padding({ left: this.safeLeft, right: this.safeRight, bottom: $r('sys.float.ohos_id_text_paragraph_margin_xs') })
        }
        .width('100%').height('100%')
        // 外层 Stack 仅用于定位面板，其余区域要透传触摸到画布
        .hitTestBehavior(HitTestMode.None)
        .zIndex(2)
      }

      // 底部控制栏 — 游戏化风格: 半透明深色背景, CupertinoIcons, 无圆角按钮
      // 与缩放面板同套吸顶/吸底算法，避免遮挡画布主活动区域
      if (this.showBottomControls && !this.showScalingControls) {
        Stack({ alignContent: this.getBottomControlsAlignment() }) {
        Row() {
          // 添加组件按钮
          Button({ type: ButtonType.Capsule }) {
            Row() {
              SymbolGlyph($r("sys.symbol.plus"))
                .fontSize(24)
                .fontColor([$r('app.color.text_on_accent')])
                .margin({ right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
              Text(I18n.t('add_component'))
                .fontSize($r('sys.float.ohos_id_text_size_body2'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_on_accent'))
            }
          }
          .height(SHEET_BUTTON_HEIGHT)
          .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l'), right: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
          .backgroundColor(this.getThemedButtonBg())
          .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
          .onFocus(() => { SoundEffectManager.getInstance().play(SoundEffect.FOCUS); })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Up) {
              SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
              this.showBottomControls = false;
              this.showAddComponentDialog = true;
            }
          })

          Blank()

          // 网格大小按钮
          Button({ type: ButtonType.Capsule }) {
            Row() {
              SymbolGlyph($r("sys.symbol.square_grid_2x2"))
                .fontSize(22)
                .fontColor([$r('app.color.text_on_accent')])
                .margin({ right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
              Text(I18n.t('layout_editor_grid_size'))
                .fontSize($r('sys.float.ohos_id_text_size_body2'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_on_accent'))
            }
          }
          .height(SHEET_BUTTON_HEIGHT)
          .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_m'), right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
          .backgroundColor(this.getThemedButtonBg())
          .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
          .onFocus(() => { SoundEffectManager.getInstance().play(SoundEffect.FOCUS); })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Up) {
              SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
              this.showBottomControls = false;
              this.showGridSizeDialog = true;
            }
          })

          Blank()

          // 菜单按钮
          Button({ type: ButtonType.Capsule }) {
            Row() {
              SymbolGlyph($r("sys.symbol.dot_grid_2x2"))
                .fontSize(24)
                .fontColor([$r('app.color.text_on_accent')])
                .margin({ right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
              Text(I18n.t('menu'))
                .fontSize($r('sys.float.ohos_id_text_size_body2'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_on_accent'))
            }
          }
          .height(SHEET_BUTTON_HEIGHT)
          .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l'), right: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
          .backgroundColor(this.getThemedButtonBg())
          .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
          .onFocus(() => { SoundEffectManager.getInstance().play(SoundEffect.FOCUS); })
          .onClick(() => {
            SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
            this.showEditorMenuSheet();
          })
        }
        .width('100%')
        .padding({
          left: 8 + this.safeLeft,
          right: 8 + this.safeRight,
          top: 6 + (this.getBottomControlsAlignment() === Alignment.Top ? this.safeTop : 0),
          bottom: 6
        })
        .backgroundColor(this.getThemedBarBg())
        .alignItems(VerticalAlign.Center)
        // 背景区域不参与触摸命中，避免遮挡底部位置的 SELECT/START 等组件。
        // 两个子 Button 各自的 .onTouch 仍然按 HitTestMode.Default 正常生效。
        .hitTestBehavior(HitTestMode.None)
        }
        .width('100%').height('100%')
        // 外层 Stack 仅用于定位 Row，其余区域要透传触摸到画布
        .hitTestBehavior(HitTestMode.None)
        .zIndex(2)
      }
      // 一个组件只能挂一个 bindSheet — 每个面板挂到独立的零尺寸宿主上
      Stack() {
      Column()
        .bindSheet($$this.showAddComponentDialog, this.AddComponentDialog(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK),
          onDisappear: () => {
            this.showAddComponentDialog = false;
          }
        })
      }
      .width(0).height(0)
      .hitTestBehavior(HitTestMode.None)

      // 编辑器弹窗组 (网格大小/属性/布局命名/菜单) — bindSheet 宿主在组件内部
      LayoutEditorSheets({
        dialogBackgroundMode: this.$dialogBackgroundMode,
        dialogBackgroundUri: this.$dialogBackgroundUri,
        dialogLayoutName: this.$dialogLayoutName,
        dialogOpacity: this.$dialogOpacity,
        dialogSecondaryScreenOpacity: this.$dialogSecondaryScreenOpacity,
        dialogUseCustomOpacity: this.$dialogUseCustomOpacity,
        nameInputText: this.$nameInputText,
        showBackgroundDialog: this.$showBackgroundDialog,
        showBottomControls: this.$showBottomControls,
        showGridSizeDialog: this.$showGridSizeDialog,
        showMenuSheet: this.$showMenuSheet,
        showNameInputDialog: this.$showNameInputDialog,
        showPropertiesDialog: this.$showPropertiesDialog,
        editingLayout: this.$editingLayout,
        editorWidth: this.editorWidth,
        gridSize: this.gridSize,
        setGridSize: (size: number) => { this.setGridSize(size); },
        exitWithoutSaving: () => { this.exitWithoutSaving(); },
        menuSaveAndExit: () => { this.menuSaveAndExit(); },
        openBackgroundDialog: () => { this.openBackgroundDialog(); },
        openPropertiesDialog: () => { this.openPropertiesDialog(); },
        resetToDefault: () => { this.resetToDefault(); },
        revertChanges: () => { this.revertChanges(); },
        storeLayoutChanges: () => { this.storeLayoutChanges(); },
        saveAndExit: () => { this.saveAndExit(); }
      })

      // 背景弹窗组 (背景选择/管理/预览/命名) — bindSheet 宿主在组件内部
      LayoutBackgroundDialogs({
        backgroundList: this.$backgroundList,
        backgroundNameInputText: this.$backgroundNameInputText,
        dialogBackgroundMode: this.$dialogBackgroundMode,
        dialogBackgroundUri: this.$dialogBackgroundUri,
        pendingBackgroundUri: this.$pendingBackgroundUri,
        previewBackground: this.$previewBackground,
        selectedBackgroundId: this.$selectedBackgroundId,
        showBackgroundDialog: this.$showBackgroundDialog,
        showBackgroundManager: this.$showBackgroundManager,
        showBackgroundNameInput: this.$showBackgroundNameInput,
        showBackgroundPreview: this.$showBackgroundPreview,
        refreshKey: this.$refreshKey,
        dialogScrollSourceId: this.dialogScrollSourceId,
        editingLayout: this.$editingLayout,
        isWaveAnimationPlaying: this.isWaveAnimationPlaying,
        safeAreaBottomVp: this.safeAreaBottomVp,
        safeAreaTopVp: this.safeAreaTopVp,
        themeColors: this.themeColors,
        deleteBackground: (bg: LayoutBackground) => { this.deleteBackground(bg); },
        getNoiseOpacity: () => this.getNoiseOpacity(),
        getSelectedBackgroundName: () => this.getSelectedBackgroundName(),
        getThemedItemBg: () => this.getThemedItemBg(),
        hexToNumber: (hex: string) => this.hexToNumber(hex),
        isEditorLandscape: () => this.isEditorLandscape(),
        loadBackgroundList: () => { this.loadBackgroundList(); },
        pickNewBackground: () => { this.pickNewBackground(); },
        saveBackgroundList: () => { this.saveBackgroundList(); }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .padding({ bottom: this.safeAreaBottomVp })
  }

  /**
   * 网格背景点 — 在交叉点绘制小圆点，提供视觉参考
   */
  @Builder
  GridDotsOverlay() {
    // 使用单个 Canvas 批量绘制，避免每个网格点创建一个 ArkUI 节点。
    Canvas(this.gridCanvasContext)
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .onReady(() => {
      this.drawGridCanvas();
    })
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.gridCanvasWidth = newValue.width as number;
      this.gridCanvasHeight = newValue.height as number;
      this.drawGridCanvas();
    })
  }

  private canvasColor(color: string): string {
    if (color.length !== 9 || !color.startsWith('#')) {
      return color;
    }
    const alpha = parseInt(color.slice(1, 3), 16) / 255;
    const red = parseInt(color.slice(3, 5), 16);
    const green = parseInt(color.slice(5, 7), 16);
    const blue = parseInt(color.slice(7, 9), 16);
    return `rgba(${red}, ${green}, ${blue}, ${alpha})`;
  }

  private drawGridCanvas(): void {
    if (this.gridCanvasWidth <= 0 || this.gridCanvasHeight <= 0) {
      return;
    }

    const ctx = this.gridCanvasContext;
    const width = this.gridCanvasWidth;
    const height = this.gridCanvasHeight;
    ctx.clearRect(0, 0, width, height);

    const bounds = this.getSafeBounds();
    ctx.fillStyle = this.canvasColor(this.getCenterCrossColor());
    ctx.fillRect((this.safeLeft + this.editorWidth - this.safeRight) / 2, 0, 1, height);
    ctx.fillRect(0, (this.safeTop + this.editorHeight - this.safeBottom) / 2, width, 1);

    const gridSize = this.gridSize;
    if (gridSize <= 0) {
      return;
    }

    const step = gridSize * 2;
    const startX = Math.ceil(bounds.left / step) * step;
    const startY = Math.ceil(bounds.top / step) * step;
    ctx.fillStyle = this.canvasColor(this.getGridDotColor());
    for (let x = startX; x <= bounds.right; x += step) {
      for (let y = startY; y <= bounds.bottom; y += step) {
        ctx.fillRect(x - 1, y - 1, 2, 2);
      }
    }
  }

  /**
   * 单个编辑器组件 (对齐 Android LayoutEditorView 的渲染和交互)
   *
   * Android 交互流程:
   *   ACTION_DOWN → 记录 downOffset, alpha=1, highlighted=true
   *   ACTION_MOVE → 距离>25 开始拖拽, dragView(offset)
   *   ACTION_UP   → 未拖拽: selectView(); 已拖拽: alpha=0.5, highlighted=false
   *
   * Android 视觉:
   *   屏幕: 上屏 solid #729F + stroke #28F 2dp; 下屏 solid #7F44 + stroke #F44 2dp
   *   按钮(未选中): dashed border #78AF 1dp
   *   按钮(选中/highlighted): dashed border #F8AF 2dp
   *   所有组件默认 alpha=0.5, 触摸时 alpha=1.0
   */
  @Builder
  EditorComponentItem(comp: PositionedLayoutComponent) {
    if (isScreenComponent(comp.component)) {
      // 屏幕组件 (对齐 Android background_top_screen.xml / background_bottom_screen.xml)
      Column()
        .width(comp.rect.width)
        .height(comp.rect.height)
        .backgroundColor(comp.component === LayoutComponent.TOP_SCREEN
          ? $r('app.color.screen_zone_top_tint') : $r('app.color.screen_zone_bottom_tint')) // 上屏: #729F → #772299FF; 下屏: #7F44 → #77FF4444
        .border({
          width: (this.touchedId === comp.component || this.selectedComponentId === comp.component) ? 2 : 2,
          color: comp.component === LayoutComponent.TOP_SCREEN ? $r('app.color.screen_zone_top') : $r('app.color.screen_zone_bottom'),
        })
        .position({ x: comp.rect.x, y: comp.rect.y })
        // 拖拽时通过 translate 实现视觉移动，不触发 ForEach 重建
        .translate({
          x: this.dragTargetId === comp.component ? this.dragOffsetX : 0,
          y: this.dragTargetId === comp.component ? this.dragOffsetY : 0,
        })
        .opacity(this.touchedId === comp.component ? 1.0 : 0.5)
        .onTouch((event: TouchEvent) => {
          this.handleComponentTouchById(comp.component, event);
        })
    } else if (comp.component === LayoutComponent.STICK || comp.component === LayoutComponent.CSTICK) {
      Stack() {
        Image($rawfile(themedImagePath(comp.component === LayoutComponent.STICK ? 'stick_main_range.png' : 'stick_c_range.png', this.overlayTheme)))
          .width('100%').height('100%')
          .objectFit(ImageFit.Fill)
        Image($rawfile(themedImagePath(comp.component === LayoutComponent.STICK ? 'stick_main.png' : 'stick_c.png', this.overlayTheme)))
          .width('100%').height('100%')
          .objectFit(ImageFit.Fill)
      }
      .width(comp.rect.width)
      .height(comp.rect.height)
      .border({
        width: (this.touchedId === comp.component || this.selectedComponentId === comp.component) ? 2 : 1,
        color: (this.touchedId === comp.component || this.selectedComponentId === comp.component)
          ? $r('app.color.drag_indicator_active') : $r('app.color.drag_indicator'),
        style: BorderStyle.Dashed,
      })
      .position({ x: comp.rect.x, y: comp.rect.y })
      .translate({
        x: this.dragTargetId === comp.component ? this.dragOffsetX : 0,
        y: this.dragTargetId === comp.component ? this.dragOffsetY : 0,
      })
      .opacity(this.touchedId === comp.component ? 1.0 : 0.5)
      .onTouch((event: TouchEvent) => {
        this.handleComponentTouchById(comp.component, event);
      })
    } else if (comp.component === LayoutComponent.BUTTONS) {
      // ABXY 四键拼接：X 上 / Y 左 / A 右 / B 下（主题几何，无底衬整图）
      Stack() {
        this.EditorAbxyButton(getThemeAbxy(this.overlayTheme).x, 'buttons_X.png', comp.rect.width)
        this.EditorAbxyButton(getThemeAbxy(this.overlayTheme).y, 'buttons_Y.png', comp.rect.width)
        this.EditorAbxyButton(getThemeAbxy(this.overlayTheme).a, 'buttons_A.png', comp.rect.width)
        this.EditorAbxyButton(getThemeAbxy(this.overlayTheme).b, 'buttons_B.png', comp.rect.width)
      }
      .width(comp.rect.width)
      .height(comp.rect.height)
      .border({
        // 未选中: #78AF (dashed 1dp); 选中/highlighted: #F8AF (dashed 2dp)
        width: (this.touchedId === comp.component || this.selectedComponentId === comp.component) ? 2 : 1,
        color: (this.touchedId === comp.component || this.selectedComponentId === comp.component)
          ? $r('app.color.drag_indicator_active') : $r('app.color.drag_indicator'),
        style: BorderStyle.Dashed,
      })
      .position({ x: comp.rect.x, y: comp.rect.y })
      // 拖拽时通过 translate 实现视觉移动，不触发 ForEach 重建
      .translate({
        x: this.dragTargetId === comp.component ? this.dragOffsetX : 0,
        y: this.dragTargetId === comp.component ? this.dragOffsetY : 0,
      })
      .opacity(this.touchedId === comp.component ? 1.0 : 0.5)
      .onTouch((event: TouchEvent) => {
        this.handleComponentTouchById(comp.component, event);
      })
    } else {
      // 按钮组件 (对齐 Android EditorBackgroundLayoutComponentViewBuilder + background_uiview_selector)
      Stack() {
        Image($rawfile(themedImagePath(getComponentImageName(comp.component), this.overlayTheme)))
          .width('100%').height('100%')
          .objectFit(ImageFit.Contain)
      }
      .width(comp.rect.width)
      .height(comp.rect.height)
      .border({
        // 未选中: #78AF (dashed 1dp); 选中/highlighted: #F8AF (dashed 2dp)
        width: (this.touchedId === comp.component || this.selectedComponentId === comp.component) ? 2 : 1,
        color: (this.touchedId === comp.component || this.selectedComponentId === comp.component)
          ? $r('app.color.drag_indicator_active') : $r('app.color.drag_indicator'),
        style: BorderStyle.Dashed,
      })
      .position({ x: comp.rect.x, y: comp.rect.y })
      // 拖拽时通过 translate 实现视觉移动，不触发 ForEach 重建
      .translate({
        x: this.dragTargetId === comp.component ? this.dragOffsetX : 0,
        y: this.dragTargetId === comp.component ? this.dragOffsetY : 0,
      })
      .opacity(this.touchedId === comp.component ? 1.0 : 0.5)
      .onTouch((event: TouchEvent) => {
        this.handleComponentTouchById(comp.component, event);
      })
    }
  }

  /** ABXY 簇内单张按键图 (编辑器用，不含按下放大) */
  @Builder
  EditorAbxyButton(spec: AbxyButtonSpec, file: string, areaSize: number) {
    Image($rawfile(themedImagePath(file, this.overlayTheme)))
      .width(areaSize * spec.s)
      .height(areaSize * spec.s)
      .objectFit(ImageFit.Fill)
      .position({
        x: areaSize * (spec.cx - spec.ccx * spec.s),
        y: areaSize * (spec.cy - spec.ccy * spec.s)
      })
      .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 画布空白区域触摸处理 (对齐 Android LayoutEditorView init setOnClickListener)
   * 点击空白区域: 有选中组件 → 取消选中; 无选中 → 切换底部控制栏显示
   */
  private handleCanvasTouch(event: TouchEvent): void {
    if (event.type === TouchType.Up) {
      if (this.showScalingControls || this.selectedComponentId !== '') {
        SoundEffectManager.getInstance().play(SoundEffect.BACK);
        this.deselectComponent();
      } else {
        SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
        this.showBottomControls = !this.showBottomControls;
      }
    }
  }

  /**
   * 组件触摸处理 (对齐 Android LayoutEditorView.setupDragHandler)
   *
   * Android 原版: setupDragHandler 为每个 LayoutComponentView 设置独立的 OnTouchListener，
   * 闭包直接捕获 layoutComponentView 对象引用，不依赖数组下标。
   * 删除组件时只 removeView + views.remove(component)，其他组件的 listener 不受影响。
   *
   * 鸿蒙适配:
   *   ForEach 的 onTouch 闭包捕获 comp.component (唯一标识) 而非数组 index，
   *   每次触摸事件通过 findIndex 实时查找当前下标，确保删除组件后不会错位。
   *   拖拽期间通过 @State dragOffsetX/Y + .translate() 实现视觉移动，
   *   避免修改 editorComponents 数组导致 ForEach 重建组件、中断触摸序列。
   *   仅在 UP 时将最终位置提交到 editorComponents 数组。
   */
  private handleComponentTouchById(compId: string, event: TouchEvent): void {
    const touch = event.touches[0];
    if (!touch) return;

    // 阻止事件冒泡到画布，避免触发 canvas onTouch
    event.stopPropagation();

    if (event.type === TouchType.Down) {
      // 对齐 Android ACTION_DOWN
      if (this.selectedComponentId !== '') {
        this.deselectComponent();
      }
      const idx = this.editorComponents.findIndex((c: PositionedLayoutComponent) => c.component === compId);
      if (idx < 0) return;
      const comp = this.editorComponents[idx];
      // 使用窗口坐标记录触摸起始位置
      this.touchDownX = touch.windowX;
      this.touchDownY = touch.windowY;
      this.dragCompStartX = comp.rect.x;
      this.dragCompStartY = comp.rect.y;
      this.isDragging = false;
      this.dragTargetId = compId;
      this.dragOffsetX = 0;
      this.dragOffsetY = 0;
      this.touchedId = compId; // alpha=1, highlighted=true
    } else if (event.type === TouchType.Move) {
      // 对齐 Android ACTION_MOVE
      const currentIdx = this.editorComponents.findIndex((c: PositionedLayoutComponent) => c.component === compId);
      if (currentIdx < 0) return;
      const comp = this.editorComponents[currentIdx];
      // 使用窗口坐标计算移动距离
      const dx = touch.windowX - this.touchDownX;
      const dy = touch.windowY - this.touchDownY;

      if (!this.isDragging) {
        const distance = Math.sqrt(dx * dx + dy * dy);
        if (distance >= 25) {
          this.isDragging = true;
        }
      }

      if (this.isDragging) {
        // 通过 translate 实现视觉移动，不修改数组
        const b = this.getSafeBounds();
        const targetX = this.dragCompStartX + dx;
        const targetY = this.dragCompStartY + dy;
        const clampedX = Math.max(b.left, Math.min(targetX, b.right - comp.rect.width));
        const clampedY = Math.max(b.top, Math.min(targetY, b.bottom - comp.rect.height));
        if (this.gridSize <= 0) {
          // 关闭自动吸附，但仍限制组件留在安全区域内。
          this.dragOffsetX = clampedX - comp.rect.x;
          this.dragOffsetY = clampedY - comp.rect.y;
          this.snapGuideLines = [];
        } else {
          const targetRect: LayoutRect = {
            x: clampedX,
            y: clampedY,
            width: comp.rect.width,
            height: comp.rect.height
          };
          const snapResult = this.snapSystem.calculateSnap(
            targetRect, this.editorComponents, currentIdx,
            b.left, b.top, b.right, b.bottom,
          );
          const snappedX = Math.max(b.left, Math.min(snapResult.x, b.right - comp.rect.width));
          const snappedY = Math.max(b.top, Math.min(snapResult.y, b.bottom - comp.rect.height));
          this.dragOffsetX = snappedX - comp.rect.x;
          this.dragOffsetY = snappedY - comp.rect.y;
          this.snapGuideLines = snapResult.guideLines;
        }
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      // 对齐 Android ACTION_UP
      this.snapGuideLines = [];
      const currentIdx = this.editorComponents.findIndex((c: PositionedLayoutComponent) => c.component === compId);
      if (!this.isDragging) {
        // 未拖拽 → selectView()
        this.dragTargetId = '';
        this.dragOffsetX = 0;
        this.dragOffsetY = 0;
        if (currentIdx >= 0) {
          SoundEffectManager.getInstance().play(SoundEffect.SELECT);
          this.selectComponent(currentIdx);
        }
      } else {
        // 已拖拽 → 提交最终位置到数组，然后清除拖拽状态
        if (currentIdx >= 0) {
          const comp = this.editorComponents[currentIdx];
          const finalX = comp.rect.x + this.dragOffsetX;
          const finalY = comp.rect.y + this.dragOffsetY;
          this.updateComponentPosition(currentIdx, finalX, finalY);
        }
        this.dragTargetId = '';
        this.dragOffsetX = 0;
        this.dragOffsetY = 0;
        this.isDragging = false;
      }
      this.touchedId = '';
    }
  }

  // ============================================================================
  // 缩放控制面板 (对齐 Android layout_scaling: delete, width, height, alpha, aspect, above, center)
  // ============================================================================

  /**
   * 缩放控制面板 (严格对齐 Android activity_layout_editor.xml 的 layout_scaling)
   *
   * Android 结构:
   *   ScrollView(#AFFF, alignParentBottom, clickable=true)
   *     LinearLayout(vertical)
   *       Button(delete, style=Button.Editor: borderless + textColor=black)
   *       [Width row]: LinearLayout(horizontal, center_vertical)
   *         LinearLayout(vertical, minWidth=34sp, center_horizontal): TextView("宽度") + TextView(widthValue)
   *         SeekBar(max=canvasWidth, progress=widthScale*max)
   *       [Height row]: 同上
   *       [Alpha row]: TextView("透明度") + SeekBar(max=100) -- 仅屏幕
   *       [AspectRatio row]: TextView + Spinner -- 仅屏幕
   *       CheckBox("在其他屏幕上方") -- 仅屏幕
   *       [Center row]: Button("水平居中") + Button("垂直居中") -- 仅屏幕
   *
   * Android SeekBar 行为:
   *   seekBarWidth.max = canvasWidth (像素/vp)
   *   seekBarWidth.progress = widthScale * max
   *   textWidth = ((max - minSize) * widthScale + minSize).toInt()
   */
  /**
   * 缩放控制面板 (简化版: 显示删除、大小调节和菜单入口，且在同一行)
   * 菜单入口保留选中组件时的快速保存/退出路径。
   */
  @Builder
  ScalingControlsPanel() {
    Row() {
      // 删除按钮 (更多按钮和屏幕组件不可删除)
      Button({ type: ButtonType.Normal }) {
        Row() {
          SymbolGlyph($r("sys.symbol.trash"))
            .fontSize(20)
            .fontColor([this.isComponentUndeletable() ? $r("sys.color.ohos_id_color_text_tertiary") : TEXT_DANGER])
            .margin({ right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
          Text(I18n.t('delete'))
            .fontSize($r("sys.float.ohos_id_text_size_body1"))
            .fontColor(this.isComponentUndeletable() ? $r("sys.color.ohos_id_color_text_tertiary") : TEXT_DANGER)
        }
      }
      .height(SHEET_BUTTON_HEIGHT)
      .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l'), right: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
      .backgroundColor(this.getThemedItemBg())
      .enabled(!this.isComponentUndeletable())
      .onFocus(() => { SoundEffectManager.getInstance().play(SoundEffect.FOCUS); })
      .onClick(() => { SoundEffectManager.getInstance().play(SoundEffect.CONFIRM); this.deleteSelectedComponent(); })

      // 尺寸调节: 上 Slider 下 名称+值
      Column() {
        Slider({
          value: this.currentWidthScale * this.scalingMaxWidth,
          min: 0,
          max: this.scalingMaxWidth > 0 ? this.scalingMaxWidth : 1,
          step: 1,
        })
          .width('100%')
          .selectedColor(ThemeManager.getInstance().getControlAccent())
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End) {
              SoundEffectManager.getInstance().play(SoundEffect.SELECT);
            }
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Moving) {
              const maxW = this.scalingMaxWidth > 0 ? this.scalingMaxWidth : 1;
              const scale = Math.round(value) / maxW;
              this.onSizeScaleChanged(scale);
            }
          })

        Row() {
          // 减号: -1 vp (长按连续触发)
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r("sys.symbol.minus"))
              .fontSize(20)
              .fontColor([$r("sys.color.ohos_id_color_text_primary")])
          }
          .width(28).height(28)
          .padding(0)
          .backgroundColor(this.getThemedItemBg())
          .margin({ right: $r('sys.float.ohos_id_card_margin_end') })
          .onFocus(() => { SoundEffectManager.getInstance().play(SoundEffect.FOCUS); })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.repeatCount = 0;
              this.adjustSizeByDelta(-1);
              SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
              this.repeatTimerId = setInterval(() => {
                this.repeatCount++;
                this.adjustSizeByDelta(-1);
                if (this.repeatCount % 3 === 0) {
                  SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
                }
              }, 80);
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              if (this.repeatTimerId !== -1) {
                clearInterval(this.repeatTimerId);
                this.repeatTimerId = -1;
              }
            }
          })

          Text(I18n.t('size'))
            .fontSize($r("sys.float.ohos_id_text_size_caption"))
            .fontColor($r("sys.color.ohos_id_color_text_secondary"))
          Text(`${Math.round((this.scalingMaxWidth - this.selectedViewMinSize) * this.currentWidthScale + this.selectedViewMinSize)}`)
            .fontSize($r("sys.float.ohos_id_text_size_caption"))
            .fontColor($r("sys.color.ohos_id_color_text_primary"))
            .margin({ left: $r('sys.float.ohos_id_elements_margin_horizontal_s') })

          // 加号: +1 vp (长按连续触发)
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r("sys.symbol.plus"))
              .fontSize(20)
              .fontColor([$r("sys.color.ohos_id_color_text_primary")])
          }
          .width(28).height(28)
          .padding(0)
          .backgroundColor(this.getThemedItemBg())
          .margin({ left: $r('sys.float.ohos_id_card_margin_start') })
          .onFocus(() => { SoundEffectManager.getInstance().play(SoundEffect.FOCUS); })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.repeatCount = 0;
              this.adjustSizeByDelta(1);
              SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
              this.repeatTimerId = setInterval(() => {
                this.repeatCount++;
                this.adjustSizeByDelta(1);
                if (this.repeatCount % 3 === 0) {
                  SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
                }
              }, 80);
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              if (this.repeatTimerId !== -1) {
                clearInterval(this.repeatTimerId);
                this.repeatTimerId = -1;
              }
            }
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
      .layoutWeight(1)
      .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_m'), right: $r('sys.float.ohos_id_default_padding_end'), top: $r('sys.float.ohos_id_text_paragraph_margin_xs'), bottom: $r('sys.float.ohos_id_text_paragraph_margin_xs') })

      // 菜单按钮: 选中组件时也保留快速保存/退出入口
      Button({ type: ButtonType.Normal }) {
        Row() {
          SymbolGlyph($r("sys.symbol.dot_grid_2x2"))
            .fontSize(20)
            .fontColor([$r("sys.color.ohos_id_color_text_primary")])
            .margin({ right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
          Text(I18n.t('menu'))
            .fontSize($r("sys.float.ohos_id_text_size_body1"))
            .fontColor($r("sys.color.ohos_id_color_text_primary"))
        }
      }
      .height(SHEET_BUTTON_HEIGHT)
      .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l'), right: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
      .backgroundColor(this.getThemedItemBg())
      .onFocus(() => { SoundEffectManager.getInstance().play(SoundEffect.FOCUS); })
      .onClick(() => {
        SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
        this.storeLayoutChanges();
        this.showEditorMenuSheet();
      })
    }
    .width('100%')
    .backgroundColor(this.getThemedDialogBg())
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 尺寸缩放变化 (替代 Width/Height/Aspect 逻辑)
   *
   * 使用 widthScale 作为主要缩放因子 (Size)
   * heightScale 根据组件原始宽高比自动计算
   */
  private onSizeScaleChanged(scale: number): void {
    const maxW = this.scalingMaxWidth;
    const maxH = this.scalingMaxHeight;
    const minSize = this.selectedViewMinSize;

    // 计算目标宽度
    let width = (maxW - minSize) * scale + minSize;

    // 计算目标高度 (保持原始宽高比)
    let height = width / this.selectedComponentRatio;

    // 检查边界 (Width 已经由 scale 控制在 maxW 内，但需再次检查以防万一)
    // 主要是检查 Height 是否超出 maxH
    if (height > maxH) {
      height = maxH;
      width = height * this.selectedComponentRatio;
    }

    // 再次检查 Width (防止 Height 调整导致 Width 超出)
    if (width > maxW) {
      width = maxW;
      height = width / this.selectedComponentRatio;
    }

    // 反算 scales
    const ws = Math.max(0, Math.min(1, (width - minSize) / Math.max(1, maxW - minSize)));
    const hs = Math.max(0, Math.min(1, (height - minSize) / Math.max(1, maxH - minSize)));

    this.currentWidthScale = ws;
    this.currentHeightScale = hs;
    this.scaleSelectedView(ws, hs);
  }

  /**
   * ± 按钮微调: 将选中组件的宽度调整 delta vp，高度按宽高比自动重算。
   * 复用 Slider 已有的 onSizeScaleChanged 管道做边界 clamp。
   */
  private adjustSizeByDelta(delta: number): void {
    const maxW = this.scalingMaxWidth;
    const minSize = this.selectedViewMinSize;
    const range = maxW - minSize;
    if (range <= 0) return;
    const currentWidth = range * this.currentWidthScale + minSize;
    const targetWidth = currentWidth + delta;
    const newScale = (targetWidth - minSize) / range;
    const clampedScale = Math.max(0, Math.min(1, newScale));
    this.onSizeScaleChanged(clampedScale);
  }

  // ============================================================================
  // 对话框 (对齐 Android 各种 AlertDialog)
  // ============================================================================

  /** 获取当前选中背景的名称 */
  private getSelectedBackgroundName(): string {
    if (!this.dialogBackgroundUri) return I18n.t('layout_bg_none');
    if (this.dialogBackgroundUri === THEME_COLOR_BG_URI) return I18n.t('layout_bg_theme_color');
    const builtin = BUILTIN_BACKGROUNDS.find((bg: BuiltinLayoutBackground) => bg.uri === this.dialogBackgroundUri);
    if (builtin) return I18n.t(getOverlayThemeNameKey(builtin.themeId));
    const found = this.backgroundList.find((bg: LayoutBackground) => bg.uri === this.dialogBackgroundUri);
    if (found) return found.name;
    // URI 存在但不在列表中，显示简短路径
    const parts = this.dialogBackgroundUri.split('/');
    return parts[parts.length - 1] || I18n.t('layout_bg_selected');
  }
  /**
   * 选择新背景图片 (对齐 Android addBackgroundLauncher)
   */
  private pickNewBackground(): void {
    try {
      const photoPicker = new picker.PhotoViewPicker();
      photoPicker.select({
        MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      }).then((result: picker.PhotoSelectResult) => {
        if (result.photoUris && result.photoUris.length > 0) {
          const uri = result.photoUris[0];
          // 从 URI 提取文件名作为默认名称
          const parts = uri.split('/');
          const fileName = parts[parts.length - 1] || 'Background';
          const nameWithoutExt = fileName.replace(/\.[^.]+$/, '');
          this.pendingBackgroundUri = uri;
          this.backgroundNameInputText = nameWithoutExt;
          this.showBackgroundNameInput = true;
        }
      }).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'Failed to pick background image: %{public}s', err.message);
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'PhotoViewPicker error: %{public}s', (err as Error).message);
    }
  }

  /** 删除背景 (对齐 Android BackgroundsViewModel.deleteBackground) */
  private deleteBackground(bg: LayoutBackground): void {
    this.backgroundList = this.backgroundList.filter((b: LayoutBackground) => b.id !== bg.id);
    this.saveBackgroundList();
    // 如果删除的是当前选中的背景，清除选择
    if (this.dialogBackgroundUri === bg.uri) {
      this.dialogBackgroundUri = '';
      this.selectedBackgroundId = '';
    }
  }

  /** 加载背景列表 */
  private loadBackgroundList(): void {
    try {
      const prefs = this.layoutManager.getPreferences();
      if (prefs) {
        const json = prefs.getSync(BACKGROUND_LIST_KEY, '[]') as string;
        this.backgroundList = JSON.parse(json) as LayoutBackground[];
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to load backgrounds: %{public}s', (err as Error).message);
      this.backgroundList = [];
    }
  }

  /** 保存背景列表 */
  private saveBackgroundList(): void {
    try {
      const prefs = this.layoutManager.getPreferences();
      if (prefs) {
        prefs.putSync(BACKGROUND_LIST_KEY, JSON.stringify(this.backgroundList));
        prefs.flush();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to save backgrounds: %{public}s', (err as Error).message);
    }
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
    PageTransitionEnter({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
  }
}

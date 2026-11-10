/**
 * 布局预览缩略图组件
 *
 * 在布局列表中显示每个布局的横屏/竖屏预览，预览数据与游戏运行时一致:
 * 通过 LayoutConfigManager.resolveGameComponents 按当前设备尺寸解析
 * (精确/容差/宽高比打分匹配已存变体，否则生成默认布局)，
 * 绘制两个游戏屏幕 + 实体游戏按键 (方向键/ABXY/摇杆/肩键/SELECT/START) 的位置关系。
 * 功能键 (暂停/快进/更多等) 属模拟器 UI 不入预览，缩略图尺寸下也只剩噪点。
 *
 * - 横竖屏使用当前设备的实际屏幕比例 (竖屏 = 短边×长边，横屏 = 长边×短边)
 * - 中性设备外框: 深色机身 + 阴影
 * - 按键贴图与游戏运行时一致: 固定 themes/default 素材 (运行时同样硬编码 default)；
 *   overlayTheme 仅参与布局几何解析 (各主题设计尺寸不同)，透明度跟随布局配置
 */

import { display } from '@kit.ArkUI';
import {
  getComponentImageName,
  LayoutConfiguration, LayoutComponent,
  Orientation,
} from '../../types/LayoutTypes';
import { LayoutConfigManager } from '../../utils/LayoutConfigManager';
import { FONT_SIZE_MIN, TEXT_SECONDARY } from '../../types/UIConstants';
import { I18n } from '../../utils/I18nManager';
import { getThemeAbxy, AbxyButtonSpec } from '../../utils/OverlayThemeHelper';

/** 预览用的组件矩形 (归一化到 0~1 范围) */
class PreviewRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
}

/** 预览中的实体按键: 矩形 + 素材名 (单图渲染，位置尺寸即信息本体) */
class PreviewKey {
  rect: PreviewRect = new PreviewRect();
  file: string = '';
}

/** 一个方向的预览数据 */
class OrientationPreview {
  topScreen: PreviewRect | null = null;
  bottomScreen: PreviewRect | null = null;
  dpad: PreviewRect | null = null;
  buttons: PreviewRect | null = null;
  stick: PreviewRect | null = null;
  cStick: PreviewRect | null = null;
  gameKeys: PreviewKey[] = [];
}

/** 预览渲染的实体游戏按键；功能键 (暂停/快进/更多等) 属模拟器 UI 不入预览 */
const PREVIEW_KEY_COMPONENTS: LayoutComponent[] = [
  LayoutComponent.BUTTON_L,
  LayoutComponent.BUTTON_R,
  LayoutComponent.BUTTON_ZL,
  LayoutComponent.BUTTON_ZR,
  LayoutComponent.BUTTON_SELECT,
  LayoutComponent.BUTTON_START,
];

/** 设备外框内边距 (vp) */
const DEVICE_PADDING = 3;

@Component
export struct LayoutPreviewThumbnail {
  /** 布局配置 (null 表示内置默认布局) */
  layout: LayoutConfiguration | null = null;
  /** 预览设备长边尺寸 (vp)，横竖屏共用同一物理设备，只是旋转方向 */
  previewLongSide: number = 120;
  /** 外部变更触发器 — 父组件递增此值以触发预览重新计算 */
  @Prop @Watch('onTriggerChanged') updateTrigger: number = 0;
  /** 按键遮罩主题 */
  @Prop overlayTheme: string = 'default';

  @State portraitPreview: OrientationPreview = new OrientationPreview();
  @State landscapePreview: OrientationPreview = new OrientationPreview();
  /** 设备屏幕宽高比 (短边/长边)，用于竖屏；横屏取倒数 */
  @State devicePortraitRatio: number = 9 / 16;
  /** 设备短边 vp 尺寸 */
  private deviceShortSideVp: number = 360;
  /** 设备长边 vp 尺寸 */
  private deviceLongSideVp: number = 800;

  aboutToAppear(): void {
    this.detectDeviceRatio();
    this.recomputePreviews();
  }

  private onTriggerChanged(): void {
    // 折叠/展开、分屏等场景下设备尺寸可能变化，先刷新再重算
    this.detectDeviceRatio();
    this.recomputePreviews();
  }

  private recomputePreviews(): void {
    this.portraitPreview = this.computePreview(Orientation.PORTRAIT, this.deviceShortSideVp, this.deviceLongSideVp);
    this.landscapePreview = this.computePreview(Orientation.LANDSCAPE, this.deviceLongSideVp, this.deviceShortSideVp);
  }

  private detectDeviceRatio(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const w = Math.min(d.width, d.height); // 短边 px
      const h = Math.max(d.width, d.height); // 长边 px
      if (h > 0) {
        this.devicePortraitRatio = w / h;
      }
      const density = d.densityPixels > 0 ? d.densityPixels : 3;
      this.deviceShortSideVp = Math.round(w / density);
      this.deviceLongSideVp = Math.round(h / density);
    } catch (_e) {
      this.devicePortraitRatio = 9 / 16;
      this.deviceShortSideVp = 360;
      this.deviceLongSideVp = 800;
    }
  }

  build() {
    Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_l') }) {
      this.PreviewBox(I18n.t('preview_portrait'), Orientation.PORTRAIT)
      this.PreviewBox(I18n.t('preview_landscape'), Orientation.LANDSCAPE)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l'), right: $r('sys.float.ohos_id_elements_margin_horizontal_l'), top: $r('sys.float.ohos_id_elements_margin_vertical_m'), bottom: $r('sys.float.ohos_id_elements_margin_vertical_m') })
  }

  @Builder
  PreviewBox(label: string, orientation: Orientation) {
    Column({ space: $r('sys.float.ohos_id_text_paragraph_margin_xs') }) {
      // 设备外框: 中性深色机身 + 圆角 + 阴影
      Stack() {
        if (orientation === Orientation.PORTRAIT) {
          this.ScreenPair(this.portraitPreview,
            this.getInnerW(Orientation.PORTRAIT), this.getInnerH(Orientation.PORTRAIT))
        } else {
          this.ScreenPair(this.landscapePreview,
            this.getInnerW(Orientation.LANDSCAPE), this.getInnerH(Orientation.LANDSCAPE))
        }
      }
      .width(this.getContainerW(orientation))
      .height(this.getContainerH(orientation))
      .backgroundColor($r('app.color.layout_preview_device'))
      .borderRadius($r('sys.float.ohos_id_corner_radius_grid'))
      .clip(true)
      .shadow(ShadowStyle.OUTER_DEFAULT_XS)

      Text(label)
        .fontSize(FONT_SIZE_MIN)
        .fontColor(TEXT_SECONDARY)
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  ScreenPair(preview: OrientationPreview, iw: number, ih: number) {
    // 游戏屏幕: 与布局编辑器一致的区域着色 (上屏蓝 / 下屏红), 整块填充无描边
    if (preview.topScreen) {
      this.ScreenRect(preview.topScreen, iw, ih, $r('app.color.screen_zone_top_tint'))
    }
    if (preview.bottomScreen) {
      this.ScreenRect(preview.bottomScreen, iw, ih, $r('app.color.screen_zone_bottom_tint'))
    }

    // 方向键 — 十字形
    if (preview.dpad) {
      this.DpadPreview(preview.dpad, iw, ih)
    }

    // ABXY — 菱形四点
    if (preview.buttons) {
      this.ButtonsPreview(preview.buttons, iw, ih)
    }

    // 摇杆 (布局含 C 摇杆时才绘制)
    if (preview.stick) {
      this.StickPreview(preview.stick, false, iw, ih)
    }
    if (preview.cStick) {
      this.StickPreview(preview.cStick, true, iw, ih)
    }

    // 实体按键 (L/R/ZL/ZR/SELECT/START) — 小尺寸标记，最后绘制避免被大控件盖住
    ForEach(preview.gameKeys, (key: PreviewKey) => {
      this.GameKeyPreview(key, iw, ih)
    }, (key: PreviewKey, index: number) => `${key.file}_${index}`)
  }

  @Builder
  ScreenRect(rect: PreviewRect, iw: number, ih: number, color: Resource) {
    Column()
      .width(rect.w * iw)
      .height(rect.h * ih)
      .position({
        x: DEVICE_PADDING + rect.x * iw,
        y: DEVICE_PADDING + rect.y * ih
      })
      .backgroundColor(color)
      .borderRadius($r('sys.float.ohos_id_corner_radius_progress_bar'))
      // 编辑器屏幕组件静置态整体透明度为 0.5 (触摸时 1.0), 预览与其静置观感一致
      .opacity(0.5)
  }

  @Builder
  DpadPreview(rect: PreviewRect, iw: number, ih: number) {
    Image($rawfile('themes/default/keypad.png'))
      .width(rect.w * iw)
      .height(rect.h * ih)
      .objectFit(ImageFit.Fill)
      .position({
        x: DEVICE_PADDING + rect.x * iw,
        y: DEVICE_PADDING + rect.y * ih
      })
      .opacity(this.getButtonOpacity())
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  ButtonsPreview(rect: PreviewRect, iw: number, ih: number) {
    // ABXY 四键拼接（主题几何，无底衬整图）；按键区域按正方形几何布局
    Stack() {
      this.AbxyButtonImage(getThemeAbxy('default').x, 'buttons_X.png', Math.min(rect.w * iw, rect.h * ih))
      this.AbxyButtonImage(getThemeAbxy('default').y, 'buttons_Y.png', Math.min(rect.w * iw, rect.h * ih))
      this.AbxyButtonImage(getThemeAbxy('default').a, 'buttons_A.png', Math.min(rect.w * iw, rect.h * ih))
      this.AbxyButtonImage(getThemeAbxy('default').b, 'buttons_B.png', Math.min(rect.w * iw, rect.h * ih))
    }
    .width(rect.w * iw)
    .height(rect.h * ih)
    .position({
      x: DEVICE_PADDING + rect.x * iw,
      y: DEVICE_PADDING + rect.y * ih
    })
    .opacity(this.getButtonOpacity())
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  StickPreview(rect: PreviewRect, isCStick: boolean, iw: number, ih: number) {
    // 摇杆: 底座 + 摇杆头两层图片 (与编辑器渲染一致)
    Stack() {
      Image($rawfile(isCStick ? 'themes/default/stick_c_range.png' : 'themes/default/stick_main_range.png'))
        .width('100%').height('100%')
        .objectFit(ImageFit.Fill)
      Image($rawfile(isCStick ? 'themes/default/stick_c.png' : 'themes/default/stick_main.png'))
        .width('100%').height('100%')
        .objectFit(ImageFit.Fill)
    }
    .width(rect.w * iw)
    .height(rect.h * ih)
    .position({
      x: DEVICE_PADDING + rect.x * iw,
      y: DEVICE_PADDING + rect.y * ih
    })
    .opacity(this.getButtonOpacity())
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  AbxyButtonImage(spec: AbxyButtonSpec, file: string, areaSize: number) {
    Image($rawfile(`themes/default/${file}`))
      .width(areaSize * spec.s)
      .height(areaSize * spec.s)
      .objectFit(ImageFit.Fill)
      .position({
        x: areaSize * (spec.cx - spec.ccx * spec.s),
        y: areaSize * (spec.cy - spec.ccy * spec.s)
      })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  GameKeyPreview(key: PreviewKey, iw: number, ih: number) {
    Image($rawfile(`themes/default/${key.file}`))
      .width(key.rect.w * iw)
      .height(key.rect.h * ih)
      .objectFit(ImageFit.Fill)
      .position({
        x: DEVICE_PADDING + key.rect.x * iw,
        y: DEVICE_PADDING + key.rect.y * ih
      })
      .opacity(this.getButtonOpacity())
      .hitTestBehavior(HitTestMode.None)
  }

  /** 获取按钮透明度: 使用布局配置的自定义透明度，否则默认 0.7 */
  private getButtonOpacity(): number {
    if (this.layout && this.layout.useCustomOpacity) {
      return this.layout.opacity / 100;
    }
    return 0.7;
  }

  /** 外框总宽度 (含 padding) */
  private getContainerW(orientation: Orientation): number {
    if (orientation === Orientation.PORTRAIT) {
      // 竖屏: 宽 = 短边
      return this.previewLongSide * this.devicePortraitRatio + DEVICE_PADDING * 2;
    }
    // 横屏: 宽 = 长边
    return this.previewLongSide + DEVICE_PADDING * 2;
  }

  /** 外框总高度 (含 padding) */
  private getContainerH(orientation: Orientation): number {
    if (orientation === Orientation.PORTRAIT) {
      // 竖屏: 高 = 长边
      return this.previewLongSide + DEVICE_PADDING * 2;
    }
    // 横屏: 高 = 短边
    return this.previewLongSide * this.devicePortraitRatio + DEVICE_PADDING * 2;
  }

  /** 内部可用宽度 (去掉 padding) */
  private getInnerW(orientation: Orientation): number {
    if (orientation === Orientation.PORTRAIT) {
      return this.previewLongSide * this.devicePortraitRatio;
    }
    return this.previewLongSide;
  }

  /** 内部可用高度 (去掉 padding) */
  private getInnerH(orientation: Orientation): number {
    if (orientation === Orientation.PORTRAIT) {
      return this.previewLongSide;
    }
    return this.previewLongSide * this.devicePortraitRatio;
  }

  /**
   * 计算指定方向的预览数据 (归一化到 0~1)
   * refW/refH 为设备参考尺寸 (vp): 竖屏 = 短边×长边，横屏 = 长边×短边。
   * 与游戏运行时同一解析路径 (resolveGameComponents 内部处理
   * 精确/容差/宽高比打分匹配及默认布局回退)，因此无需再自行挑选变体。
   */
  private computePreview(orientation: Orientation, refW: number, refH: number): OrientationPreview {
    const manager = LayoutConfigManager.getInstance();
    const components = this.layout
      ? manager.resolveGameComponents(this.layout, refW, refH, this.overlayTheme)
      : (orientation === Orientation.LANDSCAPE
        ? manager.buildDefaultLandscapeLayout(refW, refH, this.overlayTheme)
        : manager.buildDefaultPortraitLayout(refW, refH, this.overlayTheme));

    const result = new OrientationPreview();
    if (refW <= 0 || refH <= 0) return result;
    for (const comp of components) {
      const r = new PreviewRect();
      r.x = comp.rect.x / refW;
      r.y = comp.rect.y / refH;
      r.w = comp.rect.width / refW;
      r.h = comp.rect.height / refH;

      if (comp.component === LayoutComponent.TOP_SCREEN) {
        result.topScreen = r;
      } else if (comp.component === LayoutComponent.BOTTOM_SCREEN) {
        result.bottomScreen = r;
      } else if (comp.component === LayoutComponent.DPAD) {
        result.dpad = r;
      } else if (comp.component === LayoutComponent.BUTTONS) {
        result.buttons = r;
      } else if (comp.component === LayoutComponent.STICK) {
        result.stick = r;
      } else if (comp.component === LayoutComponent.CSTICK) {
        result.cStick = r;
      } else if (PREVIEW_KEY_COMPONENTS.indexOf(comp.component) >= 0) {
        const key = new PreviewKey();
        key.rect = r;
        key.file = getComponentImageName(comp.component);
        result.gameKeys.push(key);
      }
    }
    return result;
  }
}

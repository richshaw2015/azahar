
import { AzaharGameCardModel } from '../../models/AzaharGameCardModel';
import { AzaharThemeColors } from '../../types/ThemeTypes';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../utils/ThemeManager';
import { CARD_BORDER_COLOR, CARTRIDGE_SHELL_SHADOW, COVER_RADIUS_DEFAULT, GRID_COVER_BASE, GRID_COVER_CONTENT_BASE, LIST_COVER_BASE, TEXT_ON_ACCENT, TEXT_PRIMARY, TEXT_SECONDARY, TILE_SHADOW } from '../../types/UIConstants';
import { I18n } from '../../utils/I18nManager';
import { HdsListItemCard, PrefixCustomBuilder, SuffixCustomBuilder } from '@kit.UIDesignKit';
import { cartridgeShellBgOf, coverArtBgOf, coverPlaceholderBgOf, surfaceCardBgOf, tileBadgeActiveBgOf, tileBadgeBgOf } from '../../utils/ThemeSurfaces';

const FLASH_PULSE_HALF_DURATION_MS: number = 450;
export const AZAHAR_CARTRIDGE_FLASH_TOTAL_DURATION_MS: number = FLASH_PULSE_HALF_DURATION_MS * 2;
const FLASH_HIGHLIGHT_OPACITY: number = 0.42;
const WOBBLE_ANGLE: number = 6;
const WOBBLE_STEP_MS: number = 110;
export const COVER_ASPECT_RATIO: number = 1.12;

function darkenHex(hex: string, factor: number): string {
  const h = hex.startsWith('#') ? hex.slice(1) : hex;
  const r = Math.round(parseInt(h.substring(0, 2), 16) * (1 - factor));
  const g = Math.round(parseInt(h.substring(2, 4), 16) * (1 - factor));
  const b = Math.round(parseInt(h.substring(4, 6), 16) * (1 - factor));
  return `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`;
}

function lightenHex(hex: string, factor: number): string {
  const h = hex.startsWith('#') ? hex.slice(1) : hex;
  const r = Math.round(parseInt(h.substring(0, 2), 16) + (255 - parseInt(h.substring(0, 2), 16)) * factor);
  const g = Math.round(parseInt(h.substring(2, 4), 16) + (255 - parseInt(h.substring(2, 4), 16)) * factor);
  const b = Math.round(parseInt(h.substring(4, 6), 16) + (255 - parseInt(h.substring(4, 6), 16)) * factor);
  return `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`;
}

function hexToRgbaString(hex: string, alpha: number): string {
  const h = hex.startsWith('#') ? hex.slice(1) : hex;
  const r = parseInt(h.substring(0, 2), 16);
  const g = parseInt(h.substring(2, 4), 16);
  const b = parseInt(h.substring(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

interface CartridgeShellColors {
  shell: string;
  contactArea: string;
  highlight: ResourceColor;
  shadowEdge: ResourceColor;
  borderRight: ResourceColor;
}

/**
 * 卡带外壳配色（移植自 NDS computeCartridgeColors）：
 * 有封面主色用其深色变体当壳色，无则主题 primary 加深；
 * 上/左棱边高光、下/右棱边阴影制造注塑壳立体感。
 */
function cartridgeShellColors(coverColor: string, primary: string): CartridgeShellColors {
  const shell = coverColor ? darkenHex(coverColor, 0.35) : darkenHex(primary, 0.10);
  return {
    shell: shell,
    contactArea: darkenHex(shell, 0.12),
    highlight: hexToRgbaString(lightenHex(shell, 0.25), 0.25),
    shadowEdge: hexToRgbaString(darkenHex(shell, 0.20), 0.45),
    borderRight: hexToRgbaString(darkenHex(shell, 0.10), 0.30)
  };
}

@Component
struct AzaharMetadataPill {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  @Prop text: string = '';
  @Prop active: boolean = true;
  @Prop pillScale: number = 1.0;
  @Prop color: string = '';

  private s(value: number): number {
    return value * this.pillScale;
  }

  build() {
    Text(this.text)
      .fontSize(this.s(10))
      .fontWeight(FontWeight.Bold)
      .fontColor(this.color ? this.color : (this.active ? TEXT_PRIMARY : TEXT_SECONDARY))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: this.s(7), right: this.s(7), top: this.s(3), bottom: this.s(3) })
      .backgroundColor(this.active ? tileBadgeActiveBgOf(this.themeColors) : tileBadgeBgOf(this.themeColors))
      .borderRadius(this.s(999))
      .border({ width: 0.5, color: this.color ? this.color : CARD_BORDER_COLOR })
  }
}

@Component
struct TileArtwork {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  @ObjectLink model: AzaharGameCardModel;
  @Prop tileScale: number = 1.0;
  @StorageLink('coverCornerRadius') cornerRadius: number = COVER_RADIUS_DEFAULT;

  private s(value: number): number {
    return Math.round(value * this.tileScale);
  }

  build() {
    Stack() {
      if (this.model.coverImage || this.model.gameIcon) {
        Image(this.model.coverImage ? this.model.coverImage : this.model.gameIcon)
          .width('100%')
          .aspectRatio(COVER_ASPECT_RATIO)
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else {
        Column() {
          Text(I18n.t('brand_3ds'))
            .fontSize(this.s(16))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
        }
        .width('100%')
        .aspectRatio(COVER_ASPECT_RATIO)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(coverArtBgOf(this.themeColors))
      }
    }
    .width('100%')
    .aspectRatio(COVER_ASPECT_RATIO)
    .clip(true)
    .backgroundColor(coverPlaceholderBgOf(this.themeColors))
    .borderRadius(`${this.cornerRadius}%`)
    .shadow(TILE_SHADOW)
  }
}

@Component
export struct AzaharCartridgeGridModelItem {
  @ObjectLink model: AzaharGameCardModel;
  @Prop @Watch('onOpeningChanged') isOpening: boolean = false;
  @Prop cardSize: number = GRID_COVER_BASE;
  @Prop themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();
  @StorageLink('coverCornerRadius') cornerRadius: number = COVER_RADIUS_DEFAULT;

  onLaunch: () => void = () => {};
  onOpenDetails: () => void = () => {};
  @State private flashOpacity: number = 0;
  @State private wobbleAngle: number = 0;
  @State private pressed: boolean = false;
  // 触点区整体亮度（0.35 暗 / 1 亮），仅已插入卡带启动渐变呼吸
  @State private pinGlow: number = 0.35;
  private pinGlowStarted: boolean = false;

  aboutToAppear(): void {
    if (this.model.gameInfo.inserted) {
      this.startPinGlow();
    }
  }

  private s(value: number): number {
    return Math.round(value * this.cardSize / GRID_COVER_CONTENT_BASE);
  }

  // 渐变呼吸：整个触点区同步在暗/亮间平滑往返，EaseInOut 出自然呼吸感
  private startPinGlow(): void {
    if (this.pinGlowStarted) {
      return;
    }
    this.pinGlowStarted = true;
    animateTo({
      duration: 1400,
      iterations: -1,
      playMode: PlayMode.Alternate,
      curve: Curve.EaseInOut
    }, () => {
      this.pinGlow = 1;
    });
  }

  private pinOpacity(): number {
    return this.model.gameInfo.inserted ? this.pinGlow : 1;
  }

  // 已插入触点用色：深色模式取亮强调色——橙色主题深色 primary 与金色触点同为琥珀色，亮一档才看得出"点亮"
  private insertedAccentColor(): string {
    return ThemeManager.getInstance().isDarkModeEffective() ? this.themeColors.accent : this.themeColors.primary;
  }

  private onOpeningChanged(): void {
    if (this.isOpening) {
      this.runFlash();
      this.runWobble();
    }
  }

  private shellColors(): CartridgeShellColors {
    // 深色模式：封面色壳（原版效果）
    if (ThemeManager.getInstance().isDarkModeEffective()) {
      return cartridgeShellColors(this.model.coverColor, this.themeColors.primary);
    }
    // 浅色模式：混入少量主题色的浅色外壳（保持塑料感），棱边用半透明黑/白做立体感
    const shell = cartridgeShellBgOf(this.themeColors);
    return {
      shell: shell,
      contactArea: darkenHex(shell, 0.10),
      highlight: $r('app.color.cartridge_highlight'),
      shadowEdge: $r('app.color.cartridge_edge'),
      borderRight: $r('app.color.cartridge_edge_border')
    };
  }

  private shellTitleColor(): ResourceColor {
    return ThemeManager.getInstance().isDarkModeEffective() ? TEXT_ON_ACCENT : TEXT_PRIMARY;
  }

  private runFlash(): void {
    animateTo({ duration: FLASH_PULSE_HALF_DURATION_MS, curve: Curve.EaseInOut }, () => { this.flashOpacity = FLASH_HIGHLIGHT_OPACITY; });
    setTimeout(() => {
      animateTo({ duration: FLASH_PULSE_HALF_DURATION_MS, curve: Curve.EaseInOut }, () => { this.flashOpacity = 0; });
    }, FLASH_PULSE_HALF_DURATION_MS);
  }

  private runWobble(): void {
    animateTo({ duration: WOBBLE_STEP_MS, curve: Curve.EaseInOut }, () => { this.wobbleAngle = WOBBLE_ANGLE; });
    setTimeout(() => {
      animateTo({ duration: WOBBLE_STEP_MS, curve: Curve.EaseInOut }, () => { this.wobbleAngle = -WOBBLE_ANGLE; });
    }, WOBBLE_STEP_MS);
    setTimeout(() => {
      animateTo({ duration: WOBBLE_STEP_MS, curve: Curve.EaseInOut }, () => { this.wobbleAngle = WOBBLE_ANGLE * 0.5; });
    }, WOBBLE_STEP_MS * 2);
    setTimeout(() => {
      animateTo({ duration: WOBBLE_STEP_MS, curve: Curve.EaseInOut }, () => { this.wobbleAngle = 0; });
    }, WOBBLE_STEP_MS * 3);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 卡带本体 — 3DS 正面视图：外壳 + 内嵌标签贴纸 + 底部金手指触点
      Column() {
        Stack() {
          Column() {
            // 标签贴纸：顶部贴边、左右留出外壳边，封面圆角设置作用于贴纸
            Stack() {
              Stack() {
                if (this.model.coverImage || this.model.gameIcon) {
                  Image(this.model.coverImage ? this.model.coverImage : this.model.gameIcon)
                    .width('100%')
                    .aspectRatio(COVER_ASPECT_RATIO)
                    .objectFit(ImageFit.Cover)
                    .draggable(false)
                } else {
                  Column() {
                    Text(I18n.t('brand_3ds'))
                      .fontSize(this.s(16))
                      .fontWeight(FontWeight.Bold)
                      .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
                  }
                  .width('100%')
                  .aspectRatio(COVER_ASPECT_RATIO)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(coverArtBgOf(this.themeColors))
                }
              }
              .width('100%')
              .aspectRatio(COVER_ASPECT_RATIO)
              .borderRadius(`${this.cornerRadius}%`)
              .clip(true)
            }
            .width('100%')
            .margin({ left: this.s(4), right: this.s(4) })

            // 游戏名称 — 印刷在外壳标签下方
            Text(this.model.displayName)
              .fontSize(this.s(11))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.shellTitleColor())
              .opacity(0.85)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .width('85%')
              .margin({ top: this.s(4) })
          }
          .width('100%')
          .height('100%')
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)

        // 底部金手指触点区 — 已插入时触点连同槽底染主题色，像卡带进槽"通电"
        Row() {
          ForEach([0, 1, 2, 3, 4, 5, 6, 7], (_: number) => {
            Column()
              .width(this.s(6))
              .height(this.s(4))
              .backgroundColor(this.model.gameInfo.inserted ? this.insertedAccentColor() : $r('app.color.cartridge_pin_gold'))
              .opacity(this.pinOpacity())
              .borderRadius({ topLeft: this.s(1), topRight: this.s(1) })
              .margin({ left: this.s(2), right: this.s(2) })
          })
        }
        .width('100%')
        .height(this.s(10))
        .justifyContent(FlexAlign.Center)
        // 槽底染色随触点同步明暗（0.20~0.35），整区一起闪
        .backgroundColor(this.model.gameInfo.inserted ? hexToRgbaString(this.insertedAccentColor(), 0.20 + 0.15 * this.pinGlow) : this.shellColors().contactArea)
        .borderRadius({ bottomLeft: this.s(6), bottomRight: this.s(6) })
      }
      .width(this.s(104))
      .height('100%')
      .backgroundColor(this.shellColors().shell)
      // 注塑壳立体感：上/左高光棱边 + 下/右阴影棱边
      .border({
        width: { top: 1, bottom: 1, left: 1, right: 1 },
        color: {
          top: this.shellColors().highlight,
          bottom: this.shellColors().shadowEdge,
          left: this.shellColors().highlight,
          right: this.shellColors().borderRight
        }
      })
      .borderRadius(this.s(6))
      // 贴纸顶部贴边，封面圆角为 0 时其直角会戳出外壳圆角，需沿外壳轮廓裁剪子内容
      .clip(true)
      // 已插入时投影换成主题色光晕，强化"入槽高亮"
      .shadow(this.model.gameInfo.inserted ?
        { radius: this.s(10), color: hexToRgbaString(this.insertedAccentColor(), 0.35), offsetX: 0, offsetY: this.s(3) } :
        {
          radius: this.s(CARTRIDGE_SHELL_SHADOW.radius),
          color: CARTRIDGE_SHELL_SHADOW.color,
          offsetX: this.s(CARTRIDGE_SHELL_SHADOW.offsetX),
          offsetY: this.s(CARTRIDGE_SHELL_SHADOW.offsetY)
        })

      // 右侧凸耳 — 3DS 卡带防呆特征（NDS 的左上缺角在 3DS 上不存在，换成侧凸耳），着封面主色
      Row()
        .width(this.s(4))
        .height(this.s(16))
        .backgroundColor(this.model.coverColor ? this.model.coverColor : this.shellColors().shell)
        .borderRadius({ topRight: this.s(2), bottomRight: this.s(2) })
        .position({ x: this.s(104), y: this.s(10) })

      // 长按"闪烁打开"高光层 — 不拦截点击
      Column()
        .width(this.s(108))
        .height(this.s(132))
        .backgroundColor(Color.White)
        .opacity(this.flashOpacity * 0.6)
        .borderRadius(this.s(6))
        .hitTestBehavior(HitTestMode.None)
    }
    .width(this.s(108))
    .height(this.s(132))
    .scale({ x: this.pressed ? 0.92 : (this.isOpening ? 1.06 : 1.0), y: this.pressed ? 0.92 : (this.isOpening ? 1.06 : 1.0) })
    .rotate({ x: 0, y: 0, z: 1, angle: this.wobbleAngle })
    .animation({ duration: 140, curve: Curve.EaseOut })
    .transition(TransitionEffect.OPACITY.animation({ duration: 150, curve: Curve.EaseOut }))
    .onClick(() => {
      this.onLaunch();
    })
    .gesture(LongPressGesture().onAction(() => {
      this.onOpenDetails();
    }))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}

@Component
export struct AzaharCartridgeListModelItem {
  @ObjectLink model: AzaharGameCardModel;
  @Prop @Watch('onOpeningChanged') isOpening: boolean = false;
  @Prop cardSize: number = LIST_COVER_BASE;
  @Prop themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();
  @StorageLink('coverCornerRadius') cornerRadius: number = COVER_RADIUS_DEFAULT;

  onLaunch: () => void = () => {};
  onOpenDetails: () => void = () => {};
  @State private flashOpacity: number = 0;
  @State private wobbleAngle: number = 0;
  private longPressTimer: number = 0;
  private touchDownX: number = 0;
  private touchDownY: number = 0;
  private longPressFired: boolean = false;

  private s(value: number): number {
    return Math.round(value * this.cardSize / LIST_COVER_BASE);
  }

  private rowHeight(): number {
    return this.s(64) + 16;
  }

  private listCardBackground(): ResourceColor | undefined {
    if (!ThemeManager.getInstance().isDarkModeEffective()) {
      return surfaceCardBgOf(this.themeColors);
    }
    if (!this.model.coverColor) {
      return undefined;
    }
    return darkenHex(this.model.coverColor, 0.55);
  }

  private titleFontColor(): ResourceColor {
    if (!this.model.coverColor || ThemeManager.getInstance().isDarkModeEffective()) {
      return TEXT_PRIMARY;
    }
    return darkenHex(this.model.coverColor, 0.7);
  }

  private onOpeningChanged(): void {
    if (this.isOpening) {
      this.runFlash();
      this.runWobble();
    }
  }

  private runWobble(): void {
    animateTo({ duration: WOBBLE_STEP_MS, curve: Curve.EaseInOut }, () => { this.wobbleAngle = WOBBLE_ANGLE; });
    setTimeout(() => {
      animateTo({ duration: WOBBLE_STEP_MS, curve: Curve.EaseInOut }, () => { this.wobbleAngle = -WOBBLE_ANGLE; });
    }, WOBBLE_STEP_MS);
    setTimeout(() => {
      animateTo({ duration: WOBBLE_STEP_MS, curve: Curve.EaseInOut }, () => { this.wobbleAngle = WOBBLE_ANGLE * 0.5; });
    }, WOBBLE_STEP_MS * 2);
    setTimeout(() => {
      animateTo({ duration: WOBBLE_STEP_MS, curve: Curve.EaseInOut }, () => { this.wobbleAngle = 0; });
    }, WOBBLE_STEP_MS * 3);
  }

  private handleRowTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down && event.touches.length > 0) {
      this.touchDownX = event.touches[0].x;
      this.touchDownY = event.touches[0].y;
      this.longPressFired = false;
      if (this.longPressTimer) {
        clearTimeout(this.longPressTimer);
      }
      this.longPressTimer = setTimeout(() => {
        this.longPressTimer = 0;
        this.longPressFired = true;
        this.onOpenDetails();
      }, 500);
      return;
    }
    if (event.type === TouchType.Move && event.touches.length > 0) {
      const dx = event.touches[0].x - this.touchDownX;
      const dy = event.touches[0].y - this.touchDownY;
      if (Math.sqrt(dx * dx + dy * dy) > 10 && this.longPressTimer) {
        clearTimeout(this.longPressTimer);
        this.longPressTimer = 0;
      }
      return;
    }
    if (this.longPressTimer) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = 0;
    }
  }

  private runFlash(): void {
    animateTo({ duration: FLASH_PULSE_HALF_DURATION_MS, curve: Curve.EaseInOut }, () => { this.flashOpacity = FLASH_HIGHLIGHT_OPACITY; });
    setTimeout(() => {
      animateTo({ duration: FLASH_PULSE_HALF_DURATION_MS, curve: Curve.EaseInOut }, () => { this.flashOpacity = 0; });
    }, FLASH_PULSE_HALF_DURATION_MS);
  }

  @Builder
  ListItemArtwork() {
    Stack() {
      TileArtwork({
        model: this.model,
        tileScale: 0.68 * this.cardSize / LIST_COVER_BASE
      })
        .width(this.s(72))
        .height(this.s(64))

      if (this.isOpening) {
        Column()
          .width(this.s(72))
          .height(this.s(64))
          .borderRadius(`${this.cornerRadius}%`)
          .border({ width: 2, color: this.themeColors.primary })
      }

      Column()
        .width(this.s(72))
        .height(this.s(64))
        .backgroundColor(this.flashColor())
        .opacity(this.flashOpacity * 0.6)
        .borderRadius(`${this.cornerRadius}%`)
        .hitTestBehavior(HitTestMode.None)
    }
    .width(this.s(72) + 20)
    .height(this.rowHeight())
    .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_m'), right: $r('sys.float.ohos_id_card_margin_middle') })
    .rotate({ x: 0, y: 0, z: 1, angle: this.wobbleAngle })
    .scale({ x: this.isOpening ? 1.08 : 1.0, y: this.isOpening ? 1.08 : 1.0 })
    .animation({ duration: 140, curve: Curve.EaseOut })
  }

  @Builder
  ListItemTexts() {
    Column({ space: $r('sys.float.ohos_id_text_paragraph_margin_xs') }) {
      Text(this.model.displayName)
        .fontSize($r('sys.float.ohos_id_text_size_body1'))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.titleFontColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (this.model.subtitle) {
        Text(this.model.subtitle)
          .fontSize($r('sys.float.ohos_id_text_size_body2'))
          .fontColor(TEXT_SECONDARY)
          // 副标题允许两行：游玩时长等信息常与类别/发行商同串，单行会截断
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ListItemContent() {
    Row() {
      this.ListItemArtwork()
      this.ListItemTexts()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ListItemSuffix() {
    if (this.model.gameInfo.favorite) {
      AzaharMetadataPill({ text: I18n.t('favorite_short'),
        color: this.themeColors.controlAccent ?? this.themeColors.primary })
        .margin({ left: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
    }
    if (this.model.gameInfo.inserted) {
      AzaharMetadataPill({ text: I18n.t('cartridge_short') })
        .margin({ left: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
    }

    Text('')
      .width(6)
      .height(6)
      .margin({ left: $r('sys.float.ohos_id_elements_margin_horizontal_m'), right: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
      .backgroundColor(this.isOpening ? this.themeColors.primary : 'transparent')
      .borderRadius($r('sys.float.ohos_id_corner_radius_default_xs'))
  }

  private flashColor(): string {
    return this.model.coverColor || this.themeColors.primary;
  }

  build() {
    HdsListItemCard({
      cardHeight: this.rowHeight(),
      cardPrefixMargin: 12,
      cardSuffixMargin: 12,
      cardBackgroundColor: this.listCardBackground(),
      prefixItem: new PrefixCustomBuilder((): void => {
        this.ListItemContent();
      }),
      suffixItem: new SuffixCustomBuilder((): void => {
        this.ListItemSuffix();
      }),
      onClick: () => {
        if (this.longPressFired) {
          this.longPressFired = false;
          return;
        }
        this.onLaunch();
      }
    })
    .width('100%')
    .height(this.rowHeight())
    .onTouch((event: TouchEvent) => {
      this.handleRowTouch(event);
    })
  }
}

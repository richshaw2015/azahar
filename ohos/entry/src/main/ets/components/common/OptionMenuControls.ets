import { CapsuleSegmentButtonV2, ColorMetrics, ComposeListItem, LengthMetrics, SegmentButtonV2ItemOptions, SegmentButtonV2Items, SymbolGlyphModifier } from '@kit.ArkUI';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { controlAccentOf, immersiveMaterial } from './AzaharControls';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import {
  BUTTON_ICON_SM,
  FONT_SIZE_SETTING_TITLE,
  INPUT_BORDER_RADIUS,
  INPUT_PADDING_H,
  MENU_ITEM_DIVIDER,
  TEXT_PRIMARY
} from '../../types/UIConstants';
import { inputBgOf } from '../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../utils/ThemeManager';
import { AzaharThemeColors } from '../../types/ThemeTypes';

/** 对号下拉菜单内容：每个 MenuItem 包 MenuItemGroup，组间自动生成系统分隔线。 */
@Builder
function OptionMenuContent(options: SelectOption[], selectedIndex: number, accent: string,
  onPick: (index: number) => void) {
  Menu() {
    ForEach(options, (option: SelectOption, index: number) => {
      MenuItemGroup() {
        MenuItem({ content: option.value })
          .selected(index === selectedIndex)
          .selectIcon(new SymbolGlyphModifier($r('sys.symbol.checkmark')).fontColor([accent]))
          .onClick(() => {
            SoundEffectManager.getInstance().play(SoundEffect.SELECT);
            onPick(index);
          })
      }
    })
  }
  .menuItemDivider(MENU_ITEM_DIVIDER)
  .menuItemGroupDivider(MENU_ITEM_DIVIDER)
}

/**
 * 「标签 + 当前值 + 下拉菜单」选项行：与系统设置一致的形态——
 * 触发端为浅色值文本 + 小三角，展开菜单用对号标记选中项（对号着主题强调色）。
 * bindMenu 挂在整行上，点击行内任意位置都可展开。
 * 用 @Component 而非 @Builder 实现：按值传参的 @Builder 内部 UI 不随参数变化刷新，
 * @Prop 保证选择变化后值文本与菜单选中态同步更新。
 */
@Component
export struct OptionMenuRow {
  @Prop title: string = '';
  @Prop options: SelectOption[] = [];
  @Prop selectedIndex: number = 0;
  @Prop accent: string = '';
  onPick: (index: number) => void = () => {};

  build() {
    ComposeListItem({
      contentItem: {
        primaryText: this.title
      },
      operateItem: {
        text: this.options[this.selectedIndex]?.value ?? '',
        arrow: {
          value: $r('sys.symbol.arrowtriangle_down_fill')
        }
      }
    })
    .width('100%')
    .bindMenu(OptionMenuContent(this.options, this.selectedIndex, this.accent, this.onPick), {
      placement: Placement.BottomRight,
      systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
    })
  }
}

/**
 * 「当前值 + 小三角」下拉触发端 + bindMenu 对号菜单。
 * framed = false：纯文本形态，用于行内值显示（系统设置风格）。
 * framed = true：输入框形态（浅色底 + 薄材质），用于表单列（如日期选择）。
 */
@Component
export struct OptionMenuInline {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  @Prop options: SelectOption[] = [];
  @Prop selectedIndex: number = 0;
  @Prop accent: string = '';
  @Prop framed: boolean = false;
  onPick: (index: number) => void = () => {};

  @Builder
  OptionMenu() {
    OptionMenuContent(this.options, this.selectedIndex, this.accent, this.onPick)
  }

  @Builder
  TriggerContent() {
    Text(this.options[this.selectedIndex]?.value ?? '')
      .fontSize($r('sys.float.ohos_id_text_size_body2'))
      .fontColor(this.framed ? $r('sys.color.ohos_id_color_text_primary') : $r('sys.color.ohos_id_color_text_secondary'))
      .layoutWeight(this.framed ? 1 : 0)

    SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
      .fontSize(BUTTON_ICON_SM)
      .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
  }

  build() {
    Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_s') }) {
      this.TriggerContent()
    }
    .width(this.framed ? '100%' : undefined)
    .padding(this.framed ? {
      left: INPUT_PADDING_H,
      right: INPUT_PADDING_H,
      top: $r('sys.float.ohos_id_textfield_padding_vertical'),
      bottom: $r('sys.float.ohos_id_textfield_padding_vertical')
    } : 0)
    .backgroundColor(this.framed ? inputBgOf(this.themeColors) : Color.Transparent)
    .borderRadius(this.framed ? INPUT_BORDER_RADIUS : 0)
    .systemMaterial(this.framed ? immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true) : undefined)
    .bindMenu(this.OptionMenu(), {
      placement: Placement.BottomRight,
      systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
    })
  }
}

/**
 * 「标签 + 胶囊分段」单选行：标签居左、分段按钮贴右同行排布，
 * 选项并列铺开直接点按，一步完成切换，用于快捷面板内少量并列项的即时预览型选择。
 * 选中项着主题强调色实心底——SegmentButtonV2 是 pattern 组件，
 * WithTheme 染不到，只能走显式颜色属性；选中文字默认 font_on_primary。
 */
@Component
export struct SegmentOptionRow {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  @Prop title: string = '';
  @Prop options: string[] = [];
  @Prop selectedIndex: number = 0;
  onPick: (index: number) => void = () => {};

  /** 单项估算宽度（vp）：胶囊分段按背板等分，取够放 4 个汉字的宽度 */
  private segmentWidth(): number {
    return this.options.length * 72;
  }

  build() {
    Row() {
      Text(this.title)
        .fontSize(FONT_SIZE_SETTING_TITLE)
        .fontColor(TEXT_PRIMARY)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)

      // CapsuleSegmentButtonV2 不支持通用属性（无 .width/.layoutWeight），且会按拿到的
      // 最大约束铺满（constraintSize 只限 Column 自身、挡不住溢出），必须给包层固定宽；
      // SpaceBetween 让标题靠左、分段靠右，中间自动留空
      Column() {
        CapsuleSegmentButtonV2({
          items: new SegmentButtonV2Items(this.options.map((value: string): SegmentButtonV2ItemOptions => ({ text: value }))),
          selectedIndex: this.selectedIndex,
          itemSelectedBackgroundColor: ColorMetrics.resourceColor(controlAccentOf(this.themeColors)),
          itemPadding: { start: LengthMetrics.vp(4), end: LengthMetrics.vp(4) },
          itemMinFontScale: 0.8,
          enableStateAnimation: true,
          onItemClicked: (index: number) => {
            if (index !== this.selectedIndex) {
              SoundEffectManager.getInstance().play(SoundEffect.SELECT);
            }
            this.onPick(index);
          }
        })
      }
      .width(this.segmentWidth())
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('sys.float.ohos_id_default_padding_start'),
      right: $r('sys.float.ohos_id_default_padding_end'),
      top: $r('sys.float.ohos_id_elements_margin_vertical_m'),
      bottom: $r('sys.float.ohos_id_elements_margin_vertical_m')
    })
  }
}

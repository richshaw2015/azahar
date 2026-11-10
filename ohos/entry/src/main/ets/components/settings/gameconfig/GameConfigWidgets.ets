import { ComposeListItem, IconType, SymbolGlyphModifier } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { SelectSettingItem } from '../SelectSettingItem';
import { StaticInfoRow } from '../SettingsList';
import { COVER_ASPECT_RATIO } from '../../game/AzaharCartridgeItem';
import { controlAccentOf } from '../../common/AzaharControls';
import { I18n } from '../../../utils/I18nManager';
import { SettingOption } from '../../../types/SettingsTypes';
import { AzaharThemeColors } from '../../../types/ThemeTypes';
import { SoundEffect, SoundEffectManager } from '../../../utils/SoundEffectManager';
import {
  BUTTON_ICON_SM,
  CARD_BORDER_COLOR,
  RADIUS_MD,
  TEXT_DANGER,
  TEXT_DISABLED,
  TEXT_ON_ACCENT,
  TEXT_PRIMARY
} from '../../../types/UIConstants';
import { surfaceCardBgOf } from '../../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';

const TEXT_MUTED: Resource = TEXT_DISABLED;

@Component
export struct GameConfigIcon {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  // PixelMap 是 native 绑定对象，@Prop 深拷贝会产生原生层无法解析的空壳，必须按引用传递
  @Link icon: image.PixelMap | undefined;
  @Prop iconSize: number = 156;

  build() {
    if (this.icon) {
      Image(this.icon)
        .width(this.iconSize)
        .aspectRatio(COVER_ASPECT_RATIO)
        .objectFit(ImageFit.Cover)
        .backgroundColor(surfaceCardBgOf(this.themeColors))
        .borderRadius(RADIUS_MD)
        .border({ width: '1px', color: CARD_BORDER_COLOR })
        .clip(true)
    } else {
      Column() {
        Text(I18n.t('brand_3ds'))
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_ON_ACCENT)
      }
      .width(this.iconSize)
      .aspectRatio(COVER_ASPECT_RATIO)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.ds_brand_blue'))
      .borderRadius(RADIUS_MD)
    }
  }
}

@Builder
export function GameConfigInfoRow(label: string, value: string, stacked?: boolean) {
  // 纯信息展示行，无点击事件——用无按压态的静态行；堆叠模式下值占满内容区宽度
  if (stacked) {
    StaticInfoRow({ title: label, desc: value })
  } else {
    StaticInfoRow({ title: label, value: value })
  }
}

@Component
export struct GameConfigPrimaryAction {
  @Prop icon: ResourceStr;
  @Prop label: string;
  @Prop actionEnabled: boolean = true;
  @Prop themeColors: AzaharThemeColors;
  soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  onAction: () => void = () => {};

  build() {
    Button() {
      Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
        if (typeof this.icon !== 'string') {
          SymbolGlyph(this.icon)
            .fontSize(BUTTON_ICON_SM)
            .fontColor([TEXT_ON_ACCENT])
        }
        Text(this.label)
          .fontSize($r('sys.float.ohos_id_text_size_button2'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .justifyContent(FlexAlign.Center)
    }
    .type(ButtonType.Capsule)
    .height($r('sys.float.ohos_id_button_height'))
    .padding({ left: $r('sys.float.ohos_id_button_horizontal_padding'), right: $r('sys.float.ohos_id_button_horizontal_padding') })
    .buttonStyle(ButtonStyleMode.EMPHASIZED)
    .fontColor(TEXT_ON_ACCENT)
    .backgroundColor(controlAccentOf(this.themeColors))
    .enabled(this.actionEnabled)
    .onFocus(() => {
      this.soundEffectManager.play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      this.soundEffectManager.play(SoundEffect.DECIDE);
      this.onAction();
    })
    .width('100%')
  }
}

@Component
export struct GameConfigActionRow {
  @Prop icon: ResourceStr;
  @Prop title: string;
  @Prop description: string;
  @Prop actionEnabled: boolean = true;
  @Prop destructive: boolean = false;
  soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  onAction: () => void = () => {};

  build() {
    ComposeListItem({
      contentItem: {
        iconStyle: IconType.SYSTEM_ICON,
        icon: typeof this.icon !== 'string' ? this.icon : undefined,
        symbolStyle: typeof this.icon !== 'string' ? new SymbolGlyphModifier(this.icon)
          .fontColor([this.actionEnabled ? (this.destructive ? TEXT_DANGER : TEXT_PRIMARY) : TEXT_MUTED]) : undefined,
        primaryText: this.title,
        secondaryText: this.description.length > 0 ? this.description : undefined
      },
      operateItem: {
        arrow: {
          value: $r('sys.symbol.chevron_right')
        }
      }
    })
    .opacity(this.actionEnabled ? 1 : 0.6)
    .enabled(this.actionEnabled)
    .onFocus(() => {
      this.soundEffectManager.play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      if (this.actionEnabled) {
        this.soundEffectManager.play(this.destructive ? SoundEffect.CONFIRM : SoundEffect.DECIDE);
        this.onAction();
      }
    })
  }
}

/**
 * Component wrappers are intentional here. Builder arguments are evaluated only when the
 * builder is first invoked, while these rows must react when the game config object is replaced
 * after a menu selection.
 */
@Component
export struct GameConfigSelectRow {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop options: SettingOption[] = [];
  @Prop selected: number = -1;
  onSelect: (value: number) => void = () => {};

  build() {
    SelectSettingItem({
      title: this.title,
      description: this.description,
      options: this.options,
      selectedIndex: this.options.findIndex((option: SettingOption) => option.value === this.selected),
      onSelect: (_index: number, value: string | number) => {
        this.onSelect(value as number);
      }
    })
  }
}

@Component
export struct GameConfigStringSelectRow {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop options: SettingOption[] = [];
  @Prop selected: string = '';
  onSelect: (value: string) => void = () => {};

  build() {
    SelectSettingItem({
      title: this.title,
      description: this.description,
      options: this.options,
      selectedIndex: this.options.findIndex((option: SettingOption) => option.value === this.selected),
      onSelect: (_index: number, value: string | number) => {
        this.onSelect(value as string);
      }
    })
  }
}

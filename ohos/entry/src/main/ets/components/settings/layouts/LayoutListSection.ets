

import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';

import { LayoutConfiguration } from '../../../types/LayoutTypes';
import { SoundEffectManager, SoundEffect } from '../../../utils/SoundEffectManager';
import { I18n } from '../../../utils/I18nManager';

import { LayoutPreviewThumbnail } from '../LayoutPreviewThumbnail';

import uiMaterial from '@ohos.arkui.uiMaterial';

import { immersiveMaterial } from '../../common/AzaharControls';
import { SettingsList, settingsGroupDivider } from '../SettingsList';
import { MENU_ITEM_DIVIDER } from '../../../types/UIConstants';

import { listCardBgOf, secondaryButtonBgOf } from '../../../utils/ThemeSurfaces';
import { AzaharThemeColors } from '../../../types/ThemeTypes';

const BUILTIN_DEFAULT_ID = '__builtin_default__';

/** 布局列表域：加载/选择态 + 全局/默认/自定义三种列表项；菜单内容由外部回调提供 */
@Component
export struct LayoutListSection {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller: Scroller = new Scroller();
  @Prop isLoading: boolean = false;
  @Prop isSelectMode: boolean = false;
  @Prop layouts: LayoutConfiguration[] = [];
  @Prop refreshKey: number = 0;
  @Prop selectedLayoutId: string = '';
  @Prop overlayTheme: string = '';
  onEdit: (layout: LayoutConfiguration) => void = () => {};
  onDelete: (layout: LayoutConfiguration) => void = () => {};
  onSetSelected: (id: string) => void = () => {};

  @Builder
  ListContent() {
    if (this.isLoading) {
      Column().width('100%').height('100%')
    } else {
      SettingsList({ scroller: this.scroller }) {
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          // 选择器模式: 在顶部显示"使用全局布局"选项 (对齐 Android getGlobalLayoutPlaceholder)
          if (this.isSelectMode) {
            ListItem() {
              this.LayoutListItem_UseGlobal()
            }
          }
          // 默认布局 (对齐 Android: 始终显示 Default 布局项)
          ListItem() {
            this.LayoutListItem_Default()
          }
          // 自定义布局列表
          ForEach(this.layouts, (layout: LayoutConfiguration) => {
            ListItem() {
              this.LayoutListItem_Custom(layout)
            }
          }, (layout: LayoutConfiguration) => `${layout.id}_${this.refreshKey}`)
        }
        .backgroundColor(listCardBgOf(this.themeColors))
        .divider(settingsGroupDivider())
      }
    }
  }

  /** "使用全局布局"列表项 — 仅在选择器模式显示 (对齐 Android getGlobalLayoutPlaceholder) */

  @Builder
  LayoutListItem_UseGlobal() {
    Row() {
      Radio({ value: '__use_global__', group: 'layoutGroup' })
        .checked(this.selectedLayoutId === '')
        .radioStyle({ checkedBackgroundColor: ThemeManager.getInstance().getControlAccent() })
        .onChange((isChecked: boolean) => {
          if (isChecked) {
            SoundEffectManager.getInstance().play(SoundEffect.SELECT);
            this.onSetSelected('');
          }
        })
        .width(20).height(20)

      Text(I18n.t('use_global_layout'))
        .fontSize($r("sys.float.ohos_id_text_size_body1")).fontColor($r("sys.color.ohos_id_color_text_primary"))
        .margin({ left: 32 })
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Column().width(48).height(48)
    }
    .width('100%')
    .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l'), right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
    .alignItems(VerticalAlign.Center)
    .height(56)
    .useEffect(true)
    .onClick(() => {
      SoundEffectManager.getInstance().play(SoundEffect.SELECT);
      this.onSetSelected('');
    })
  }

  /** 默认布局列表项 (对齐 Android LayoutItem with type=DEFAULT) */

  @Builder
  LayoutListItem_Default() {
    Column() {
      Row() {
        Radio({ value: BUILTIN_DEFAULT_ID, group: 'layoutGroup' })
          .checked(this.selectedLayoutId === BUILTIN_DEFAULT_ID)
          .radioStyle({ checkedBackgroundColor: ThemeManager.getInstance().getControlAccent() })
          .onChange((isChecked: boolean) => {
            if (isChecked) {
              SoundEffectManager.getInstance().play(SoundEffect.SELECT);
              this.onSetSelected(BUILTIN_DEFAULT_ID);
            }
          })
          .width(20).height(20)

        Text(I18n.t('default_layout'))
          .fontSize($r("sys.float.ohos_id_text_size_body1")).fontColor($r("sys.color.ohos_id_color_text_primary"))
          .margin({ left: 32 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 默认布局没有 MoreVert 菜单，但保留占位高度 (对齐 Android Box(Modifier.height(48.dp)))
        Column().width(48).height(48)
      }
      .width('100%')
      .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l'), right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
      .alignItems(VerticalAlign.Center)
      .height(56)
      .useEffect(true)
      .onClick(() => {
        SoundEffectManager.getInstance().play(SoundEffect.SELECT);
        this.onSetSelected(BUILTIN_DEFAULT_ID);
      })

      // 布局预览缩略图
      LayoutPreviewThumbnail({ layout: null, previewLongSide: 120, updateTrigger: this.refreshKey, overlayTheme: this.overlayTheme })
    }
    .width('100%')
  }

  /** 自定义布局列表项 (对齐 Android LayoutItem with type=CUSTOM) */

  @Builder
  LayoutListItem_Custom(layout: LayoutConfiguration) {
    Column() {
      Row() {
        Radio({ value: layout.id, group: 'layoutGroup' })
          .checked(this.selectedLayoutId === layout.id)
          .radioStyle({ checkedBackgroundColor: ThemeManager.getInstance().getControlAccent() })
          .onChange((isChecked: boolean) => {
            if (isChecked) {
              SoundEffectManager.getInstance().play(SoundEffect.SELECT);
              this.onSetSelected(layout.id);
            }
          })
          .width(20).height(20)

        Text(layout.name || I18n.t('unnamed_layout'))
          .fontSize($r("sys.float.ohos_id_text_size_body1")).fontColor($r("sys.color.ohos_id_color_text_primary"))
          .margin({ left: 32 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // MoreVert 菜单按钮 - 使用 bindMenu 对齐首页"启动固件"交互
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
            .fontSize(24)
            .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
        }
        .width($r('sys.float.sheet_close_icon_button_width')).height($r('sys.float.sheet_close_icon_button_width'))
        .backgroundColor(secondaryButtonBgOf(this.themeColors))
        .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
        .onFocus(() => { SoundEffectManager.getInstance().play(SoundEffect.FOCUS); })
        .onClick(() => { SoundEffectManager.getInstance().play(SoundEffect.DECIDE); })
        .bindMenu(this.LayoutItemMenuBuilder(layout), {
          placement: Placement.BottomRight,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
        })
      }
      .width('100%')
      .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l'), right: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
      .alignItems(VerticalAlign.Center)
      .height(56)
      .useEffect(true)
      .onClick(() => {
        SoundEffectManager.getInstance().play(SoundEffect.SELECT);
        this.onSetSelected(layout.id);
      })

      // 布局预览缩略图
      LayoutPreviewThumbnail({ layout: layout, previewLongSide: 120, updateTrigger: this.refreshKey, overlayTheme: this.overlayTheme })
    }
    .width('100%')
  }

  /** 自定义布局的更多操作菜单 - bindMenu 对齐首页"启动固件"交互 */
  @Builder
  LayoutItemMenuBuilder(layout: LayoutConfiguration) {
    Menu() {
      MenuItem({ content: I18n.t('edit') })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.onEdit(layout);
        })
      MenuItem({ content: I18n.t('delete') })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
          this.onDelete(layout);
        })
    }
    .fontColor($r("sys.color.ohos_id_color_text_primary"))
    .menuItemDivider(MENU_ITEM_DIVIDER)
  }

  // ============================================================================
  // 编辑器模式 UI (对齐 Android activity_layout_editor.xml + LayoutEditorManagerView)
  // ============================================================================

  build() {
    this.ListContent()
  }
}

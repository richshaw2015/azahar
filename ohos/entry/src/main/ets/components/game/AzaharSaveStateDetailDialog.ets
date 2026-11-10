import { AzaharSaveStateInfo, AzaharSaveStateStatus } from '../../types/AzaharNative';
import {
  RADIUS_SHEET,
  SETTING_ITEM_PADDING,
  SHEET_BG_GROUPED,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING,
  SURFACE_TRACK,
  TEXT_PRIMARY,
  TEXT_SECONDARY,
  TEXT_WARNING
} from '../../types/UIConstants';
import { I18n } from '../../utils/I18nManager';
import { formatSaveStateTime } from '../../utils/DateTimeFormatter';
import { formatFileSize } from '../../utils/FileSizeFormatter';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { immersiveMaterial } from '../common/AzaharControls';
import { SheetActionRow, SheetRowDivider, SheetTitleBar } from '../common/MultiplayerSheets';
import { ComposeListItem, IconType, SymbolGlyphModifier } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';

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

/** 存档详情底部弹窗内容（bindSheet 半模态，与联机/编辑器弹窗同套规范）：
 *  标题栏 + 截图预览卡（双屏完整拼接，底部信息条显示时间/大小）+ 操作白卡。
 *  状态行只在空槽/版本不匹配时提示，正常"可读取"状态不再单列。 */
@Component
export struct AzaharSaveStateDetailDialog {
  @Prop slot: number = 0;
  @Prop saveState: AzaharSaveStateInfo = {
    slot: 0,
    time: 0,
    status: AzaharSaveStateStatus.OK,
    buildName: '',
    fileSize: 0,
    screenshotPath: '',
    hasUndo: false
  };
  @Prop exists: boolean = false;

  onSave: (slot: number) => void = () => {};
  onLoad: (slot: number) => void = () => {};
  onDelete: (slot: number) => void = () => {};
  onUndo: (slot: number) => void = () => {};
  onDismiss: () => void = () => {};

  /** 截图解码失败后降级到占位提示，避免反复重建失败图片（对齐 nds） */
  @State screenshotLoadFailed: boolean = false;

  private hasUsableScreenshot(): boolean {
    return this.exists && this.saveState.screenshotPath.length > 0 && !this.screenshotLoadFailed;
  }

  private slotLabel(): string {
    // 快速槽（0）不进存档列表，详情弹窗只会拿到普通槽位
    return I18n.tf1('save_state_slot_fmt', 'slot', this.slot);
  }

  build() {
    Column() {
      SheetTitleBar(this.slotLabel(), () => {
        this.onDismiss();
      })

      // 截图预览卡：双屏左右拼接 3:1 横版，封面贴卡片边缘（与其他卡片内容贴边一致，圆角交给卡片 clip）；
      // 无截图仅浅色底 + 无预览提示（对齐 nds 占位语义）；封面下方接信息条（时间左 + 大小右，灰底容器）
      Column() {
        if (this.hasUsableScreenshot()) {
          Image(toImageUri(this.saveState.screenshotPath))
            .width('100%')
            .aspectRatio(3)
            .objectFit(ImageFit.Contain)
            .onError(() => {
              this.screenshotLoadFailed = true;
            })
        } else {
          Column() {
            Text(I18n.t('save_state_no_preview'))
              .fontSize($r('sys.float.ohos_id_text_size_body3'))
              .fontColor(TEXT_SECONDARY)
          }
          .width('100%')
          .aspectRatio(3)
          .backgroundColor(SURFACE_TRACK)
          .justifyContent(FlexAlign.Center)
        }
        if (this.exists) {
          Row() {
            Text(formatSaveStateTime(this.saveState.time))
              .fontSize($r('sys.float.ohos_id_text_size_body3'))
              .fontColor(TEXT_PRIMARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.saveState.fileSize > 0) {
              Text(formatFileSize(this.saveState.fileSize))
                .fontSize($r('sys.float.ohos_id_text_size_body3'))
                .fontColor(TEXT_SECONDARY)
                .maxLines(1)
            }
          }
          .width('100%')
          .padding(SETTING_ITEM_PADDING)
          .backgroundColor(SURFACE_TRACK)
        }
      }
      .width('100%')
      .backgroundColor(SHEET_CARD_BG)
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
      .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
      .clip(true)

      // 操作白卡：系统列表行（对齐编辑器菜单 sheet）；空槽/版本不匹配才提示，正常状态不显示
      Column() {
        if (!this.exists) {
          ComposeListItem({
            contentItem: {
              primaryText: I18n.t('save_state_empty_slot'),
              secondaryText: I18n.t('save_state_empty_desc')
            }
          })
          SheetRowDivider()
        } else if (this.saveState.status !== AzaharSaveStateStatus.OK) {
          ComposeListItem({
            contentItem: {
              iconStyle: IconType.SYSTEM_ICON,
              symbolStyle: new SymbolGlyphModifier($r('sys.symbol.exclamationmark_triangle')).fontColor([TEXT_WARNING]),
              primaryText: I18n.t('save_state_revision_mismatch')
            }
          })
          SheetRowDivider()
        }
        SheetActionRow($r('sys.symbol.save'), I18n.t('save_to_this_slot'), false, () => {
          this.onSave(this.slot);
        })
        if (this.exists) {
          SheetRowDivider()
          SheetActionRow($r('sys.symbol.upload'), I18n.t('load_this_slot'), false, () => {
            this.onLoad(this.slot);
          })
          // 覆盖前有旧档内存留底才可撤销（一次性：恢复后备份即失效）
          if (this.saveState.hasUndo) {
            SheetRowDivider()
            SheetActionRow($r('sys.symbol.arrow_counterclockwise'), I18n.t('undo_overwrite'), false, () => {
              this.onUndo(this.slot);
            })
          }
          SheetRowDivider()
          SheetActionRow($r('sys.symbol.trash'), I18n.t('delete_state'), true, () => {
            this.onDelete(this.slot);
          })
        }
      }
      .width('100%')
      .margin({ top: $r('sys.float.ohos_id_card_margin_middle') })
      .backgroundColor(SHEET_CARD_BG)
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
      .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
      .clip(true)
    }
    .width('100%')
    .padding(SHEET_CONTENT_PADDING)
    .backgroundColor(SHEET_BG_GROUPED)
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }
}

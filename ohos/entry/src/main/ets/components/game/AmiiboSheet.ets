import { ComposeListItem } from '@kit.ArkUI';
import uiMaterial from '@ohos.arkui.uiMaterial';
import {
  INPUT_HEIGHT,
  RADIUS_SHEET,
  SHEET_BG_GROUPED,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING,
  TEXT_PRIMARY
} from '../../types/UIConstants';
import { AzaharNative } from '../../types/AzaharNative';
import { I18n } from '../../utils/I18nManager';
import { showErrorToast, showSuccessToast } from '../../utils/ToastHelper';
import { DownloadDirManager } from '../../utils/DownloadDirManager';
import { immersiveMaterial } from '../common/AzaharControls';
import { SheetRowDivider, SheetTitleBar } from '../common/MultiplayerSheets';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';

/** Amiibo 底部弹窗（对齐 Android 暂停菜单 Amiibo 二级菜单，入口样式与 MultiplayerSheets 一致）：
 *  加载 .bin（系统文件选择器）/ 按 ID 生成 / 移除 三个入口；父组件把 showAmiiboSheet 置 true 即弹出。 */
@Component
export struct AmiiboSheet {
  /** 弹窗开关：父组件绑定的状态，置 true 弹出 */
  @Link showAmiiboSheet: boolean;
  onLoad: () => void = () => {};
  onRemove: () => void = () => {};

  @State private showGenerateSheet: boolean = false;
  @State private amiiboId: string = '';

  private openLoad(): void {
    SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
    this.showAmiiboSheet = false;
    this.onLoad();
  }

  private openGenerate(): void {
    SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
    this.showGenerateSheet = true;
  }

  private openRemove(): void {
    SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
    this.showAmiiboSheet = false;
    this.onRemove();
  }

  private generateAmiibo(): void {
    const id = this.amiiboId.trim().replace(/^@/, '');
    if (!/^[0-9A-Fa-f]{16}$/.test(id)) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('amiibo_generate_bad_id'));
      return;
    }
    const dir = DownloadDirManager.getInstance().getDownloadDirPath() + '/amiibo';
    const path = `${dir}/generated_${id}.bin`;
    if (!AzaharNative.makeAmiiboFile('@' + id, path)) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('amiibo_generate_failed'));
      return;
    }
    if (!AzaharNative.loadAmiibo(path)) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('amiibo_generate_failed'));
      return;
    }
    SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
    showSuccessToast(I18n.t('amiibo_generate_done'));
    this.amiiboId = '';
    this.showGenerateSheet = false;
    this.showAmiiboSheet = false;
  }

  @Builder
  GenerateSheet() {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_l') }) {
      SheetTitleBar(I18n.t('amiibo_generate'), () => {
        this.showGenerateSheet = false;
      })
      TextInput({ placeholder: I18n.t('amiibo_generate_desc'), text: $$this.amiiboId })
        .fontSize($r('sys.float.ohos_id_text_size_body1'))
        .fontColor(TEXT_PRIMARY)
        .width('100%')
        .height(INPUT_HEIGHT)
      Button(I18n.t('amiibo_generate'), { type: ButtonType.Capsule })
        .fontSize($r('sys.float.ohos_id_text_size_button1'))
        .width('100%')
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
          this.generateAmiibo();
        })
    }
    .width('100%')
    .padding(SHEET_CONTENT_PADDING)
    .backgroundColor(SHEET_BG_GROUPED)
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  @Builder
  AmiiboEntrySheet() {
    Column() {
      SheetTitleBar(I18n.t('amiibo'), () => {
        this.showAmiiboSheet = false;
      })
      Column({ space: 0 }) {
        ComposeListItem({
          contentItem: { primaryText: I18n.t('amiibo_load_file') },
          operateItem: { arrow: { value: $r('sys.symbol.chevron_right'), action: () => { this.openLoad(); } } }
        })
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          this.openLoad();
        })
        SheetRowDivider()
        ComposeListItem({
          contentItem: { primaryText: I18n.t('amiibo_generate') },
          operateItem: { arrow: { value: $r('sys.symbol.chevron_right'), action: () => { this.openGenerate(); } } }
        })
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          this.openGenerate();
        })
        SheetRowDivider()
        ComposeListItem({
          contentItem: { primaryText: I18n.t('amiibo_remove') },
          operateItem: { arrow: { value: $r('sys.symbol.chevron_right'), action: () => { this.openRemove(); } } }
        })
        .onFocus(() => {
          SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          this.openRemove();
        })
      }
      .width('100%')
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

  build() {
    Column() {
      Column()
        .bindSheet($$this.showAmiiboSheet, this.AmiiboEntrySheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
        })
      Column()
        .bindSheet($$this.showGenerateSheet, this.GenerateSheet(), {
          height: SheetSize.FIT_CONTENT,
          showClose: false,
          systemMaterial: immersiveMaterial(uiMaterial.ImmersiveStyle.THICK)
        })
    }
    .width(0)
    .height(0)
  }
}

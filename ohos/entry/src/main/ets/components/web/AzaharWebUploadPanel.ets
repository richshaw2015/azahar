import { FileManagerHelper } from '../../utils/FileManagerHelper';
import { formatFileSize } from '../../utils/FileSizeFormatter';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { showErrorToast, showSuccessToast } from '../../utils/ToastHelper';
import { ServerInfo, ServerStatus, UploadProgress, WebUploadServer } from '../../utils/WebUploadServer';
import { DownloadDirManager } from '../../utils/DownloadDirManager';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { ComposeListItem, IconType, SymbolGlyphModifier } from '@kit.ArkUI';
import {
  BUTTON_BG_SECONDARY,
  FONT_SIZE_SETTING_DESC,
  FONT_SIZE_SETTING_TITLE,
  ICON_SIZE_ROW,
  OPACITY_DISABLED,
  RADIUS_SHEET,
  SHEET_BG_GROUPED,
  SHEET_CARD_BG,
  SHEET_CONTENT_PADDING,
  TEXT_DANGER,
  TEXT_ON_ACCENT,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';
import { AzaharThemeColors } from '../../types/ThemeTypes';
import { ThemeManager } from '../../utils/ThemeManager';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { controlAccentOf, immersiveMaterial } from '../common/AzaharControls';
import { inputBgOf } from '../../utils/ThemeSurfaces';

@Component
export struct AzaharWebUploadPanel {
  @Prop uploadPath: string = '';
  @Prop themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();

  onDismiss: () => void = () => {};
  onUploadComplete: () => void = () => {};

  @State private serverInfo: ServerInfo = WebUploadServer.getInstance().getServerInfo();
  @State private errorMessage: string = '';
  @State private progressItems: UploadProgress[] = [];
  @State private copied: boolean = false;

  private uploadServer: WebUploadServer = WebUploadServer.getInstance();
  private statusListener: ((info: ServerInfo) => void) | null = null;
  private uploadCompleteListener: ((filename: string, size: number) => void) | null = null;
  private progressTimer: number = 0;

  aboutToAppear(): void {
    this.serverInfo = this.uploadServer.getServerInfo();
    this.statusListener = (info: ServerInfo) => {
      this.serverInfo = info;
    };
    this.uploadServer.addStatusListener(this.statusListener);
    this.uploadCompleteListener = (filename: string, size: number) => {
      SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
      showSuccessToast(I18n.tf2('uploaded_file_fmt', 'name', filename, 'size', formatFileSize(size)));
      this.onUploadComplete();
    };
    this.uploadServer.addUploadCompleteListener(this.uploadCompleteListener);
    this.startProgressPolling();
    if (this.serverInfo.status !== ServerStatus.RUNNING && this.uploadPath.length > 0) {
      this.startServer();
    }
  }

  aboutToDisappear(): void {
    if (this.statusListener) {
      this.uploadServer.removeStatusListener(this.statusListener);
      this.statusListener = null;
    }
    if (this.uploadCompleteListener) {
      this.uploadServer.removeUploadCompleteListener(this.uploadCompleteListener);
      this.uploadCompleteListener = null;
    }
    if (this.progressTimer) {
      clearInterval(this.progressTimer);
      this.progressTimer = 0;
    }
  }

  private startProgressPolling(): void {
    this.progressItems = this.uploadServer.getUploadProgress();
    if (this.progressTimer) {
      clearInterval(this.progressTimer);
    }
    this.progressTimer = setInterval(() => {
      this.progressItems = this.uploadServer.getUploadProgress();
    }, 500);
  }

  private async startServer(): Promise<void> {
    if (!this.uploadPath) {
      this.errorMessage = I18n.t('download_dir_not_set');
      return;
    }
    this.errorMessage = '';
    const started = await this.uploadServer.start(this.uploadPath);
    this.serverInfo = this.uploadServer.getServerInfo();
    if (!started) {
      this.errorMessage = I18n.t('web_upload_start_failed');
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(this.errorMessage);
    }
  }

  private async stopServer(): Promise<void> {
    await this.uploadServer.stop();
    this.serverInfo = this.uploadServer.getServerInfo();
  }

  private serverUrl(): string {
    if (this.serverInfo.status !== ServerStatus.RUNNING || !this.serverInfo.localIp) {
      return '';
    }
    return `http://${this.serverInfo.localIp}:${this.serverInfo.port}/`;
  }

  private statusText(): string {
    if (this.serverInfo.status === ServerStatus.RUNNING) {
      return I18n.t('running');
    }
    if (this.serverInfo.status === ServerStatus.STARTING) {
      return I18n.t('starting');
    }
    if (this.serverInfo.status === ServerStatus.STOPPING) {
      return I18n.t('stopping');
    }
    return I18n.t('stopped');
  }

  private statusColor(): ResourceColor {
    if (this.serverInfo.status === ServerStatus.RUNNING) {
      return this.themeColors.controlAccent ?? this.themeColors.accent;
    }
    if (this.errorMessage) {
      return TEXT_DANGER;
    }
    return TEXT_SECONDARY;
  }

  private isBusy(): boolean {
    return this.serverInfo.status === ServerStatus.STARTING || this.serverInfo.status === ServerStatus.STOPPING;
  }

  private copyServerUrl(): void {
    const url = this.serverUrl();
    if (!url) {
      return;
    }
    const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(pasteData).then(() => {
      this.copied = true;
      showSuccessToast(I18n.t('web_upload_url_copied'));
      setTimeout(() => {
        this.copied = false;
      }, 2000);
    }).catch((error: Error) => {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(error.message);
    });
  }

  private async openUploadDir(): Promise<void> {
    if (!this.uploadPath) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(I18n.t('upload_dir_not_set'));
      return;
    }
    // 优先用已授权的下载目录 URI 拼出 roms 子目录，没有再退回路径
    const downloadDirUri = DownloadDirManager.getInstance().getDownloadDirUri();
    const target = downloadDirUri
      ? `${downloadDirUri.endsWith('/') ? downloadDirUri.slice(0, -1) : downloadDirUri}/roms`
      : this.uploadPath;
    const context = getContext(this) as common.UIAbilityContext;
    const result = await FileManagerHelper.getInstance().openFolder(context, target);
    if (!result.success) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(result.message);
    }
  }

  build() {
    Column({ space: $r('sys.float.ohos_id_card_margin_middle') }) {
      this.Header()
      this.StatusCard()
      this.DirectoryCard()
      this.ProgressCard()
      this.ActionButton()
    }
    .width('100%')
    .padding(SHEET_CONTENT_PADDING)
    .backgroundColor(SHEET_BG_GROUPED)
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  @Builder
  private Header() {
    Row() {
      Text(I18n.t('web_upload'))
        .fontSize($r('sys.float.ohos_id_text_size_headline8'))
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_PRIMARY)
        .layoutWeight(1)

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
        this.onDismiss();
      })
    }
    .width('100%')
  }

  // 服务状态卡：状态行 → 按状态展示访问地址 / 加载 / 错误 / 待启动说明
  @Builder
  private StatusCard() {
    Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_l') }) {
      Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
        SymbolGlyph($r('sys.symbol.wifi'))
          .fontSize(ICON_SIZE_ROW)
          .fontColor([this.statusColor()])
        Text(this.statusText())
          .fontSize(FONT_SIZE_SETTING_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.statusColor())
          .layoutWeight(1)
        if (this.isBusy()) {
          LoadingProgress()
            .width(ICON_SIZE_ROW)
            .height(ICON_SIZE_ROW)
            .color(controlAccentOf(this.themeColors))
        }
      }
      .width('100%')

      if (this.serverInfo.status === ServerStatus.RUNNING) {
        Text(I18n.t('web_upload_browser_hint'))
          .fontSize(FONT_SIZE_SETTING_DESC)
          .fontColor(TEXT_SECONDARY)
          .width('100%')

        // 访问地址：整行可点击复制
        Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
          Text(this.serverUrl())
            .fontSize($r('sys.float.ohos_id_text_size_body1'))
            .fontWeight(FontWeight.Medium)
            .fontFamily('monospace')
            .fontColor(controlAccentOf(this.themeColors))
            .wordBreak(WordBreak.BREAK_ALL)
            .layoutWeight(1)
          SymbolGlyph(this.copied ? $r('sys.symbol.checkmark') : $r('sys.symbol.doc_filled_on_doc'))
            .fontSize(ICON_SIZE_ROW)
            .fontColor([controlAccentOf(this.themeColors)])
        }
        .width('100%')
        .padding({ left: $r('sys.float.ohos_id_card_margin_middle'), right: $r('sys.float.ohos_id_card_margin_middle'), top: $r('sys.float.ohos_id_elements_margin_vertical_l'), bottom: $r('sys.float.ohos_id_elements_margin_vertical_l') })
        .backgroundColor(inputBgOf(this.themeColors))
        .borderRadius($r('sys.float.ohos_id_corner_radius_default_m'))
        .accessibilityText(I18n.t('web_upload_tap_to_copy'))
        .useEffect(true)
        .onClick(() => {
          SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
          this.copyServerUrl();
        })

        Text(I18n.t('web_upload_running_desc'))
          .fontSize(FONT_SIZE_SETTING_DESC)
          .fontColor(TEXT_SECONDARY)
          .width('100%')
      } else if (!this.isBusy()) {
        Text(this.errorMessage ? this.errorMessage : I18n.t('web_upload_idle_desc'))
          .fontSize(FONT_SIZE_SETTING_DESC)
          .fontColor(this.errorMessage ? TEXT_DANGER : TEXT_SECONDARY)
          .width('100%')
      }
    }
    .width('100%')
    .padding($r('sys.float.ohos_id_card_margin_middle'))
    .backgroundColor(SHEET_CARD_BG)
    .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
    .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
  }

  // 上传目录：列表行样式，点击打开目录——ComposeListItem 包卡片容器，自带按压/长按高亮
  @Builder
  private DirectoryCard() {
    Column() {
      ComposeListItem({
        contentItem: {
          iconStyle: IconType.SYSTEM_ICON,
          icon: $r('sys.symbol.folder'),
          symbolStyle: new SymbolGlyphModifier($r('sys.symbol.folder')),
          primaryText: I18n.t('web_upload_dir_title'),
          secondaryText: this.uploadPath ? FileManagerHelper.getDisplayPath(this.uploadPath) : I18n.t('upload_dir_not_set')
        },
        operateItem: {
          arrow: {
            value: $r('sys.symbol.chevron_right')
          }
        }
      })
      .enabled(this.uploadPath.length > 0)
      .opacity(this.uploadPath.length > 0 ? 1 : OPACITY_DISABLED)
      .onFocus(() => {
        SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
      })
      .onClick(() => {
        SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
        this.openUploadDir();
      })
    }
    .width('100%')
    .backgroundColor(SHEET_CARD_BG)
    .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
    .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
    .clip(true)
  }

  // 上传进度：单卡分组，行间发丝分隔线
  @Builder
  private ProgressCard() {
    if (this.progressItems.length > 0) {
      Column() {
        ForEach(this.progressItems, (progressEntry: UploadProgress, index: number) => {
          if (index > 0) {
            Divider()
              .color($r('sys.color.ohos_id_color_list_separator'))
              .strokeWidth('1px')
          }
          this.ProgressItem(index)
        }, (item: UploadProgress) => item.filename)
      }
      .width('100%')
      .padding({ left: $r('sys.float.ohos_id_card_margin_middle'), right: $r('sys.float.ohos_id_card_margin_middle') })
      .backgroundColor(SHEET_CARD_BG)
      .systemMaterial(immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
      .borderRadius($r('sys.float.ohos_id_corner_radius_card'))
    }
  }

  @Builder
  private ProgressItem(itemIndex: number) {
    if (itemIndex < this.progressItems.length) {
      Column({ space: $r('sys.float.ohos_id_elements_margin_vertical_m') }) {
        Row({ space: $r('sys.float.ohos_id_elements_margin_horizontal_m') }) {
          Text(this.progressItems[itemIndex].filename)
            .fontSize(FONT_SIZE_SETTING_TITLE)
            .fontColor(TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(`${formatFileSize(this.progressItems[itemIndex].uploadedBytes)} / ${formatFileSize(this.progressItems[itemIndex].totalBytes)}`)
            .fontSize(FONT_SIZE_SETTING_DESC)
            .fontColor(TEXT_SECONDARY)
        }
        .width('100%')
        Progress({
          value: this.progressItems[itemIndex].uploadedBytes,
          total: Math.max(1, this.progressItems[itemIndex].totalBytes),
          type: ProgressType.Linear
        })
          .color(controlAccentOf(this.themeColors))
          .width('100%')
      }
      .width('100%')
      .padding({ top: $r('sys.float.ohos_id_elements_margin_vertical_l'), bottom: $r('sys.float.ohos_id_elements_margin_vertical_l') })
    }
  }

  // 主操作：运行中=停止，启动失败=重试，其余=启动；统一主题强调色
  @Builder
  private ActionButton() {
    Button(this.serverInfo.status === ServerStatus.RUNNING
      ? I18n.t('stop')
      : (this.errorMessage ? I18n.t('retry') : I18n.t('start')))
      .type(ButtonType.Capsule)
      .width('100%')
      .height($r('sys.float.ohos_id_button_height'))
      .buttonStyle(ButtonStyleMode.EMPHASIZED)
      .fontColor(TEXT_ON_ACCENT)
      .backgroundColor(controlAccentOf(this.themeColors))
      .fontSize($r('sys.float.ohos_id_text_size_button1'))
      .enabled(!this.isBusy())
      .onFocus(() => {
        SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
      })
      .onClick(() => {
        SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
        if (this.serverInfo.status === ServerStatus.RUNNING) {
          this.stopServer();
        } else {
          this.startServer();
        }
      })
  }
}

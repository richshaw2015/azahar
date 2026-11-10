import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ComposeListItem } from '@kit.ArkUI';
import {
  OPACITY_DISABLED
} from '../../types/UIConstants';
import { DownloadDirManager } from '../../utils/DownloadDirManager';
import { FileManagerHelper, OpenFolderResult } from '../../utils/FileManagerHelper';
import { I18n } from '../../utils/I18nManager';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { showErrorToast, showInfoToast, showWarningToast } from '../../utils/ToastHelper';

@Component
export struct DirectoryPickerItem {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop currentPath: string = '';
  @Prop subDirectory: string = '';
  @Prop disabled: boolean = false;
  @Prop requiresRestart: boolean = false;
  @Prop fileSuffixes: string[] = [];
  onSelect: (path: string) => void = () => {};

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private downloadDirManager: DownloadDirManager = DownloadDirManager.getInstance();
  private fileManagerHelper: FileManagerHelper = FileManagerHelper.getInstance();

  build() {
    ComposeListItem({
      contentItem: {
        icon: $r('sys.symbol.folder'),
        primaryText: this.requiresRestart ? `${this.title} *` : this.title,
        secondaryText: this.description.length > 0
          ? `${this.description}\n${this.displayPath()}`
          : this.displayPath()
      },
      operateItem: {
        arrow: {
          value: $r('sys.symbol.chevron_right')
        }
      }
    })
    .opacity(this.disabled ? OPACITY_DISABLED : 1.0)
    .enabled(!this.disabled)
    .onFocus(() => {
      SoundEffectManager.getInstance().play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      if (!this.disabled) {
        SoundEffectManager.getInstance().play(SoundEffect.DECIDE);
        this.openDirectory();
      }
    })
  }

  private async openDirectory(): Promise<void> {
    await this.downloadDirManager.initialize(this.context);
    let rootPath = this.downloadDirManager.getDownloadDirPath();
    if (!rootPath) {
      rootPath = await this.downloadDirManager.initDownloadDirectory();
    }
    if (!rootPath) {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showWarningToast(I18n.t('download_dir_not_set_short'));
      return;
    }

    const targetPath = this.targetPath(rootPath);
    this.ensureDirectory(targetPath);
    const targetUri = this.targetUri(this.downloadDirManager.getDownloadDirUri(), targetPath);
    const result: OpenFolderResult = await this.fileManagerHelper.selectFileInFolder(
      this.context,
      targetUri,
      this.fileSuffixes
    );

    if (result.selectedUri) {
      const selectedPath = FileManagerHelper.pathFromUri(result.selectedUri);
      const selectedDir = this.parentDir(selectedPath);
      if (!this.isInsideDownloadDir(rootPath, selectedDir)) {
        SoundEffectManager.getInstance().play(SoundEffect.FAIL);
        showWarningToast(I18n.t('select_file_in_download'));
        return;
      }
      this.onSelect(selectedDir);
      return;
    }

    if (result.success) {
      this.onSelect(targetPath);
      SoundEffectManager.getInstance().play(SoundEffect.CONFIRM);
      showInfoToast(result.message);
    } else {
      SoundEffectManager.getInstance().play(SoundEffect.FAIL);
      showErrorToast(result.message);
    }
  }

  private displayPath(): string {
    if (this.currentPath) {
      return FileManagerHelper.getDisplayPath(this.currentPath);
    }
    if (this.subDirectory) {
      return `~/Download/${this.subDirectory}`;
    }
    return '~/Download';
  }

  private targetPath(rootPath: string): string {
    if (this.currentPath) {
      return this.currentPath;
    }
    if (!this.subDirectory) {
      return rootPath;
    }
    return `${rootPath}/${this.normalizeSubDirectory(this.subDirectory)}`;
  }

  private targetUri(rootUri: string, targetPath: string): string {
    if (!rootUri || !this.subDirectory) {
      return targetPath;
    }
    const base = rootUri.endsWith('/') ? rootUri.slice(0, -1) : rootUri;
    return `${base}/${this.normalizeSubDirectory(this.subDirectory)}`;
  }

  private normalizeSubDirectory(path: string): string {
    return path.split('/').filter((part: string) => part.length > 0).join('/');
  }

  private ensureDirectory(path: string): void {
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
    } catch (_error) {
      try {
        fileIo.mkdirSync(path, true);
      } catch (error) {
        console.error(`DirectoryPickerItem mkdir failed: ${(error as Error).message}`);
      }
    }
  }

  private parentDir(path: string): string {
    const index = path.lastIndexOf('/');
    if (index <= 0) {
      return path;
    }
    return path.substring(0, index);
  }

  private isInsideDownloadDir(rootPath: string, path: string): boolean {
    return path === rootPath || path.startsWith(`${rootPath}/`);
  }
}

import { ComposeListItem, SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { ToggleSettingItem } from '../ToggleSettingItem';
import { DeviceProfile } from '../../../utils/DeviceProfile';
import { I18n } from '../../../utils/I18nManager';
import { SettingsManager } from '../../../utils/SettingsManager';
import { AzaharNative } from '../../../types/AzaharNative';

import { KEY_ASYNC_FS_OPERATIONS, KEY_COMPRESS_CIA_INSTALLS } from '../../../types/SettingsTypes';
import { DownloadDirManager } from '../../../utils/DownloadDirManager';
import { FileManagerHelper } from '../../../utils/FileManagerHelper';
import { GameManager } from '../../../utils/GameManager';
import { SoundEffect, SoundEffectManager } from '../../../utils/SoundEffectManager';
import { showSuccessToast, showWarningToast } from '../../../utils/ToastHelper';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { AzaharThemeColors } from '../../../types/ThemeTypes';

interface DirectoryItem {
  title: string;
  description: string;
  relativePath: string;
  status: string;
  /** 点行时随父目录一并预建的子目录（核心按需创建的完整结构先铺好） */
  subdirs?: string[];
}

@Component
export struct StorageSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  @State compressCiaInstalls: boolean = false;
  @State asyncFsOperations: boolean = true;
  @State private downloadDirPath: string = '';
  @State private downloadDirUri: string = '';
  @State private isInitializing: boolean = false;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private deviceType: string = 'phone';
  private downloadDirManager: DownloadDirManager = DownloadDirManager.getInstance();
  private gameManager: GameManager = GameManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();

  async aboutToAppear(): Promise<void> {
    FileManagerHelper.initAppName(this.context);
    await this.settingsManager.initialize(this.context);
    await this.downloadDirManager.initialize(this.context);
    await this.gameManager.initialize(this.context);
    this.deviceType = DeviceProfile.getDeviceType();
    this.loadSettings();
    this.downloadDirPath = this.downloadDirManager.getDownloadDirPath();
    this.downloadDirUri = this.downloadDirManager.getDownloadDirUri();
    if (this.downloadDirPath) {
      this.gameManager.ensureLibraryDirectories(this.downloadDirPath);
    }
  }

  private loadSettings(): void {
    this.compressCiaInstalls = this.settingsManager.getBoolean(KEY_COMPRESS_CIA_INSTALLS);
    this.asyncFsOperations = this.settingsManager.getBoolean(KEY_ASYNC_FS_OPERATIONS);
  }

  private async updateBoolean(key: string, value: boolean): Promise<void> {
    await this.settingsManager.setBoolean(key, value);
    AzaharNative.applyConfig();
  }

  private getDirectories(): DirectoryItem[] {
    return [
      { title: I18n.t('dir_download_root'), description: I18n.t('dir_download_root_desc'), relativePath: '', status: I18n.t('dir_status_root') },
      { title: I18n.t('dir_rom_library'), description: I18n.t('dir_rom_library_desc'), relativePath: 'roms', status: I18n.t('dir_status_scan') },
      { title: I18n.t('sdmc'), description: I18n.t('dir_sdmc_desc'), relativePath: 'sdmc', status: I18n.t('dir_status_system') },
      { title: I18n.t('nand'), description: I18n.t('dir_nand_desc'), relativePath: 'nand', status: I18n.t('dir_status_system') },
      { title: I18n.t('dir_save_states'), description: I18n.t('dir_save_states_desc'), relativePath: 'states', status: I18n.t('dir_status_state') },
      { title: I18n.t('covers'), description: I18n.t('dir_covers_desc'), relativePath: 'covers', status: I18n.t('dir_status_media') },
      { title: I18n.t('cheats'), description: I18n.t('dir_cheats_desc'), relativePath: 'cheats', status: I18n.t('dir_status_cheat') },
      { title: I18n.t('dir_load'), description: I18n.t('dir_load_desc'), relativePath: 'load', status: I18n.t('mods'), subdirs: ['textures', 'mods'] },
      { title: I18n.t('dir_dump'), description: I18n.t('dir_dump_desc'), relativePath: 'dump', status: I18n.t('dir_status_export'), subdirs: ['romfs', 'textures'] },
    ];
  }

  private getFullPath(relativePath: string): string {
    if (!this.downloadDirPath) {
      return '';
    }
    if (!relativePath) {
      return this.downloadDirPath;
    }
    return `${this.downloadDirPath}/${relativePath}`;
  }

  private getDirectoryUri(relativePath: string): string {
    if (!this.downloadDirUri) {
      return '';
    }
    const base = this.downloadDirUri.endsWith('/') ? this.downloadDirUri.slice(0, -1) : this.downloadDirUri;
    return relativePath ? `${base}/${relativePath}` : base;
  }

  private ensureDirectory(path: string): void {
    if (!path) {
      return;
    }
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
    } catch (_error) {
      try {
        fileIo.mkdirSync(path, true);
      } catch (_mkdirError) {
        console.warn(`StorageSettings: mkdir failed: ${(_mkdirError as Error)?.message}`);
      }
    }
  }

  private async openDirectory(item: DirectoryItem): Promise<void> {
    if (!this.downloadDirPath) {
      await this.initializeDownloadDir();
    }
    if (!this.downloadDirPath) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('download_dir_not_set_short'));
      return;
    }

    const targetPath = this.getFullPath(item.relativePath);
    this.ensureDirectory(targetPath);
    item.subdirs?.forEach((sub: string) => this.ensureDirectory(`${targetPath}/${sub}`));
    const result = await FileManagerHelper.getInstance().openFolder(
      this.context,
      this.getDirectoryUri(item.relativePath) || targetPath
    );
    if (!result.success) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(result.message);
    }
  }

  private async initializeDownloadDir(): Promise<void> {
    if (this.isInitializing) {
      return;
    }
    this.isInitializing = true;
    try {
      const path = await this.downloadDirManager.initDownloadDirectory();
      if (!path) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showWarningToast(I18n.t('download_dir_not_set_short'));
        return;
      }
      this.downloadDirPath = path;
      this.downloadDirUri = this.downloadDirManager.getDownloadDirUri();
      this.gameManager.ensureLibraryDirectories(path);
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      showSuccessToast(I18n.t('download_dir_initialized'));
    } finally {
      this.isInitializing = false;
    }
  }

  @Builder
  SectionHeader(title: string) {
    SettingsSectionHeader({ title })
  }

  @Builder
  DirectoryRow(item: DirectoryItem) {
    ComposeListItem({
      contentItem: {
        icon: $r('sys.symbol.folder'),
        symbolStyle: new SymbolGlyphModifier($r('sys.symbol.folder')),
        primaryText: item.title,
        secondaryText: item.description,
      },
      operateItem: {
        text: item.relativePath || FileManagerHelper.getDisplayPath(this.downloadDirPath),
        arrow: {
          value: $r('sys.symbol.chevron_right')
        }
      }
    })
    .onFocus(() => {
      this.soundEffectManager.play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      this.soundEffectManager.play(SoundEffect.DECIDE);
      this.openDirectory(item);
    })
  }

  build() {
    SettingsList({ scroller: this.scroller }) {
      ListItem() {
        this.SectionHeader(I18n.t('settings_storage'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_compress_cia_installs'),
          description: I18n.t('settings_compress_cia_installs_desc'),
          isOn: this.compressCiaInstalls,
          onToggle: (value: boolean) => {
            this.compressCiaInstalls = value;
            this.updateBoolean(KEY_COMPRESS_CIA_INSTALLS, value);
          }
        })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_async_fs_operations'),
          description: I18n.t('settings_async_fs_operations_desc'),
          isOn: this.asyncFsOperations,
          onToggle: (value: boolean) => {
            this.asyncFsOperations = value;
            this.updateBoolean(KEY_ASYNC_FS_OPERATIONS, value);
          }
        })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())

      .margin(menuGroupMargin())
      ListItem() {
        this.SectionHeader(I18n.t('directory'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ForEach(this.getDirectories(), (item: DirectoryItem) => {
          ListItem() {
            this.DirectoryRow(item)
          }
        }, (item: DirectoryItem) => item.relativePath || '__root__')
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

    }
  }
}

import { ComposeListItem, router, SymbolGlyphModifier } from '@kit.ArkUI';
import { AzaharNavPage } from '../../components/common/AzaharNavPage';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../../components/settings/SettingsList';
import { ToggleSettingItem } from '../../components/settings/ToggleSettingItem';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { GlobalWallpaper } from '../../components/common/GlobalWallpaper';
import { FloatTilesBackground } from '../../components/theme/FloatTilesBackground';
import { AzaharNative, AzaharSystemFilesStatus } from '../../types/AzaharNative';
import { AzaharTheme, AzaharThemeColors } from '../../types/ThemeTypes';
import {
  TEXT_DANGER,
  TEXT_PRIMARY,
  TEXT_SECONDARY
} from '../../types/UIConstants';
import { DownloadDirManager } from '../../utils/DownloadDirManager';
import { FileManagerHelper } from '../../utils/FileManagerHelper';
import { GameManager } from '../../utils/GameManager';
import { gamepadBackHandler } from '../../utils/GamepadUIHelper';
import { I18n } from '../../utils/I18nManager';
import { PAGE_TRANSITION_DURATION } from '../../utils/PageTransitionHelper';
import { SoundEffect, SoundEffectManager } from '../../utils/SoundEffectManager';
import { ThemeManager } from '../../utils/ThemeManager';
import { initToastHelper, showErrorToast, showSuccessToast, showWarningToast } from '../../utils/ToastHelper';
import { listCardBgOf } from '../../utils/ThemeSurfaces';

interface SystemDirectoryItem {
  title: string;
  description: string;
  relativePath: string;
  badge: string;
}

@Entry
@Component
struct SystemFilesSettings {
  @State private downloadDirPath: string = '';
  @State private downloadDirUri: string = '';
  @State private fullConsoleLinked: boolean = false;
  @State private systemFilesStatus: AzaharSystemFilesStatus = { old3dsInstalled: false, new3dsInstalled: false };
  @State private systemSetupNeeded: boolean = false;
  @State private systemProfileAvailable: boolean = false;
  @State private isRefreshing: boolean = false;
  @State private isInitializing: boolean = false;
  @State private themeColors: AzaharThemeColors = ThemeManager.getInstance().getCurrentColors();
  @StorageLink('globalWallpaperUri') globalWallpaperUri: string = '';
  @StorageLink('safeAreaBottomVp') safeAreaBottomVp: number = 0;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private pageScroller: Scroller = new Scroller();
  private downloadDirManager: DownloadDirManager = DownloadDirManager.getInstance();
  private gameManager: GameManager = GameManager.getInstance();
  private themeManager: ThemeManager = ThemeManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private themeChangeListener: ((theme: AzaharTheme) => void) | null = null;

  private zipPassExport(): void {
    const path = this.downloadDirPath + '/azahar.pass.zip';
    const ret = AzaharNative.zipPassExport(path);
    if (ret > 0) {
      this.soundEffectManager.play(SoundEffect.CONFIRM);
      showSuccessToast(I18n.tf2('zippass_export_done_fmt', 'count', ret, 'path', path));
    } else if (ret === 0) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('zippass_export_empty'));
    } else {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('zippass_failed_fmt', 'code', ret));
    }
  }

  private zipPassImport(): void {
    const documentPicker = new picker.DocumentViewPicker(this.context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    documentPicker.select(options).then((uris: Array<string>) => {
      if (!uris || uris.length === 0) {
        return;
      }
      const path = FileManagerHelper.pathFromUri(uris[0]);
      if (!path) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.tf1('zippass_failed_fmt', 'code', -1));
        return;
      }
      const ret = AzaharNative.zipPassImport(path);
      if (ret >= 0) {
        this.soundEffectManager.play(SoundEffect.CONFIRM);
        showSuccessToast(I18n.tf1('zippass_import_done_fmt', 'count', ret));
      } else if (ret === -2) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('zippass_import_no_system_files'));
      } else if (ret === -3) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('zippass_import_no_lle'));
      } else {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.tf1('zippass_failed_fmt', 'code', ret));
      }
    });
  }

  async aboutToAppear(): Promise<void> {
    initToastHelper(this.getUIContext());
    await this.soundEffectManager.initialize(this.context);
    await this.initializePage();
  }

  aboutToDisappear(): void {
    if (this.themeChangeListener) {
      this.themeManager.removeListener(this.themeChangeListener);
      this.themeChangeListener = null;
    }
  }

  private async initializePage(): Promise<void> {
    FileManagerHelper.initAppName(this.context);
    await this.themeManager.initialize(this.context);
    await this.downloadDirManager.initialize(this.context);
    await this.gameManager.initialize(this.context);
    this.themeColors = this.themeManager.getCurrentColors();
    this.themeChangeListener = (_theme: AzaharTheme) => {
      this.themeColors = this.themeManager.getCurrentColors();
    };
    this.themeManager.addListener(this.themeChangeListener);
    this.downloadDirPath = this.downloadDirManager.getDownloadDirPath();
    this.downloadDirUri = this.downloadDirManager.getDownloadDirUri();
    if (this.downloadDirPath) {
      this.gameManager.ensureLibraryDirectories(this.downloadDirPath);
    }
    this.refreshConsoleLinkState();
    this.refreshSystemFilesStatus();
    try {
      const profile = AzaharNative.getSystemProfile();
      this.systemProfileAvailable = profile.available;
      this.systemSetupNeeded = profile.systemSetupNeeded;
    } catch (_error) {
      this.systemProfileAvailable = false;
    }
  }

  // 对应 Android 系统文件页的 Run System Setup 开关，选中即写 CFG 存档
  private updateSystemSetupNeeded(value: boolean): void {
    try {
      const profile = AzaharNative.getSystemProfile();
      if (!profile.available) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('system_profile_unavailable'));
        return;
      }
      profile.systemSetupNeeded = value;
      if (!AzaharNative.setSystemProfile(profile)) {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showErrorToast(I18n.t('system_profile_save_failed'));
      }
    } catch (_error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('system_profile_save_failed'));
    }
  }

  private getSystemDirectories(): SystemDirectoryItem[] {
    return [
      { title: I18n.t('nand'), description: I18n.t('sys_dir_nand_desc'), relativePath: 'nand', badge: I18n.t('nand') },
      { title: I18n.t('sdmc'), description: I18n.t('sys_dir_sdmc_desc'), relativePath: 'sdmc', badge: I18n.t('sd') },
      { title: I18n.t('config'), description: I18n.t('sys_dir_config_desc'), relativePath: 'config', badge: I18n.t('config') },
      { title: I18n.t('dir_camera_images'), description: I18n.t('sys_dir_camera_desc'), relativePath: 'camera', badge: I18n.t('camera') }
    ];
  }

  private refreshConsoleLinkState(): void {
    this.isRefreshing = true;
    try {
      this.fullConsoleLinked = AzaharNative.isFullConsoleLinked();
    } catch (_error) {
      this.fullConsoleLinked = false;
    } finally {
      this.isRefreshing = false;
    }
  }

  private refreshSystemFilesStatus(): void {
    try {
      this.systemFilesStatus = AzaharNative.getSystemFilesStatus();
    } catch (_error) {
      this.systemFilesStatus = { old3dsInstalled: false, new3dsInstalled: false };
    }
  }

  private getFullPath(relativePath: string): string {
    if (!this.downloadDirPath) {
      return '';
    }
    return `${this.downloadDirPath}/${relativePath}`;
  }

  private getDirectoryUri(relativePath: string): string {
    if (!this.downloadDirUri) {
      return '';
    }
    const base = this.downloadDirUri.endsWith('/') ? this.downloadDirUri.slice(0, -1) : this.downloadDirUri;
    return `${base}/${relativePath}`;
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
        console.warn(`SystemFiles: mkdir failed: ${(_mkdirError as Error)?.message}`);
      }
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

  private async openDirectory(item: SystemDirectoryItem): Promise<void> {
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
    const result = await FileManagerHelper.getInstance().openFolder(
      this.context,
      this.getDirectoryUri(item.relativePath) || targetPath
    );
    if (!result.success) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(result.message);
    }
  }

  private confirmUnlinkConsole(): void {
    if (!this.fullConsoleLinked) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.t('console_not_linked'));
      return;
    }

    this.getUIContext().showAlertDialog({
      title: I18n.t('unlink_console_title'),
      message: I18n.t('unlink_console_message'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: I18n.t('unlink'),
        fontColor: TEXT_DANGER,
        action: () => {
          this.soundEffectManager.play(SoundEffect.CONFIRM);
          this.unlinkConsole();
        }
      },
      secondaryButton: {
        value: I18n.t('cancel'),
        fontColor: ThemeManager.getInstance().getControlAccent(),
        action: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
        }
      },
      cancel: () => {
        this.soundEffectManager.play(SoundEffect.BACK);
      }
    });
  }

  private unlinkConsole(): void {
    try {
      if (AzaharNative.unlinkConsole()) {
        this.soundEffectManager.play(SoundEffect.CONFIRM);
        this.refreshConsoleLinkState();
      } else {
        this.soundEffectManager.play(SoundEffect.FAIL);
        this.refreshConsoleLinkState();
        showWarningToast(I18n.t('console_unlink_not_done'));
      }
    } catch (_error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.t('console_unlink_failed'));
    }
  }

  private confirmUninstallSystemFiles(old3ds: boolean): void {
    const label = old3ds ? 'Old 3DS' : 'New 3DS';
    const installed = old3ds ? this.systemFilesStatus.old3dsInstalled : this.systemFilesStatus.new3dsInstalled;
    if (!installed) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showWarningToast(I18n.tf1('system_files_not_complete_fmt', 'label', label));
      return;
    }

    this.getUIContext().showAlertDialog({
      title: I18n.tf1('uninstall_system_files_title_fmt', 'label', label),
      message: I18n.tf1('uninstall_system_files_message_fmt', 'label', label),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: I18n.t('uninstall'),
        fontColor: TEXT_DANGER,
        action: () => {
          this.soundEffectManager.play(SoundEffect.CONFIRM);
          this.uninstallSystemFiles(old3ds, label);
        }
      },
      secondaryButton: {
        value: I18n.t('cancel'),
        fontColor: ThemeManager.getInstance().getControlAccent(),
        action: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
        }
      },
      cancel: () => {
        this.soundEffectManager.play(SoundEffect.BACK);
      }
    });
  }

  private uninstallSystemFiles(old3ds: boolean, label: string): void {
    try {
      if (AzaharNative.uninstallSystemFiles(old3ds)) {
        this.soundEffectManager.play(SoundEffect.CONFIRM);
        this.refreshSystemFilesStatus();
        showSuccessToast(I18n.tf1('system_files_uninstalled_fmt', 'label', label));
      } else {
        this.soundEffectManager.play(SoundEffect.FAIL);
        showWarningToast(I18n.tf1('system_files_uninstall_failed_fmt', 'label', label));
      }
    } catch (_error) {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('system_files_uninstall_failed_fmt', 'label', label));
    }
  }

  @Builder
  SectionHeader(title: string) {
    SettingsSectionHeader({ title })
  }

  @Builder
  DirectoryRow(item: SystemDirectoryItem) {
    ComposeListItem({
      contentItem: {
        icon: $r('sys.symbol.folder'),
        symbolStyle: new SymbolGlyphModifier($r('sys.symbol.folder')),
        primaryText: item.title,
        secondaryText: item.description,
        description: FileManagerHelper.getDisplayPath(this.getFullPath(item.relativePath))
      },
      operateItem: {
        text: item.badge,
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

  @Builder
  ConsoleLinkPanel() {
    ListItem() {
      this.SectionHeader(I18n.t('console_unique_data'))
    }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      ListItem() {
        ComposeListItem({
          contentItem: {
            icon: $r('sys.symbol.checkmark_shield'),
            symbolStyle: new SymbolGlyphModifier($r('sys.symbol.checkmark_shield'))
              .fontColor([this.fullConsoleLinked ? TEXT_PRIMARY : TEXT_SECONDARY]),
            primaryText: I18n.t('console_unique_data'),
            secondaryText: this.fullConsoleLinked ? I18n.t('console_linked_desc') : I18n.t('console_not_linked_desc')
          },
          operateItem: {
            text: this.fullConsoleLinked ? I18n.t('linked') : I18n.t('not_linked')
          }
        })
      }
      ListItem() {
        ComposeListItem({
          contentItem: {
            icon: $r('sys.symbol.arrow_clockwise'),
            symbolStyle: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise')),
            primaryText: this.isRefreshing ? I18n.t('refreshing') : I18n.t('refresh')
          },
          operateItem: {
            arrow: {
          value: $r('sys.symbol.chevron_right')
        }
          }
        })
        .onFocus(() => {
          this.soundEffectManager.play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          this.soundEffectManager.play(SoundEffect.SELECT);
          this.refreshConsoleLinkState();
        })
      }
      ListItem() {
        ComposeListItem({
          contentItem: {
            icon: $r('sys.symbol.trash'),
            symbolStyle: new SymbolGlyphModifier($r('sys.symbol.trash')).fontColor([TEXT_DANGER]),
            primaryText: I18n.t('unlink')
          },
          operateItem: {
            arrow: {
          value: $r('sys.symbol.chevron_right')
        }
          }
        })
        .enabled(this.fullConsoleLinked)
        .opacity(this.fullConsoleLinked ? 1 : 0.55)
        .onFocus(() => {
          this.soundEffectManager.play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          this.soundEffectManager.play(SoundEffect.SELECT);
          this.confirmUnlinkConsole();
        })
      }
      if (this.systemProfileAvailable) {
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('run_system_setup'),
            isOn: this.systemSetupNeeded,
            onToggle: (value: boolean) => {
              this.systemSetupNeeded = value;
              this.updateSystemSetupNeeded(value);
            }
          })
        }
      }
    }
    .padding(menuGroupPadding())
    .backgroundColor(listCardBgOf(this.themeColors))
    .divider(settingsGroupDivider())
    .margin(menuGroupMargin())
  }

  @Builder
  SystemFirmwareRow(title: string, description: string, installed: boolean, old3ds: boolean) {
    ComposeListItem({
      contentItem: {
        icon: installed ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.info_circle'),
        symbolStyle: new SymbolGlyphModifier(installed ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.info_circle'))
          .fontColor([installed ? TEXT_PRIMARY : TEXT_SECONDARY]),
        primaryText: title,
        secondaryText: description
      },
      operateItem: {
        text: installed ? I18n.t('complete') : I18n.t('incomplete'),
        arrow: installed ? {
          value: $r('sys.symbol.chevron_right')
        } : undefined
      }
    })
    .enabled(installed)
    .opacity(installed ? 1 : 0.55)
    .onFocus(() => {
      this.soundEffectManager.play(SoundEffect.FOCUS);
    })
    .onClick(() => {
      if (installed) {
        this.soundEffectManager.play(SoundEffect.SELECT);
        this.confirmUninstallSystemFiles(old3ds);
      }
    })
  }

  @Builder
  SystemFirmwarePanel() {
    ListItem() {
      this.SectionHeader(I18n.t('system_firmware_files'))
    }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      ListItem() {
        ComposeListItem({
          contentItem: {
            icon: $r('sys.symbol.arrow_clockwise'),
            symbolStyle: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise')),
            primaryText: I18n.t('refresh')
          },
          operateItem: {
            arrow: {
          value: $r('sys.symbol.chevron_right')
        }
          }
        })
        .onFocus(() => {
          this.soundEffectManager.play(SoundEffect.FOCUS);
        })
        .onClick(() => {
          this.soundEffectManager.play(SoundEffect.SELECT);
          this.refreshSystemFilesStatus();
        })
      }
      ListItem() {
        this.SystemFirmwareRow(
          I18n.t('old3ds_system_files'),
          I18n.t('old3ds_system_files_desc'),
          this.systemFilesStatus.old3dsInstalled,
          true
        )
      }
      ListItem() {
        this.SystemFirmwareRow(
          I18n.t('new3ds_system_files'),
          I18n.t('new3ds_system_files_desc'),
          this.systemFilesStatus.new3dsInstalled,
          false
        )
      }
    }
    .padding(menuGroupPadding())
    .backgroundColor(listCardBgOf(this.themeColors))
    .divider(settingsGroupDivider())
    .margin(menuGroupMargin())
  }

  @Builder
  ZipPassPanel() {
    ListItem() {
      this.SectionHeader('ZipPass')
    }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      ListItem() {
        ComposeListItem({
          contentItem: {
            icon: $r('sys.symbol.upload'),
            primaryText: I18n.t('zippass_export'),
            secondaryText: I18n.t('zippass_export_desc')
          },
          operateItem: { arrow: { value: $r('sys.symbol.chevron_right') } }
        })
        .onFocus(() => { this.soundEffectManager.play(SoundEffect.FOCUS); })
        .onClick(() => {
          this.soundEffectManager.play(SoundEffect.SELECT);
          this.zipPassExport();
        })
      }
      ListItem() {
        ComposeListItem({
          contentItem: {
            icon: $r('sys.symbol.square_and_arrow_down'),
            primaryText: I18n.t('zippass_import'),
            secondaryText: I18n.t('zippass_import_desc')
          },
          operateItem: { arrow: { value: $r('sys.symbol.chevron_right') } }
        })
        .onFocus(() => { this.soundEffectManager.play(SoundEffect.FOCUS); })
        .onClick(() => {
          this.soundEffectManager.play(SoundEffect.SELECT);
          this.zipPassImport();
        })
      }
      ListItem() {
        ComposeListItem({
          contentItem: {
            icon: $r('sys.symbol.trash'),
            symbolStyle: new SymbolGlyphModifier($r('sys.symbol.trash')).fontColor([TEXT_DANGER]),
            primaryText: I18n.t('zippass_clear')
          },
          operateItem: { arrow: { value: $r('sys.symbol.chevron_right') } }
        })
        .onFocus(() => { this.soundEffectManager.play(SoundEffect.FOCUS); })
        .onClick(() => {
          this.soundEffectManager.play(SoundEffect.SELECT);
          const ret = AzaharNative.zipPassClearStreetPass();
          if (ret === 0) {
            showSuccessToast(I18n.t('zippass_clear_done'));
          } else {
            showErrorToast(I18n.tf1('zippass_failed_fmt', 'code', ret));
          }
        })
      }
    }
      .padding(menuGroupPadding())
  }

  build() {
    Stack() {
      if (this.globalWallpaperUri) {
        GlobalWallpaper()
      } else {
        FloatTilesBackground({
          themeColors: this.themeColors,
          isPlaying: false
        })
      }

      AzaharNavPage({
        title: I18n.t('system_files'),
        scrollers: [this.pageScroller],
        subtitle: this.downloadDirPath ? FileManagerHelper.getDisplayPath(this.downloadDirPath) : I18n.t('download_dir_not_set_short'),
        onBack: () => {
          this.soundEffectManager.play(SoundEffect.BACK);
          router.back();
        },
        menuItems: [
          {
            icon: this.downloadDirPath ? $r('sys.symbol.arrow_clockwise') : $r('sys.symbol.folder'),
            action: () => {
              this.soundEffectManager.play(SoundEffect.DECIDE);
              if (this.downloadDirPath) {
                this.gameManager.ensureLibraryDirectories(this.downloadDirPath);
                this.refreshConsoleLinkState();
                this.refreshSystemFilesStatus();
                showSuccessToast(I18n.t('system_dirs_checked'));
              } else {
                this.initializeDownloadDir();
              }
            }
          }
        ]
      }) {
        SettingsList({ scroller: this.pageScroller }) {
          this.ConsoleLinkPanel()
          this.ZipPassPanel()
          this.SystemFirmwarePanel()

          ListItem() {

            this.SectionHeader(I18n.t('system_dirs'))

          }

          ListItemGroup({ style: ListItemGroupStyle.CARD }) {
            ForEach(this.getSystemDirectories(), (item: SystemDirectoryItem) => {
              ListItem() {
                this.DirectoryRow(item)
              }
            }, (item: SystemDirectoryItem) => item.relativePath)
          }
          .padding(menuGroupPadding())
          .backgroundColor(listCardBgOf(this.themeColors))
          .divider(settingsGroupDivider())
        }
      }
    }
    .width('100%')
    .height('100%')
    .onKeyEvent(gamepadBackHandler())
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
    PageTransitionEnter({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Push, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Pop, duration: PAGE_TRANSITION_DURATION }).slide(SlideEffect.Right)
  }
}

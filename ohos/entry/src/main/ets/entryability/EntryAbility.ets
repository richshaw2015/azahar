import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BackgroundMusicManager } from '../utils/BackgroundMusicManager';
import { FullscreenController } from '../utils/FullscreenController';
import { I18n } from '../utils/I18nManager';
import { SafeAreaHelper } from '../utils/SafeAreaHelper';
import { ThemeManager } from '../utils/ThemeManager';
import { PersistedUriManager } from '../utils/PersistedUriManager';
import { AzaharNative } from '../types/AzaharNative';

const DOMAIN = 0x0000;
const TAG = 'Azahar_EntryAbility';

export class LaunchParams {
  static gamePath: string = '';
  static fromCard: boolean = false;
}

export default class EntryAbility extends UIAbility {
  private i18nReady: Promise<void> = Promise.resolve();
  private themeReady: Promise<void> = Promise.resolve();

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    this.themeReady = ThemeManager.getInstance().initialize(this.context).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'ThemeManager init failed: %{public}s', err.message);
    });
    this.handleWantParams(want);
    this.i18nReady = I18n.init(this.context).then(() => {
      hilog.info(DOMAIN, TAG, 'I18n initialized.');
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'I18n init failed: %{public}s', err.message);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
    BackgroundMusicManager.getInstance().release();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    const fullscreenController = FullscreenController.getInstance();
    fullscreenController.init(windowStage).then(() => {
      fullscreenController.disableFullscreen().catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'Apply immersive mode failed: %{public}s', err.message);
      });
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'Fullscreen init failed: %{public}s', err.message);
    });

    SafeAreaHelper.init(windowStage);
    windowStage.getMainWindow().then((win: window.Window) => {
      win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'Set orientation failed: %{public}s', err.message);
      });
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'Get main window for orientation failed: %{public}s', err.message);
    });

    this.i18nReady.then(() => {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
        // 官方要求 setColorMode 在主线程、页面加载完成后调用
        this.themeReady.then(() => {
          ThemeManager.getInstance().applyColorMode();
        });
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    if (newConfig.colorMode !== undefined) {
      ThemeManager.getInstance().onSystemColorModeChanged(newConfig.colorMode);
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleWantParams(want);
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
    BackgroundMusicManager.getInstance().resumeFromBackground();
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
    BackgroundMusicManager.getInstance().pauseForBackground();
  }

  // `aa start --ps runNativeTests true` runs the native Catch2 suite inside
  // the app process (retail devices cannot exec hdc-pushed binaries). The
  // full report is emitted to hilog from native code under AzaharNativeTests.
  private maybeRunNativeTests(want: Want): void {
    const flag = want.parameters?.['runNativeTests'];
    if (!flag) {
      return;
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'runNativeTests requested');
    try {
      const filter = want.parameters?.['testFilter'];
      const summary = AzaharNative.runNativeTests(typeof filter === 'string' ? filter : '');
      hilog.info(DOMAIN, TAG, 'runNativeTests done: %{public}s', summary);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'runNativeTests failed: %{public}s', JSON.stringify(err));
    }
  }

  private maybeRunAsmCrashProbe(want: Want): void {
    const flag = want.parameters?.['asmCrashProbe'];
    if (!flag) {
      return;
    }
    try {
      AzaharNative.asmCrashProbe();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'asmCrashProbe failed: %{public}s', JSON.stringify(err));
    }
  }

  private handleWantParams(want: Want): void {
    this.maybeRunNativeTests(want);
    this.maybeRunAsmCrashProbe(want);

    // Backend escape hatch that bypasses syncNativeSettings() masking:
    // `aa start --ps cpuBackend dyncom|fastinterp|jit`
    const cpuBackend = want.parameters?.['cpuBackend'] as string;
    if (cpuBackend === 'dyncom' || cpuBackend === 'fastinterp' || cpuBackend === 'jit') {
      AzaharNative.setConfig('cpu_backend', cpuBackend);
      hilog.info(DOMAIN, TAG, 'cpuBackend override: %{public}s', cpuBackend);
    }
    const graphicsApi = want.parameters?.['graphicsApi'] as string;
    if (graphicsApi === '1' || graphicsApi === '2') {
      AzaharNative.setConfig('graphics_api', Number(graphicsApi));
      hilog.info(DOMAIN, TAG, 'graphicsApi override: %{public}s', graphicsApi);
    }

    const fileUri = want.uri;
    if (fileUri && fileUri.startsWith('file://')) {
      // 文件管理器「打开方式」：viewData want 在 uri 字段携带 file:// 授权
      void this.launchGameFromFileUri(fileUri);
      return;
    }

    const gamePath = this.extractGamePath(want);
    if (!gamePath) {
      return;
    }
    LaunchParams.gamePath = gamePath;
    LaunchParams.fromCard = true;
    AppStorage.setOrCreate('pendingGamePath', gamePath);
    hilog.info(DOMAIN, TAG, 'Widget pending game path set.');
  }

  /**
   * 文件管理器「打开方式」传入的 file:// URI 只带会话级临时授权，先持久化并激活
   * 再转换为路径，最后复用卡片直启链路（pendingGamePath）由 Index 拉起游戏。
   */
  private async launchGameFromFileUri(uri: string): Promise<void> {
    try {
      const uriManager = PersistedUriManager.getInstance();
      await uriManager.initialize(this.context);

      let path = '';
      const persisted = await uriManager.persistFilePermission(uri);
      if (persisted && persisted.path) {
        path = persisted.path;
      } else {
        // 设备不支持持久化授权时，want 自带临时授权在会话内仍可读，
        // best-effort 激活后直接转换路径
        await uriManager.activatePermissionForUri(uri);
        path = uriManager.uriToPath(uri);
      }

      if (!path) {
        hilog.error(DOMAIN, TAG, 'Failed to resolve opened file uri.');
        return;
      }

      LaunchParams.gamePath = path;
      LaunchParams.fromCard = true;
      AppStorage.setOrCreate('pendingGamePath', path);
      hilog.info(DOMAIN, TAG, 'File open pending game path set.');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Resolve opened file uri failed: %{public}s', JSON.stringify(err));
    }
  }

  private extractGamePath(want: Want): string {
    const directPath = want.parameters?.['gamePath'] as string;
    if (directPath) {
      return directPath;
    }

    const rawParams = want.parameters?.['params'];
    if (!rawParams) {
      return '';
    }
    if (typeof rawParams === 'string') {
      try {
        const params = JSON.parse(rawParams) as Record<string, string>;
        return params.gamePath || '';
      } catch (_error) {
        return '';
      }
    }
    return (rawParams as Record<string, string>).gamePath || '';
  }
}

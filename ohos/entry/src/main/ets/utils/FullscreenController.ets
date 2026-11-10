import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'Azahar_Fullscreen';

export class FullscreenController {
  private static instance: FullscreenController | null = null;
  private windowClass: window.Window | null = null;
  private initialized: boolean = false;
  private fullscreen: boolean = false;

  private constructor() {}

  static getInstance(): FullscreenController {
    if (!FullscreenController.instance) {
      FullscreenController.instance = new FullscreenController();
    }
    return FullscreenController.instance;
  }

  async init(windowStage: window.WindowStage): Promise<void> {
    if (this.initialized) {
      return;
    }

    try {
      this.windowClass = await windowStage.getMainWindow();
    } catch (err) {
      this.windowClass = null;
      hilog.warn(DOMAIN, TAG, 'Fullscreen init failed: %{public}s', (err as Error).message);
    } finally {
      this.initialized = true;
    }
  }

  async enableFullscreen(): Promise<boolean> {
    if (!this.windowClass) {
      hilog.warn(DOMAIN, TAG, 'Window not initialized, cannot enable fullscreen');
      return false;
    }

    try {
      await this.windowClass.setWindowLayoutFullScreen(true);
      await this.windowClass.setWindowSystemBarEnable([]);
      this.fullscreen = true;
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Enable fullscreen failed: %{public}s', (err as Error).message);
      return false;
    }
  }

  async disableFullscreen(): Promise<boolean> {
    if (!this.windowClass) {
      hilog.warn(DOMAIN, TAG, 'Window not initialized, cannot disable fullscreen');
      return false;
    }

    try {
      await this.windowClass.setWindowLayoutFullScreen(true);
      await this.windowClass.setWindowSystemBarEnable(['status', 'navigation']);
      this.fullscreen = false;
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Disable fullscreen failed: %{public}s', (err as Error).message);
      return false;
    }
  }

  isFullscreenEnabled(): boolean {
    return this.fullscreen;
  }

  isInitialized(): boolean {
    return this.initialized;
  }
}

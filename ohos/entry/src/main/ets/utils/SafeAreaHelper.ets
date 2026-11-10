import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'Azahar_SafeArea';

AppStorage.setOrCreate('safeAreaTopVp', 0);
AppStorage.setOrCreate('safeAreaBottomVp', 0);

export class SafeAreaHelper {
  private static mainWindow: window.Window | null = null;

  static async init(windowStage: window.WindowStage): Promise<void> {
    try {
      const mainWindow = await windowStage.getMainWindow();
      SafeAreaHelper.mainWindow = mainWindow;
      // 先注册监听再测量：窗口布局完成前的首帧避让区可能为 0，
      // 靠 avoidAreaChange 和延迟重测兜底补齐
      mainWindow.on('avoidAreaChange', () => {
        SafeAreaHelper.updateSafeArea(mainWindow);
      });
      SafeAreaHelper.updateSafeArea(mainWindow);
      setTimeout(() => {
        void SafeAreaHelper.updateSafeArea(mainWindow);
      }, 500);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Safe area init failed: %{public}s', (err as Error).message);
    }
  }

  // 页面 aboutToAppear/onPageShow 时主动重测一次，覆盖初始化早于窗口布局完成的竞态
  static refresh(): void {
    if (SafeAreaHelper.mainWindow) {
      void SafeAreaHelper.updateSafeArea(SafeAreaHelper.mainWindow);
    }
  }

  private static async updateSafeArea(win: window.Window): Promise<void> {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      const densityPixels = defaultDisplay.densityPixels || 1;
      const isLandscape = defaultDisplay.width > defaultDisplay.height;
      if (isLandscape) {
        AppStorage.setOrCreate('safeAreaTopVp', 0);
        AppStorage.setOrCreate('safeAreaBottomVp', 0);
        return;
      }

      const systemArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutoutArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const navIndicatorArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      let topPx = Math.max(systemArea.topRect?.height || 0, cutoutArea.topRect?.height || 0);
      const bottomPx = Math.max(systemArea.bottomRect?.height || 0, navIndicatorArea.bottomRect?.height || 0);

      try {
        const cutoutInfo = await defaultDisplay.getCutoutInfo();
        let cutoutTop = 0;
        if (cutoutInfo.boundingRects) {
          for (let i = 0; i < cutoutInfo.boundingRects.length; i++) {
            const rect = cutoutInfo.boundingRects[i];
            const bottomEdge = rect.top + rect.height;
            if (rect.top + rect.height / 2 <= defaultDisplay.height / 2) {
              cutoutTop = Math.max(cutoutTop, bottomEdge);
            }
          }
        }
        const waterfallTop = cutoutInfo.waterfallDisplayAreaRects?.top.height ?
          cutoutInfo.waterfallDisplayAreaRects.top.top + cutoutInfo.waterfallDisplayAreaRects.top.height : 0;
        topPx = Math.max(topPx, cutoutTop, waterfallTop);
      } catch (_error) {
        // 刘海/挖孔信息在部分设备不可得，按无避让处理
      }

      if (topPx > defaultDisplay.height / 2) {
        topPx = Math.floor(defaultDisplay.height / 2);
      }
      AppStorage.setOrCreate('safeAreaTopVp', Math.ceil(topPx / densityPixels));
      AppStorage.setOrCreate('safeAreaBottomVp', Math.ceil(bottomPx / densityPixels));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Safe area update failed: %{public}s', (err as Error).message);
    }
  }
}

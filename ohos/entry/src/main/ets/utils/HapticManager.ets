import { vibrator } from '@kit.SensorServiceKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsManager } from './SettingsManager';
import { KEY_INPUT_HAPTIC_ENABLED, KEY_INPUT_HAPTIC_STRENGTH } from '../types/SettingsTypes';

const DOMAIN = 0x0000;
const TAG = 'Azahar_Haptic';

export class HapticManager {
  private static instance: HapticManager | null = null;
  private settingsManager: SettingsManager = SettingsManager.getInstance();

  private constructor() {}

  public static getInstance(): HapticManager {
    if (!HapticManager.instance) {
      HapticManager.instance = new HapticManager();
    }
    return HapticManager.instance;
  }

  public trigger(): void {
    const enabled = this.settingsManager.getSync<boolean>(KEY_INPUT_HAPTIC_ENABLED, true);
    if (!enabled) {
      return;
    }

    try {
      const strength = this.settingsManager.getSync<number>(KEY_INPUT_HAPTIC_STRENGTH, 70);
      const duration = Math.round(5 + (strength / 100) * 45);
      vibrator.startVibration({
        type: 'time',
        duration: duration
      }, {
        id: 0,
        usage: 'touch'
      }).catch((err: Error) => {
        hilog.debug(DOMAIN, TAG, 'Vibration failed: %{public}s', err.message);
      });
    } catch (err) {
      hilog.debug(DOMAIN, TAG, 'Vibration error: %{public}s', (err as Error).message);
    }
  }
}

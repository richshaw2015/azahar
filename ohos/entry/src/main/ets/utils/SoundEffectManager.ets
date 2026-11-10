import { audio } from '@kit.AudioKit';
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HapticManager } from './HapticManager';
import { SettingsManager } from './SettingsManager';
import { KEY_SFX_ENABLED, KEY_SFX_VOLUME } from '../types/SettingsTypes';

const DOMAIN = 0x0000;
const TAG = 'Azahar_SFX';

export enum SoundEffect {
  CONFIRM = 'confirm',
  BACK = 'back',
  SELECT = 'select',
  TOGGLE_ON = 'toggle_on',
  TOGGLE_OFF = 'toggle_off',
  DECIDE = 'decide',
  FOCUS = 'focus',
  FAIL = 'fail',
}

const SFX_FILES: Record<string, string> = {
  [SoundEffect.CONFIRM]: 'assets/audio/confirm.mp3',
  [SoundEffect.BACK]: 'assets/audio/back.mp3',
  [SoundEffect.SELECT]: 'assets/audio/select.mp3',
  [SoundEffect.TOGGLE_ON]: 'assets/audio/on.mp3',
  [SoundEffect.TOGGLE_OFF]: 'assets/audio/off.mp3',
  [SoundEffect.DECIDE]: 'assets/audio/decide.mp3',
  [SoundEffect.FOCUS]: 'assets/audio/scroll.mp3',
  [SoundEffect.FAIL]: 'assets/audio/fail.mp3',
};

export class SoundEffectManager {
  private static instance: SoundEffectManager | null = null;
  private soundPool: media.SoundPool | null = null;
  private soundIds: Map<string, number> = new Map();
  private initialized: boolean = false;
  private initializing: boolean = false;
  private settingsManager: SettingsManager = SettingsManager.getInstance();

  private constructor() {}

  public static getInstance(): SoundEffectManager {
    if (!SoundEffectManager.instance) {
      SoundEffectManager.instance = new SoundEffectManager();
    }
    return SoundEffectManager.instance;
  }

  public async initialize(context: Context): Promise<void> {
    if (this.initialized || this.initializing) {
      return;
    }
    this.initializing = true;

    try {
      const audioRendererInfo: audio.AudioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_GAME,
        rendererFlags: 0
      };
      this.soundPool = await media.createSoundPool(8, audioRendererInfo);

      const resourceManager = context.resourceManager;
      const keys = Object.keys(SFX_FILES);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        const fileName = SFX_FILES[key];
        try {
          const fd = await resourceManager.getRawFd(fileName);
          const soundId = await this.soundPool.load(fd.fd, fd.offset, fd.length);
          this.soundIds.set(key, soundId);
          hilog.debug(DOMAIN, TAG, 'Loaded SFX: %{public}s -> id %{public}d', key, soundId);
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'Failed to load SFX %{public}s: %{public}s', key, (err as Error).message);
        }
      }

      this.initialized = true;
      hilog.info(DOMAIN, TAG, 'SoundEffectManager initialized, %{public}d sounds loaded', this.soundIds.size);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to initialize SoundPool: %{public}s', (err as Error).message);
    } finally {
      this.initializing = false;
    }
  }

  public play(effect: SoundEffect): void {
    HapticManager.getInstance().trigger();

    if (!this.initialized || !this.soundPool) {
      return;
    }

    const enabled = this.settingsManager.getSync<boolean>(KEY_SFX_ENABLED, true);
    if (!enabled) {
      return;
    }

    const soundId = this.soundIds.get(effect);
    if (soundId === undefined) {
      return;
    }

    const volumePercent = this.settingsManager.getSync<number>(KEY_SFX_VOLUME, 30);
    const volume = volumePercent / 100.0;
    const playParams: media.PlayParameters = {
      loop: 0,
      rate: audio.AudioRendererRate.RENDER_RATE_NORMAL,
      leftVolume: volume,
      rightVolume: volume,
      priority: 0
    };

    this.soundPool.play(soundId, playParams).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'Failed to play SFX %{public}s: %{public}s', effect, err.message);
    });
  }

  public async release(): Promise<void> {
    if (this.soundPool) {
      try {
        await this.soundPool.release();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to release SoundPool: %{public}s', (err as Error).message);
      }
      this.soundPool = null;
    }
    this.soundIds.clear();
    this.initialized = false;
  }
}

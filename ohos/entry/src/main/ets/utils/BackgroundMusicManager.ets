import { audio } from '@kit.AudioKit';
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsManager } from './SettingsManager';
import { KEY_BGM_ENABLED, KEY_BGM_VOLUME } from '../types/SettingsTypes';

const DOMAIN = 0x0000;
const TAG = 'Azahar_BGM';
const BGM_RAW_FILE = 'assets/audio/bg.mp3';

export class BackgroundMusicManager {
  private static instance: BackgroundMusicManager | null = null;
  private avPlayer: media.AVPlayer | null = null;
  private initialized: boolean = false;
  private initializing: boolean = false;
  private pausedForGame: boolean = false;
  private pausedForBackground: boolean = false;
  private settingsManager: SettingsManager = SettingsManager.getInstance();

  private constructor() {}

  static getInstance(): BackgroundMusicManager {
    if (!BackgroundMusicManager.instance) {
      BackgroundMusicManager.instance = new BackgroundMusicManager();
    }
    return BackgroundMusicManager.instance;
  }

  async initialize(context: Context): Promise<void> {
    if (this.initialized || this.initializing) {
      return;
    }
    this.initializing = true;

    try {
      this.avPlayer = await media.createAVPlayer();
      this.avPlayer.audioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      };

      await new Promise<void>((resolve, reject) => {
        this.avPlayer!.on('stateChange', async (state: string) => {
          try {
            if (state === 'initialized') {
              await this.avPlayer!.prepare();
            } else if (state === 'prepared') {
              this.avPlayer!.loop = true;
              this.applyVolume();
              this.initialized = true;
              this.initializing = false;

              if (this.settingsManager.getSync<boolean>(KEY_BGM_ENABLED, true)) {
                await this.avPlayer!.play();
              }
              hilog.info(DOMAIN, TAG, 'BackgroundMusicManager initialized');
              resolve();
            } else if (state === 'completed') {
              if (this.avPlayer?.loop) {
                await this.avPlayer.play();
              }
            } else if (state === 'error') {
              reject(new Error('AVPlayer entered error state'));
            }
          } catch (err) {
            reject(err);
          }
        });

        this.avPlayer!.on('error', (err) => {
          reject(err);
        });

        context.resourceManager.getRawFd(BGM_RAW_FILE).then((fd) => {
          this.avPlayer!.fdSrc = {
            fd: fd.fd,
            offset: fd.offset,
            length: fd.length
          };
        }).catch((err: Error) => {
          reject(err);
        });
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to initialize BGM: %{public}s', (err as Error).message);
    } finally {
      this.initializing = false;
    }
  }

  async play(): Promise<void> {
    if (!this.initialized || !this.avPlayer) {
      return;
    }
    if (!this.settingsManager.getSync<boolean>(KEY_BGM_ENABLED, true)) {
      return;
    }

    try {
      this.applyVolume();
      await this.avPlayer.play();
      this.pausedForGame = false;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'BGM play failed: %{public}s', (err as Error).message);
    }
  }

  async pause(): Promise<void> {
    if (!this.initialized || !this.avPlayer) {
      return;
    }
    try {
      await this.avPlayer.pause();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'BGM pause failed: %{public}s', (err as Error).message);
    }
  }

  async pauseForGame(): Promise<void> {
    this.pausedForGame = true;
    if (!this.initialized || !this.avPlayer) {
      return;
    }
    if (!this.settingsManager.getSync<boolean>(KEY_BGM_ENABLED, true)) {
      return;
    }

    await this.pause();
  }

  async resumeFromGame(): Promise<void> {
    if (!this.pausedForGame) {
      return;
    }
    this.pausedForGame = false;
    if (!this.initialized || !this.avPlayer) {
      return;
    }
    await this.play();
  }

  async pauseForBackground(): Promise<void> {
    if (!this.initialized || !this.avPlayer || this.pausedForGame) {
      return;
    }
    if (!this.settingsManager.getSync<boolean>(KEY_BGM_ENABLED, true)) {
      return;
    }

    this.pausedForBackground = true;
    await this.pause();
  }

  async resumeFromBackground(): Promise<void> {
    if (!this.initialized || !this.avPlayer || !this.pausedForBackground || this.pausedForGame) {
      return;
    }
    this.pausedForBackground = false;
    await this.play();
  }

  async setEnabled(enabled: boolean): Promise<void> {
    if (!this.initialized || !this.avPlayer) {
      return;
    }
    if (enabled) {
      if (!this.pausedForGame) {
        await this.play();
      }
    } else {
      await this.pause();
    }
  }

  setVolume(volumePercent: number): void {
    if (!this.avPlayer) {
      return;
    }
    const volume = (volumePercent / 100.0) * 0.5;
    this.avPlayer.setVolume(volume);
  }

  async release(): Promise<void> {
    if (this.avPlayer) {
      try {
        await this.avPlayer.release();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to release BGM: %{public}s', (err as Error).message);
      }
      this.avPlayer = null;
    }
    this.initialized = false;
    this.pausedForGame = false;
    this.pausedForBackground = false;
  }

  private applyVolume(): void {
    const volumePercent = this.settingsManager.getSync<number>(KEY_BGM_VOLUME, 20);
    this.setVolume(volumePercent);
  }
}

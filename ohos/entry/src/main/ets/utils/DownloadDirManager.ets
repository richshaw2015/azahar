import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileUri, picker } from '@kit.CoreFileKit';

const PREFERENCES_NAME: string = 'azahar_download_dir_settings';
const KEY_DOWNLOAD_DIR_PATH: string = 'download_dir_path';
const KEY_DOWNLOAD_DIR_URI: string = 'download_dir_uri';

export class DownloadDirManager {
  private static instance: DownloadDirManager | null = null;
  private context: common.UIAbilityContext | null = null;
  private prefs: preferences.Preferences | null = null;
  private downloadDirPath: string = '';
  private downloadDirUri: string = '';
  private initialized: boolean = false;

  static getInstance(): DownloadDirManager {
    if (!DownloadDirManager.instance) {
      DownloadDirManager.instance = new DownloadDirManager();
    }
    return DownloadDirManager.instance;
  }

  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }

    this.context = context;
    this.prefs = await preferences.getPreferences(context, PREFERENCES_NAME);
    await this.loadDownloadDir();
    this.initialized = true;
  }

  async initDownloadDirectory(): Promise<string> {
    if (this.downloadDirPath) {
      return this.downloadDirPath;
    }
    if (!this.context) {
      return '';
    }

    const documentPicker = new picker.DocumentViewPicker(this.context);
    const options = new picker.DocumentSaveOptions();
    options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const result = await documentPicker.save(options);
    if (!result || result.length === 0) {
      return '';
    }

    this.downloadDirUri = result[0];
    this.downloadDirPath = new fileUri.FileUri(this.downloadDirUri).path;
    await this.saveDownloadDir();
    return this.downloadDirPath;
  }

  getDownloadDirPath(): string {
    return this.downloadDirPath;
  }

  getDownloadDirUri(): string {
    return this.downloadDirUri;
  }

  isInitialized(): boolean {
    return this.downloadDirPath.length > 0;
  }

  private async loadDownloadDir(): Promise<void> {
    if (!this.prefs) {
      return;
    }

    this.downloadDirPath = await this.prefs.get(KEY_DOWNLOAD_DIR_PATH, '') as string;
    this.downloadDirUri = await this.prefs.get(KEY_DOWNLOAD_DIR_URI, '') as string;
  }

  private async saveDownloadDir(): Promise<void> {
    if (!this.prefs) {
      return;
    }

    await this.prefs.put(KEY_DOWNLOAD_DIR_PATH, this.downloadDirPath);
    await this.prefs.put(KEY_DOWNLOAD_DIR_URI, this.downloadDirUri);
    await this.prefs.flush();
  }

}

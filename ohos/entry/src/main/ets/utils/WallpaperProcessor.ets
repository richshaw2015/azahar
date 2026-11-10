import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { GLOBAL_WALLPAPER_URI_KEY } from '../types/SettingsTypes';
import { I18n } from './I18nManager';
import { SettingsManager } from './SettingsManager';
import { showErrorToast } from './ToastHelper';

const WALLPAPER_FILENAME: string = 'azahar_wallpaper.jpg';
const CUSTOM_WALLPAPER_MAX_DIM: number = 1440;

export interface WallpaperPickResult {
  success: boolean;
  cancelled: boolean;
  filePath: string;
}

export class WallpaperProcessor {
  static async pickCustomWallpaper(context: common.UIAbilityContext): Promise<WallpaperPickResult> {
    let pixelMap: image.PixelMap | null = null;
    try {
      const selectedUri = await WallpaperProcessor.selectImageUri();
      if (!selectedUri) {
        return { success: false, cancelled: true, filePath: '' };
      }

      pixelMap = await WallpaperProcessor.loadEditablePixelMapFromUri(selectedUri);
      if (!pixelMap) {
        return { success: false, cancelled: false, filePath: '' };
      }

      await WallpaperProcessor.scaleDownForProcessing(pixelMap, CUSTOM_WALLPAPER_MAX_DIM);
      const filePath = await WallpaperProcessor.saveToFile(pixelMap, context);
      await WallpaperProcessor.applyWallpaperFilePath(filePath, context);
      return { success: true, cancelled: false, filePath };
    } catch (error) {
      showErrorToast(I18n.tf1('settings_wallpaper_failed_fmt', 'error', JSON.stringify(error)));
      return { success: false, cancelled: false, filePath: '' };
    } finally {
      if (pixelMap) {
        pixelMap.release();
      }
    }
  }

  /**
   * 把已有 PixelMap（如游戏封面）处理后设为全局壁纸。
   * 克隆后再缩放，避免改动调用方仍持有的源图。
   */
  static async applyPixelMapAsWallpaper(src: image.PixelMap, context: common.UIAbilityContext): Promise<string> {
    const pixelMap = await src.clone();
    try {
      await WallpaperProcessor.scaleDownForProcessing(pixelMap, CUSTOM_WALLPAPER_MAX_DIM);
      const filePath = await WallpaperProcessor.saveToFile(pixelMap, context);
      await WallpaperProcessor.applyWallpaperFilePath(filePath, context);
      return filePath;
    } finally {
      pixelMap.release();
    }
  }

  static async applyWallpaperFilePath(filePath: string, context: common.UIAbilityContext): Promise<void> {
    const wallpaperUri = `file://${filePath}`;
    const settingsManager = SettingsManager.getInstance();
    if (!settingsManager.isInitialized()) {
      await settingsManager.initialize(context);
    }
    await settingsManager.setString(GLOBAL_WALLPAPER_URI_KEY, wallpaperUri);
    AppStorage.setOrCreate('globalWallpaperUri', wallpaperUri);
    AppStorage.setOrCreate('globalWallpaperVersion', Date.now());
  }

  static async clearWallpaper(context: common.UIAbilityContext): Promise<void> {
    const filePath = await WallpaperProcessor.getWallpaperFilePath(context, false);
    try {
      if (filePath && fileIo.accessSync(filePath)) {
        fileIo.unlinkSync(filePath);
      }
    } catch (error) {
      console.warn(`WallpaperProcessor: remove wallpaper file failed: ${(error as Error).message}`);
    }

    SettingsManager.getInstance().setString(GLOBAL_WALLPAPER_URI_KEY, '').catch((error: Error) => {
      console.warn(`WallpaperProcessor: clear wallpaper setting failed: ${error.message}`);
    });
    AppStorage.setOrCreate('globalWallpaperUri', '');
    AppStorage.setOrCreate('globalWallpaperVersion', Date.now());
  }

  private static async selectImageUri(): Promise<string> {
    const photoPicker = new picker.PhotoViewPicker();
    const result = await photoPicker.select({
      MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: 1
    });
    if (result.photoUris && result.photoUris.length > 0) {
      return result.photoUris[0];
    }
    return '';
  }

  private static async loadEditablePixelMapFromUri(uri: string): Promise<image.PixelMap | null> {
    let imageSource: image.ImageSource | undefined = undefined;
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = fileIo.statSync(file.fd);
      if (stat.size <= 0) {
        return null;
      }

      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      imageSource = image.createImageSource(buffer);
      return await imageSource.createPixelMap({ editable: true });
    } finally {
      if (imageSource) {
        imageSource.release();
      }
      fileIo.closeSync(file);
    }
  }

  private static async scaleDownForProcessing(src: image.PixelMap, maxProcessDim: number): Promise<void> {
    const info = src.getImageInfoSync();
    const maxDim = Math.max(info.size.width, info.size.height);
    if (maxDim <= maxProcessDim) {
      return;
    }

    const scale = maxProcessDim / maxDim;
    await src.scale(scale, scale);
  }

  private static async saveToFile(src: image.PixelMap, context: common.UIAbilityContext): Promise<string> {
    const filePath = await WallpaperProcessor.getWallpaperFilePath(context, true);
    if (!filePath) {
      throw new Error(I18n.t('download_dir_not_set'));
    }
    const packer = image.createImagePacker();
    let buffer: ArrayBuffer;
    try {
      buffer = await packer.packing(src, { format: 'image/jpeg', quality: 95 });
    } finally {
      packer.release();
    }

    const file = fileIo.openSync(
      filePath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, buffer);
    } finally {
      fileIo.closeSync(file);
    }
    return filePath;
  }

  private static async getWallpaperFilePath(context: common.UIAbilityContext, _createDir: boolean): Promise<string> {
    // 壁纸属于应用私有资源，存 cacheDir，不占用户库目录
    return `${context.cacheDir}/${WALLPAPER_FILENAME}`;
  }
}

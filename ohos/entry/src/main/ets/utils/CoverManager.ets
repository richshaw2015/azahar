/**
 * 封面管理器（仅本地文件）
 * 封面文件按 covers/<coverId>/boxFrontSmall.jpg | boxFront.jpg 结构存放于
 * 下载目录下的 covers/ 子目录，用户可按同结构手动放置封面。
 * 使用 NCCH product code 末 4 位作为封面 ID（如 CTR-P-AREJ -> arej）：
 * 末位区域码 J(日)/E(美)/P(欧) 用完整 4 位，其他区域（K 韩/W 台/X 演示等）
 * 只取前 3 位（如 AREK -> are）
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { DownloadDirManager } from './DownloadDirManager';
import { GameInfo } from './GameManager';

const TAG = '[CoverManager]';
const COVER_FILE_HD = 'boxFront.jpg';
const COVER_FILE_NORMAL = 'boxFrontSmall.jpg';

export type OnlineCoverQuality = 'normal' | 'hd';

// ============================================================================
// 模块级纯函数
// ============================================================================

/**
 * 从 product code 推导封面 ID
 * 3DS product code 形如 CTR-P-AREJ，取末 4 位；
 * 末位区域码 J(日)/E(美)/P(欧) 保留 4 位，其他区域只取前 3 位
 */
export function getCoverId(productCode: string): string {
  const code = productCode.trim().toUpperCase();
  if (code.length < 4) {
    return '';
  }

  const last4 = code.substring(code.length - 4);
  const region = last4.charAt(3);
  if (region === 'J' || region === 'E' || region === 'P') {
    return last4.toLowerCase();
  }
  return last4.substring(0, 3).toLowerCase();
}

/** 封面文件名：normal -> boxFrontSmall.jpg，hd -> boxFront.jpg */
export function getCoverFileName(quality: OnlineCoverQuality): string {
  return quality === 'hd' ? COVER_FILE_HD : COVER_FILE_NORMAL;
}

function otherCoverQuality(quality: OnlineCoverQuality): OnlineCoverQuality {
  return quality === 'hd' ? 'normal' : 'hd';
}

/** 获取缓存文件路径：covers/<coverId>/boxFrontSmall.jpg 或 covers/<coverId>/boxFront.jpg */
export function getCacheFilePath(cacheDir: string, coverId: string, quality: OnlineCoverQuality): string {
  return `${cacheDir}/${coverId}/${getCoverFileName(quality)}`;
}

// ============================================================================
// CoverManager 单例类
// ============================================================================

export class CoverManager {
  private static instance: CoverManager | null = null;
  private context: common.UIAbilityContext | null = null;
  private initialized: boolean = false;
  private downloadDirManager: DownloadDirManager = DownloadDirManager.getInstance();
  private coverCache: Map<string, image.PixelMap> = new Map(); // coverId_quality -> PixelMap
  private coverChangeCallbacks: Array<(path: string) => void> = [];
  private coverCacheDir: string = '';

  private constructor() {}

  public static getInstance(): CoverManager {
    if (!CoverManager.instance) {
      CoverManager.instance = new CoverManager();
    }
    return CoverManager.instance;
  }

  public async initialize(context: common.UIAbilityContext): Promise<void> {
    this.context = context;

    try {
      await this.ensureCacheDirExists();

      this.initialized = this.coverCacheDir.length > 0;
      if (this.initialized) {
        console.info(`${TAG} initialized`);
      }
    } catch (err) {
      this.initialized = false;
      console.error(`${TAG} init failed: ${(err as Error).message}`);
    }
  }

  private async ensureCacheDirExists(): Promise<void> {
    const downloadDir = this.downloadDirManager.getDownloadDirPath();
    if (!downloadDir) {
      this.coverCacheDir = '';
      return;
    }

    this.coverCacheDir = `${downloadDir}/covers`;
    try {
      try {
        const stat = fileIo.statSync(this.coverCacheDir);
        if (!stat.isDirectory()) {
          fileIo.mkdirSync(this.coverCacheDir);
        }
      } catch (_e) {
        fileIo.mkdirSync(this.coverCacheDir);
      }
    } catch (err) {
      console.error(`${TAG} failed to create covers dir ${this.coverCacheDir}: ${(err as Error).message}`);
      this.coverCacheDir = '';
    }
  }

  public getCacheDir(): string {
    return this.coverCacheDir;
  }

  private async ensureReadyForCovers(): Promise<boolean> {
    if (!this.context) {
      return false;
    }
    if (!this.initialized) {
      await this.initialize(this.context);
    }
    return this.initialized;
  }

  private checkRecordKey(coverId: string, quality: OnlineCoverQuality): string {
    return `${coverId}_${quality}`;
  }

  /** 从内存缓存获取封面（同步） */
  public getCoverFromCache(coverId: string, quality: OnlineCoverQuality): image.PixelMap | null {
    if (!coverId) {
      return null;
    }
    return this.coverCache.get(this.checkRecordKey(coverId, quality)) || null;
  }

  /** 从内存缓存或本地文件缓存获取封面 */
  public async getCachedCover(coverId: string, quality: OnlineCoverQuality): Promise<image.PixelMap | null> {
    if (!coverId) {
      return null;
    }

    const memoryCover = this.getCoverFromCache(coverId, quality);
    if (memoryCover) {
      return memoryCover;
    }

    if (!await this.ensureReadyForCovers()) {
      return null;
    }

    const localCover = await this.loadCoverFromCache(coverId, quality);
    if (localCover) {
      this.coverCache.set(this.checkRecordKey(coverId, quality), localCover);
    }
    return localCover;
  }

  /** 获取游戏封面：内存缓存 -> covers/ 本地文件 */
  public async getCoverForGame(game: GameInfo, quality: OnlineCoverQuality): Promise<image.PixelMap | null> {
    const coverId = getCoverId(game.productCode);
    if (!coverId) {
      return null;
    }
    return this.getCachedCover(coverId, quality);
  }

  /** 当前画质的封面文件是否已存在于本地 covers/<id>/ */
  private coverFileExists(coverId: string, quality: OnlineCoverQuality): boolean {
    if (!this.coverCacheDir) {
      return false;
    }
    try {
      return fileIo.accessSync(getCacheFilePath(this.coverCacheDir, coverId, quality));
    } catch (_err) {
      return false;
    }
  }

  private async loadCoverFromCache(coverId: string, quality: OnlineCoverQuality): Promise<image.PixelMap | null> {
    if (!this.coverCacheDir) {
      return null;
    }

    // 优先当前画质文件，缺失或损坏时退回另一画质文件
    for (const q of [quality, otherCoverQuality(quality)]) {
      if (!this.coverFileExists(coverId, q)) {
        continue;
      }
      const pixelMap = await this.decodeCoverFile(getCacheFilePath(this.coverCacheDir, coverId, q));
      if (pixelMap) {
        return pixelMap;
      }
    }
    return null;
  }

  private async decodeCoverFile(cachePath: string): Promise<image.PixelMap | null> {
    let file: fileIo.File | null = null;
    let imageSource: image.ImageSource | undefined = undefined;
    try {
      file = fileIo.openSync(cachePath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);

      imageSource = image.createImageSource(buffer);
      return await imageSource.createPixelMap();
    } catch (err) {
      console.warn(`${TAG} failed to load cached cover ${cachePath}: ${(err as Error).message}`);
      try {
        fileIo.unlinkSync(cachePath);
      } catch (_unlinkErr) {
        // ignore
      }
      return null;
    } finally {
      if (imageSource) {
        imageSource.release();
      }
      if (file) {
        fileIo.closeSync(file);
      }
    }
  }

  /**
   * 检查一批游戏的封面（把本地 covers/ 下已有的封面加载到内存缓存）
   */
  public async checkAllCovers(games: GameInfo[]): Promise<void> {
    const quality: OnlineCoverQuality = 'normal';

    if (!await this.ensureReadyForCovers()) {
      console.info(`${TAG} skip cover check: covers dir not ready`);
      return;
    }

    for (const game of games) {
      const coverId = getCoverId(game.productCode);
      if (!coverId) {
        continue;
      }

      const key = this.checkRecordKey(coverId, quality);
      if (this.coverCache.has(key)) {
        continue;
      }

      const localCover = await this.loadCoverFromCache(coverId, quality);
      if (localCover) {
        this.coverCache.set(key, localCover);
        this.notifyCoverChange(game.path);
      }
    }
  }

  /** 添加封面变化回调（参数为游戏 path） */
  public addCoverChangeCallback(callback: (path: string) => void): void {
    this.coverChangeCallbacks.push(callback);
  }

  public removeCoverChangeCallback(callback: (path: string) => void): void {
    const index = this.coverChangeCallbacks.indexOf(callback);
    if (index >= 0) {
      this.coverChangeCallbacks.splice(index, 1);
    }
  }

  private notifyCoverChange(path: string): void {
    for (const callback of this.coverChangeCallbacks) {
      try {
        callback(path);
      } catch (err) {
        console.error(`${TAG} callback error: ${(err as Error).message}`);
      }
    }
  }

  public isInitialized(): boolean {
    return this.initialized;
  }
}

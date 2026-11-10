import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AzaharCIAInstallStatus, AzaharGameMetadata, AzaharNative } from '../types/AzaharNative';
import { CoverManager, getCoverId } from './CoverManager';
import { GameConfigManager } from './GameConfigManager';
import { normalizeTitleId, PlayTimeManager } from './PlayTimeManager';
import { SettingsManager } from './SettingsManager';
import { KEY_GAME_NAME_SOURCE } from '../types/SettingsTypes';

const PREFERENCES_NAME: string = 'azahar_games';
const KEY_RECENT_GAMES: string = 'recent_games';
const KEY_FAVORITE_TITLE_IDS: string = 'favorite_title_ids';
const KEY_INSTALLED_CIA_KEYS: string = 'installed_cia_keys';
const MAX_RECENT_GAMES: number = 50;
const ROMS_SUBDIR: string = 'roms';
const COVERS_SUBDIR: string = 'covers';
const MAX_SCAN_DEPTH: number = 2;
const MAX_COVER_DIMENSION: number = 512;
const MEDIA_TYPE_NAND: number = 0;
const MEDIA_TYPE_SDMC: number = 1;
const MEDIA_TYPE_GAME_CARD: number = 2;

export interface GameInfo {
  uri: string;
  path: string;
  name: string;
  fileName: string;
  extension: string;
  titleId: string;
  shortTitle: string;
  longTitle: string;
  publisher: string;
  regions: string;
  productCode: string;
  extdataId: string;
  fileType: string;
  encrypted: boolean;
  insertable: boolean;
  inserted: boolean;
  systemTitle: boolean;
  visible: boolean;
  hasIcon: boolean;
  installed: boolean;
  mediaType: number;
  lastPlayed: number;
  playCount: number;
  playTimeMs: number;
  favorite: boolean;
}

class RomEntry {
  filePath: string;
  fileName: string;

  constructor(filePath: string, fileName: string) {
    this.filePath = filePath;
    this.fileName = fileName;
  }
}

interface InstalledGameEntry {
  path: string;
  mediaType: number;
}

export interface CiaDeleteResult {
  deleted: number;
  failed: number;
}

export class GameManager {
  private static instance: GameManager | null = null;
  private prefs: preferences.Preferences | null = null;
  private recentGames: GameInfo[] = [];
  private favoriteTitleIds: Set<string> = new Set<string>();
  private installedCiaKeys: Set<string> = new Set<string>();
  private initialized: boolean = false;
  private supportedExtensions: string[] = [];
  private iconCache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private coverCache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();

  static getInstance(): GameManager {
    if (!GameManager.instance) {
      GameManager.instance = new GameManager();
    }
    return GameManager.instance;
  }

  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }

    this.supportedExtensions = AzaharNative.getSupportedExtensions();
    this.prefs = await preferences.getPreferences(context, PREFERENCES_NAME);
    await this.loadFavoriteTitleIds();
    await this.loadInstalledCiaKeys();
    await this.loadRecentGames();
    this.initialized = true;
  }

  getRecentGames(): GameInfo[] {
    return [...this.recentGames];
  }

  async addToRecentGames(uri: string, path: string): Promise<void> {
    if (!path) {
      return;
    }

    const existingIndex = this.recentGames.findIndex((game: GameInfo) => game.path === path || (!!uri && game.uri === uri));
    if (existingIndex >= 0) {
      const existing = this.recentGames[existingIndex];
      existing.lastPlayed = Date.now();
      existing.favorite = this.isFavorite(existing);
      this.recentGames.splice(existingIndex, 1);
      this.recentGames.unshift(existing);
    } else {
      // 启动次数/时长的唯一来源是 PlayTimeManager（GameView 启动成功后 startSession 计数），
      // 这里只维护最近列表的排序字段
      this.recentGames.unshift(this.createGameInfo(uri, path, Date.now(), 0));
    }

    if (this.recentGames.length > MAX_RECENT_GAMES) {
      this.recentGames = this.recentGames.slice(0, MAX_RECENT_GAMES);
    }
    await this.saveRecentGames();
  }

  /** 收藏列表按收藏时间倒序返回：favoriteTitleIds 插入序保序持久化，末尾为最新收藏 */
  getFavoriteGames(games: GameInfo[]): GameInfo[] {
    const order = new Map<string, number>();
    let index = 0;
    this.favoriteTitleIds.forEach((titleId: string) => { order.set(titleId, index++); });
    return games
      .filter((game: GameInfo) => this.isFavorite(game))
      .sort((a: GameInfo, b: GameInfo) =>
        (order.get(normalizeTitleId(b.titleId)) ?? -1) - (order.get(normalizeTitleId(a.titleId)) ?? -1));
  }

  isFavorite(game: GameInfo): boolean {
    return this.isFavoriteTitleId(game.titleId);
  }

  isFavoriteTitle(titleId: string): boolean {
    return this.isFavoriteTitleId(titleId);
  }

  async setFavorite(game: GameInfo, favorite: boolean): Promise<boolean> {
    const changed = await this.setFavoriteTitle(game.titleId, favorite, game.path);
    if (changed) {
      game.favorite = favorite;
    }
    return changed;
  }

  async setFavoriteTitle(titleIdValue: string, favorite: boolean, path: string = ''): Promise<boolean> {
    const titleId = normalizeTitleId(titleIdValue);
    if (!titleId) {
      return false;
    }

    if (favorite) {
      this.favoriteTitleIds.add(titleId);
    } else {
      this.favoriteTitleIds.delete(titleId);
    }

    let recentChanged = false;
    this.recentGames.forEach((recent: GameInfo) => {
      if (normalizeTitleId(recent.titleId) === titleId || (!!path && recent.path === path)) {
        recent.favorite = favorite;
        recentChanged = true;
      }
    });

    await this.saveFavoriteTitleIds();
    if (recentChanged) {
      await this.saveRecentGames();
    }
    return true;
  }

  async toggleFavorite(game: GameInfo): Promise<boolean> {
    return this.setFavorite(game, !this.isFavorite(game));
  }

  async toggleFavoriteTitle(titleId: string, path: string = ''): Promise<boolean> {
    return this.setFavoriteTitle(titleId, !this.isFavoriteTitle(titleId), path);
  }

  async resetPlayTime(path: string, uri: string = '', titleIdValue: string = ''): Promise<boolean> {
    let changed = false;
    let titleId = normalizeTitleId(titleIdValue);
    this.recentGames.forEach((game: GameInfo) => {
      if (game.path === path || (!!uri && game.uri === uri)) {
        game.lastPlayed = 0;
        game.playCount = 0;
        game.playTimeMs = 0;
        if (!titleId) {
          titleId = normalizeTitleId(game.titleId);
        }
        changed = true;
      }
    });
    if (changed) {
      await this.saveRecentGames();
    }
    changed = PlayTimeManager.getInstance().resetStats(titleId, path) || changed;
    return changed;
  }

  /** 以 PlayTimeManager 为唯一来源回填展示字段；无记录时保留最近列表里的持久化值 */
  refreshPlayStats(games: GameInfo[]): GameInfo[] {
    const playTimeManager = PlayTimeManager.getInstance();
    return games.map((game: GameInfo) => {
      const stats = playTimeManager.getStats(game.titleId, game.path);
      if (stats) {
        game.lastPlayed = stats.lastPlayed;
        game.playCount = stats.playCount;
        game.playTimeMs = stats.totalPlayTimeMs;
      }
      return game;
    });
  }

  async clearRecentGames(): Promise<void> {
    this.recentGames = [];
    await this.saveRecentGames();
  }

  async removeFromRecentGames(path: string, uri: string = ''): Promise<void> {
    const beforeCount = this.recentGames.length;
    this.recentGames = this.recentGames.filter((game: GameInfo) => {
      if (game.path === path) {
        return false;
      }
      if (uri && game.uri === uri) {
        return false;
      }
      return true;
    });
    if (this.recentGames.length !== beforeCount) {
      await this.saveRecentGames();
    }
  }

  async scanDirectory(dirPath: string, onProgress?: (done: number, total: number) => void): Promise<GameInfo[]> {
    const entries: RomEntry[] = [];
    this.collectRootEntries(dirPath, entries);

    const romsDir = `${dirPath}/${ROMS_SUBDIR}`;
    if (this.pathExists(romsDir)) {
      this.collectRomEntries(romsDir, 0, MAX_SCAN_DEPTH, entries);
    }

    console.info(`[AzaharGameManager] scan start: ${dirPath}, entries=${entries.length}`);
    await this.installPendingCiaEntries(entries.filter((entry: RomEntry) => this.isCiaFile(entry.fileName)));

    const games: GameInfo[] = [];
    const seenPaths: Set<string> = new Set<string>();
    const batchSize = 40;
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      if (!this.isCiaFile(entry.fileName) && !seenPaths.has(entry.filePath)) {
        games.push(this.createGameInfo('', entry.filePath, 0, 0));
        seenPaths.add(entry.filePath);
      }
      if (onProgress && ((i + 1) % batchSize === 0 || i + 1 === entries.length)) {
        onProgress(i + 1, entries.length);
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
    }

    for (const installedValue of AzaharNative.getInstalledGamePaths()) {
      const installedEntry = this.parseInstalledGameEntry(installedValue);
      if (!installedEntry || seenPaths.has(installedEntry.path)) {
        continue;
      }
      const installedGame = this.createGameInfo('', installedEntry.path, 0, 0, true,
        installedEntry.mediaType);
      if (!this.isLaunchableInstalledGame(installedGame)) {
        console.warn(`[AzaharGameManager] skip installed title: ${installedEntry.path}, validTitle=${installedGame.titleId.length > 0}, encrypted=${installedGame.encrypted}, visible=${installedGame.visible}`);
        continue;
      }
      games.push(installedGame);
      seenPaths.add(installedEntry.path);
    }

    console.info(`[AzaharGameManager] scan done: ${dirPath}, games=${games.length}`);
    return games;
  }

  // 只建前端独有目录：roms 是游戏库扫描根、covers 是封面缓存。
  // 核心目录（states/cheats/nand/sdmc/dump/load 等）由 core 的 runtime_paths 统一创建；
  // 存储页目录行点击时 openDirectory 会 ensureDirectory 兜底，未启动核心也能打开。
  ensureLibraryDirectories(downloadDir: string): void {
    if (!downloadDir) {
      return;
    }

    this.ensureDirExists(`${downloadDir}/${ROMS_SUBDIR}`);
    this.ensureDirExists(`${downloadDir}/covers`);
  }

  getSupportedSuffixFilters(): string[] {
    if (this.supportedExtensions.length > 0) {
      const filters: string[] = [];
      for (const ext of this.supportedExtensions) {
        filters.push(ext.toLowerCase());
        filters.push(ext.toUpperCase());
      }
      return filters;
    }
    return ['.3ds', '.3DS', '.cci', '.CCI', '.cxi', '.CXI', '.3dsx', '.3DSX', '.elf', '.ELF', '.axf', '.AXF', '.app', '.APP'];
  }

  getInstallableSuffixFilters(): string[] {
    const filters = this.getSupportedSuffixFilters();
    filters.push('.cia');
    filters.push('.CIA');
    return filters;
  }

  isCiaPath(path: string): boolean {
    return this.isCiaFile(path);
  }

  isInstalledTitlePath(path: string): boolean {
    const lowerPath = path.toLowerCase();
    return lowerPath.endsWith('.app') && lowerPath.includes('/content/') &&
      (lowerPath.includes('/title/00040000/') || lowerPath.includes('/title/00040002/') ||
        lowerPath.includes('/title/00040010/'));
  }

  async installCiaFile(path: string): Promise<AzaharCIAInstallStatus> {
    if (!this.isCiaFile(path)) {
      return AzaharCIAInstallStatus.ErrorInvalid;
    }

    const key = this.getCiaInstallKey(path);
    if (this.installedCiaKeys.has(key)) {
      return AzaharCIAInstallStatus.Success;
    }

    const status = AzaharNative.installCIA(path);
    if (status === AzaharCIAInstallStatus.Success) {
      this.installedCiaKeys.add(key);
      // 同时记一条 tid|titleId|源文件名 旁路条目：安装后内部内容名（00000000.app）
      // 丢失原始文件名，文件名来源显示时按 titleId 反查
      const titleId = normalizeTitleId(AzaharNative.getGameMetadata(path).titleId);
      if (titleId) {
        this.installedCiaKeys.add(`tid|${titleId}|${this.extractGameName(this.extractFileName(path))}`);
      }
      await this.saveInstalledCiaKeys();
    }
    return status;
  }

  /**
   * 删除属于指定 titleId 的 .cia 安装源文件（收集范围与游戏扫描一致：下载根 + roms/ 递归）。
   * 按 CIA 元数据 titleId 匹配而非文件名，避免同名/改名文件误删；扫描会静默自动安装，
   * 删除游戏时必须连带清掉，否则残留文件既不会重装也无法再手动安装。
   */
  deleteCiaFilesForTitle(dirPath: string, titleId: string): CiaDeleteResult {
    const result: CiaDeleteResult = { deleted: 0, failed: 0 };
    const target = normalizeTitleId(titleId);
    if (!dirPath || !target) {
      return result;
    }
    const entries: RomEntry[] = [];
    this.collectRootEntries(dirPath, entries);
    const romsDir = `${dirPath}/${ROMS_SUBDIR}`;
    if (this.pathExists(romsDir)) {
      this.collectRomEntries(romsDir, 0, MAX_SCAN_DEPTH, entries);
    }
    for (const entry of entries) {
      if (!this.isCiaFile(entry.fileName)) {
        continue;
      }
      let entryTitleId = '';
      try {
        entryTitleId = normalizeTitleId(AzaharNative.getGameMetadata(entry.filePath).titleId);
      } catch (_error) {
        continue;
      }
      if (entryTitleId !== target) {
        continue;
      }
      try {
        fileIo.unlinkSync(entry.filePath);
        result.deleted += 1;
      } catch (_error) {
        result.failed += 1;
      }
    }
    return result;
  }

  async getGameIcon(path: string): Promise<image.PixelMap | null> {
    const cached = this.iconCache.get(path);
    if (cached) {
      return cached;
    }

    const metadata = AzaharNative.getGameMetadata(path);
    if (!metadata.hasIcon || (!metadata.iconRgb565 && !metadata.icon) || metadata.iconWidth <= 0 || metadata.iconHeight <= 0) {
      console.warn(`[AzaharGameManager] no icon metadata: ${path}, valid=${metadata.valid}, encrypted=${metadata.encrypted}, fileType=${metadata.fileType}, status=${metadata.iconStatus}`);
      return null;
    }

    let pixelMap = await this.createIconPixelMap(path, metadata.icon, metadata.iconWidth,
      metadata.iconHeight, image.PixelMapFormat.RGBA_8888, 4, 'rgba');
    if (!pixelMap) {
      pixelMap = await this.createIconPixelMap(path, metadata.iconRgb565, metadata.iconWidth,
        metadata.iconHeight, image.PixelMapFormat.RGB_565, 2, 'rgb565');
    }
    if (pixelMap) {
      this.iconCache.set(path, pixelMap);
      return pixelMap;
    }

    return null;
  }

  private async createIconPixelMap(path: string, source: ArrayBuffer | undefined, width: number, height: number,
    srcPixelFormat: image.PixelMapFormat, bytesPerPixel: number, label: string): Promise<image.PixelMap | null> {
    if (!source) {
      return null;
    }

    const expectedBytes = width * height * bytesPerPixel;
    if (source.byteLength < expectedBytes) {
      console.warn(`[AzaharGameManager] ${label} icon buffer too small: ${path}, ${source.byteLength}/${expectedBytes}`);
      return null;
    }

    const pixels = new Uint8Array(expectedBytes);
    pixels.set(new Uint8Array(source).subarray(0, expectedBytes));
    const options: image.InitializationOptions = {
      size: { width, height },
      srcPixelFormat,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.UNPREMUL
    };
    try {
      const pm = typeof image.createPixelMapFromPixels === 'function' ?
        await image.createPixelMapFromPixels(pixels.buffer as ArrayBuffer, options) :
        await image.createPixelMap(pixels.buffer as ArrayBuffer, options);
      return pm;
    } catch (error) {
      console.error(`[AzaharGameManager] create ${label} icon failed: ${path}, ${JSON.stringify(error)}`);
      return null;
    }
  }

  // 同步读取已缓存的封面/图标：详情页进页时做首帧种子，避免占位块闪烁；未命中返回 null 走异步加载
  getCachedCover(path: string): image.PixelMap | null {
    return this.coverCache.get(path) ?? null;
  }

  getCachedIcon(path: string): image.PixelMap | null {
    return this.iconCache.get(path) ?? null;
  }

  async getGameCover(game: GameInfo, downloadDir: string): Promise<image.PixelMap | null> {
    if (!downloadDir) {
      return null;
    }

    const cached = this.coverCache.get(game.path);
    if (cached) {
      return cached;
    }

    // 封面统一按 productCode -> coverId 存取（covers/<coverId>/boxFront*.jpg）：
    // 此处只读内存与本地 covers/ 文件
    const coverId = getCoverId(game.productCode);
    if (!coverId) {
      return null;
    }
    const pixelMap = await CoverManager.getInstance().getCachedCover(coverId, 'normal');
    if (!pixelMap) {
      return null;
    }
    await this.scaleCoverForUi(pixelMap);
    this.coverCache.set(game.path, pixelMap);
    return pixelMap;
  }

  clearGameCoverCache(path?: string): void {
    if (path) {
      this.coverCache.delete(path);
      return;
    }
    this.coverCache.clear();
  }

  private collectRootEntries(dirPath: string, out: RomEntry[]): void {
    try {
      const files = fileIo.listFileSync(dirPath);
      for (const fileName of files) {
        if (this.isSupportedRom(fileName) || this.isCiaFile(fileName)) {
          out.push(new RomEntry(`${dirPath}/${fileName}`, fileName));
        }
      }
    } catch (error) {
      console.error(`[AzaharGameManager] scan root failed: ${(error as Error).message}`);
    }
  }

  private async scaleCoverForUi(pixelMap: image.PixelMap): Promise<void> {
    const info = pixelMap.getImageInfoSync();
    const maxDimension = Math.max(info.size.width, info.size.height);
    if (maxDimension <= MAX_COVER_DIMENSION) {
      return;
    }

    const scale = MAX_COVER_DIMENSION / maxDimension;
    await pixelMap.scale(scale, scale);
  }

  private collectRomEntries(dirPath: string, currentDepth: number, maxDepth: number, out: RomEntry[]): void {
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(dirPath);
    } catch (_error) {
      return;
    }

    for (const entryName of entries) {
      if (entryName.startsWith('.')) {
        continue;
      }
      const entryPath = `${dirPath}/${entryName}`;
      if (this.isSupportedRom(entryName) || this.isCiaFile(entryName)) {
        out.push(new RomEntry(entryPath, entryName));
      } else if (currentDepth < maxDepth) {
        try {
          const stat = fileIo.statSync(entryPath);
          if (stat.isDirectory() && !stat.isSymbolicLink()) {
            this.collectRomEntries(entryPath, currentDepth + 1, maxDepth, out);
          }
        } catch (_error) {
          // 扫描中条目可能被并发删除/无权限，跳过该条目
        }
      }
    }
  }

  private createGameInfo(uri: string, path: string, lastPlayed: number, playCount: number,
    installed: boolean = false, mediaType: number = MEDIA_TYPE_GAME_CARD): GameInfo {
    const appInfo = AzaharNative.getAppInfo(path);
    const metadata: AzaharGameMetadata = AzaharNative.getGameMetadata(path);
    const fileName = appInfo.fileName || this.extractFileName(path);
    const metadataName = metadata.longTitle || metadata.shortTitle;
    const stats = PlayTimeManager.getInstance().getStats(metadata.titleId, path);
    const isInstalled = installed || this.isInstalledTitlePath(path);
    if (!metadata.hasIcon) {
      console.warn(`[AzaharGameManager] metadata without icon: ${fileName}, ext=${appInfo.extension}, valid=${metadata.valid}, encrypted=${metadata.encrypted}, fileType=${metadata.fileType}, status=${metadata.iconStatus}`);
    }
    return {
      uri,
      path,
      name: metadataName || this.extractGameName(fileName),
      fileName,
      extension: appInfo.extension,
      titleId: metadata.titleId,
      shortTitle: metadata.shortTitle,
      longTitle: metadata.longTitle,
      publisher: metadata.publisher,
      regions: metadata.regions,
      productCode: metadata.productCode || '',
      extdataId: metadata.extdataId,
      fileType: metadata.fileType,
      encrypted: metadata.encrypted,
      insertable: metadata.insertable,
      inserted: false,
      systemTitle: metadata.systemTitle,
      visible: metadata.visible,
      hasIcon: metadata.hasIcon,
      installed: isInstalled,
      mediaType: isInstalled ? mediaType : MEDIA_TYPE_GAME_CARD,
      lastPlayed: lastPlayed > 0 ? lastPlayed : (stats?.lastPlayed ?? 0),
      playCount: playCount > 0 ? playCount : (stats?.playCount ?? 0),
      playTimeMs: stats?.totalPlayTimeMs ?? 0,
      favorite: this.isFavoriteTitleId(metadata.titleId)
    };
  }

  private async loadFavoriteTitleIds(): Promise<void> {
    if (!this.prefs) {
      return;
    }
    try {
      const json = await this.prefs.get(KEY_FAVORITE_TITLE_IDS, '[]') as string;
      const ids = JSON.parse(json) as string[];
      this.favoriteTitleIds = new Set<string>(ids.map((id: string) => normalizeTitleId(id)).filter((id: string) => id.length > 0));
    } catch (_error) {
      this.favoriteTitleIds = new Set<string>();
    }
  }

  private async loadInstalledCiaKeys(): Promise<void> {
    if (!this.prefs) {
      return;
    }
    try {
      const json = await this.prefs.get(KEY_INSTALLED_CIA_KEYS, '[]') as string;
      const keys = JSON.parse(json) as string[];
      this.installedCiaKeys = new Set<string>(keys);
    } catch (_error) {
      this.installedCiaKeys = new Set<string>();
    }
  }

  private async saveInstalledCiaKeys(): Promise<void> {
    if (!this.prefs) {
      return;
    }
    await this.prefs.put(KEY_INSTALLED_CIA_KEYS, JSON.stringify(Array.from(this.installedCiaKeys.values())));
    await this.prefs.flush();
  }

  /** 统一游戏显示名：自定义名 > (文件名|元数据) 来源偏好 > game.name */
  getDisplayName(game: GameInfo): string {
    const metadataName = game.name;
    const source = SettingsManager.getInstance().getString(KEY_GAME_NAME_SOURCE);
    const fallback = source === 'filename'
      ? (GameManager.isInternalInstallName(game)
        ? (this.getInstalledSourceName(game.titleId) || metadataName)
        : this.extractGameName(game.fileName))
      : metadataName;
    return GameConfigManager.getInstance().getDisplayName(game.path, fallback);
  }

  /** 已安装 CIA 标题的 fileName 是内部内容文件名（如 00000000.app），非用户可见文件名 */
  static isInternalInstallName(game: GameInfo): boolean {
    return !!game.installed && /^[0-9a-fA-F]+(\.[0-9a-zA-Z]+)?$/.test(game.fileName);
  }

  /** 已安装 CIA 的原始文件名（无后缀），按 titleId 反查 tid| 旁路条目；未经过本应用安装的返回 '' */
  getInstalledSourceName(titleId: string): string {
    const tid = normalizeTitleId(titleId);
    if (!tid) {
      return '';
    }
    const prefix = `tid|${tid}|`;
    for (const key of this.installedCiaKeys) {
      if (key.startsWith(prefix)) {
        return key.substring(prefix.length);
      }
    }
    return '';
  }

  private async saveFavoriteTitleIds(): Promise<void> {
    if (!this.prefs) {
      return;
    }
    await this.prefs.put(KEY_FAVORITE_TITLE_IDS, JSON.stringify(Array.from(this.favoriteTitleIds.values())));
    await this.prefs.flush();
  }

  private async loadRecentGames(): Promise<void> {
    if (!this.prefs) {
      return;
    }

    try {
      const json = await this.prefs.get(KEY_RECENT_GAMES, '[]') as string;
      const parsed = JSON.parse(json) as GameInfo[];
      this.recentGames = parsed.map((game: GameInfo) => this.normalizeGameInfo(game))
        .filter((game: GameInfo) => this.isUsableRecentGame(game));
      if (this.recentGames.length !== parsed.length) {
        await this.saveRecentGames();
      }
    } catch (_error) {
      this.recentGames = [];
    }
  }

  private normalizeGameInfo(game: GameInfo): GameInfo {
    const path = game.path || '';
    const installed = !!game.installed || this.isInstalledTitlePath(path);
    const mediaType = installed ? this.normalizeMediaType(Number(game.mediaType || this.inferInstalledMediaType(path))) :
      MEDIA_TYPE_GAME_CARD;
    const normalized: GameInfo = {
      uri: game.uri || '',
      path,
      name: game.name || this.extractGameName(game.fileName || game.path || ''),
      fileName: game.fileName || this.extractFileName(game.path || ''),
      extension: game.extension || '',
      titleId: game.titleId || '',
      shortTitle: game.shortTitle || '',
      longTitle: game.longTitle || '',
      publisher: game.publisher || '',
      regions: game.regions || '',
      productCode: game.productCode || '',
      extdataId: game.extdataId || '',
      fileType: game.fileType || '',
      encrypted: !!game.encrypted,
      insertable: !!game.insertable,
      inserted: !!game.inserted,
      systemTitle: !!game.systemTitle,
      visible: !!game.visible,
      hasIcon: !!game.hasIcon,
      installed,
      mediaType,
      lastPlayed: Number(game.lastPlayed || 0),
      playCount: Number(game.playCount || 0),
      playTimeMs: Number(game.playTimeMs || 0),
      favorite: this.isFavoriteTitleId(game.titleId || '')
    };
    return normalized;
  }

  private isUsableRecentGame(game: GameInfo): boolean {
    if (!game.path || this.isCiaFile(game.path)) {
      return false;
    }
    if (game.installed && !this.isLaunchableInstalledGame(game)) {
      return false;
    }
    return this.isSupportedRom(game.path) && this.pathExists(game.path);
  }

  private isLaunchableInstalledGame(game: GameInfo): boolean {
    if (!game.installed) {
      return true;
    }
    return game.titleId.length > 0 && !game.encrypted;
  }

  private parseInstalledGameEntry(value: string): InstalledGameEntry | null {
    if (!value) {
      return null;
    }
    const separator = value.lastIndexOf('|');
    if (separator < 0) {
      return {
        path: value,
        mediaType: this.inferInstalledMediaType(value)
      };
    }
    const path = value.substring(0, separator);
    const mediaType = Number(value.substring(separator + 1));
    if (!path) {
      return null;
    }
    return {
      path,
      mediaType: this.normalizeMediaType(mediaType)
    };
  }

  private normalizeMediaType(mediaType: number): number {
    if (mediaType === MEDIA_TYPE_NAND || mediaType === MEDIA_TYPE_SDMC) {
      return mediaType;
    }
    return MEDIA_TYPE_GAME_CARD;
  }

  private inferInstalledMediaType(path: string): number {
    const lowerPath = path.toLowerCase();
    if (lowerPath.includes('/nand/') || lowerPath.includes('/title/00040010/')) {
      return MEDIA_TYPE_NAND;
    }
    if (lowerPath.includes('/sdmc/') || lowerPath.includes('/nintendo 3ds/')) {
      return MEDIA_TYPE_SDMC;
    }
    return MEDIA_TYPE_GAME_CARD;
  }

  private async saveRecentGames(): Promise<void> {
    if (!this.prefs) {
      return;
    }
    await this.prefs.put(KEY_RECENT_GAMES, JSON.stringify(this.recentGames));
    await this.prefs.flush();
  }

  private ensureDirExists(path: string): void {
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
    } catch (_error) {
      try {
        fileIo.mkdirSync(path, true);
      } catch (error) {
        console.error(`[AzaharGameManager] mkdir failed: ${path}, ${(error as Error).message}`);
      }
    }
  }

  private pathExists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (_error) {
      return false;
    }
  }

  private isSupportedRom(fileName: string): boolean {
    const lowerName = fileName.toLowerCase();
    const extensions = this.supportedExtensions.length > 0 ? this.supportedExtensions : ['.3ds', '.cci', '.cxi', '.3dsx', '.elf', '.axf', '.app'];
    return extensions.some((ext: string) => lowerName.endsWith(ext.toLowerCase()));
  }

  private isCiaFile(fileName: string): boolean {
    return fileName.toLowerCase().endsWith('.cia');
  }

  private getCiaInstallKey(path: string): string {
    try {
      const stat = fileIo.statSync(path);
      return `${path}|${stat.size}|${stat.mtime}`;
    } catch (_error) {
      return path;
    }
  }

  private async installPendingCiaEntries(entries: RomEntry[]): Promise<void> {
    let changed = false;
    for (const entry of entries) {
      const key = this.getCiaInstallKey(entry.filePath);
      if (this.installedCiaKeys.has(key)) {
        continue;
      }

      console.info(`[AzaharGameManager] auto installing CIA: ${entry.filePath}`);
      const status = await this.installCiaFile(entry.filePath);
      if (status === AzaharCIAInstallStatus.Success) {
        changed = true;
        console.info(`[AzaharGameManager] auto install CIA success: ${entry.filePath}`);
      } else {
        console.error(`[AzaharGameManager] auto install CIA failed: ${entry.filePath}, status=${status}`);
      }
    }
    if (changed) {
      await this.saveInstalledCiaKeys();
    }
  }

  private extractFileName(path: string): string {
    const slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  private extractGameName(fileName: string): string {
    const dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  private isFavoriteTitleId(titleId: string): boolean {
    const normalized = normalizeTitleId(titleId);
    return normalized.length > 0 && this.favoriteTitleIds.has(normalized);
  }
}

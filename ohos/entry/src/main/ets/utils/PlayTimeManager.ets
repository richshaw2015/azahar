/**
 * 游戏游玩统计管理器。
 *
 * 只统计模拟器实际处于运行状态的真实经过时间：暂停菜单、切后台和锁屏期间不计时。
 * 身份 key 以 titleId 优先（title:<TITLEID>），无 titleId 时回退 ROM 路径
 * （path:<encodeURIComponent(path)>）；之后拿到 titleId 时同路径的 path: 记录
 * 会被合并进 title: 记录。存储走前端 preferences，不再使用 native 的 play_time.bin。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { I18n } from './I18nManager';

const DOMAIN = 0x0000;
const TAG = '[PlayTimeManager]';
const PREFERENCES_NAME = 'azahar_play_stats';
const KEY_PLAY_STATS = 'play_stats_v1';
const KEY_LEGACY_SEED_COMPLETE = 'legacy_seed_complete_v1';
const TITLE_KEY_PREFIX = 'title:';
const PATH_KEY_PREFIX = 'path:';
const CHECKPOINT_INTERVAL_MS = 60_000;

/** titleId 归一化规则的唯一实现（GameManager 等处复用，不再各自私拷贝） */
export function normalizeTitleId(titleId: string): string {
  return titleId.trim().toUpperCase();
}

/** 统计身份 key：titleId 归一化后非空则按标题，否则按 ROM 路径 */
export function makePlayStatsKey(titleId: string, romPath: string): string {
  const normalizedTitleId = normalizeTitleId(titleId);
  if (normalizedTitleId) {
    return `${TITLE_KEY_PREFIX}${normalizedTitleId}`;
  }
  return romPath ? `${PATH_KEY_PREFIX}${encodeURIComponent(romPath)}` : '';
}

export interface GamePlayStats {
  statsKey: string;
  romPath: string;
  totalPlayTimeMs: number;
  lastPlayed: number;
  playCount: number;
}

/** 旧版最近列表中可迁移的游玩字段 */
export class LegacyPlayRecord {
  path: string;
  lastPlayed: number;
  playCount: number;

  constructor(path: string, lastPlayed: number, playCount: number) {
    this.path = path;
    this.lastPlayed = lastPlayed;
    this.playCount = playCount;
  }
}

interface ActivePlaySession {
  statsKey: string;
  romPath: string;
  running: boolean;
  segmentStartedAt: number;
}

export interface PlayTimeParts {
  hours: number;
  minutes: number;
  lessThanMinute: boolean;
}

export function getPlayTimeParts(totalPlayTimeMs: number): PlayTimeParts {
  const safeMs = Math.max(0, Math.floor(totalPlayTimeMs));
  const totalMinutes = Math.floor(safeMs / 60_000);
  return {
    hours: Math.floor(totalMinutes / 60),
    minutes: totalMinutes % 60,
    lessThanMinute: safeMs > 0 && totalMinutes === 0,
  };
}

export function formatPlayTime(totalPlayTimeMs: number, hasStats: boolean = true): string {
  if (!hasStats) {
    return '';
  }
  const parts = getPlayTimeParts(totalPlayTimeMs);
  if (parts.lessThanMinute) {
    return I18n.t('play_time_less_than_minute');
  }
  if (parts.hours <= 0) {
    return I18n.tf1('duration_minutes_fmt', 'minutes', parts.minutes);
  }
  if (parts.minutes <= 0) {
    return I18n.tf1('duration_hours_fmt', 'hours', parts.hours);
  }
  return I18n.tf2('duration_hours_minutes_fmt', 'hours', parts.hours, 'minutes', parts.minutes);
}

/** 列表副标题用：带“游玩”前缀的简短时间文案（不足 1 分钟按 1 分钟显示） */
export function formatPlayTimeSummary(totalPlayTimeMs: number): string {
  if (totalPlayTimeMs <= 0) {
    return '';
  }
  const parts = getPlayTimeParts(totalPlayTimeMs);
  if (parts.hours <= 0) {
    return I18n.tf1('play_minutes_fmt', 'minutes', Math.max(1, parts.minutes));
  }
  if (parts.minutes <= 0) {
    return I18n.tf1('play_hours_fmt', 'hours', parts.hours);
  }
  return I18n.tf2('play_hours_minutes_fmt', 'hours', parts.hours, 'minutes', parts.minutes);
}

let cachedRelativeFormatter: Intl.RelativeTimeFormat | null = null;
let cachedRelativeLocale: string = '';

/** RelativeTimeFormat 构造不便宜，副标题逐条目调用，按 locale 缓存一个 */
function getRelativeTimeFormatter(): Intl.RelativeTimeFormat {
  const locale = I18n.getLocaleTag();
  if (!cachedRelativeFormatter || cachedRelativeLocale !== locale) {
    cachedRelativeFormatter = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' });
    cachedRelativeLocale = locale;
  }
  return cachedRelativeFormatter;
}

/** 相对时间文案：“现在”“3 分钟前”“昨天”“2 周前”；timestamp<=0 显示从未游玩 */
export function formatLastPlayed(timestamp: number): string {
  if (timestamp <= 0) {
    return I18n.t('never_played');
  }
  const diffMs = Math.max(0, Date.now() - timestamp);
  const seconds = Math.floor(diffMs / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);
  const formatter = getRelativeTimeFormatter();
  let text: string;
  if (seconds < 60) {
    text = formatter.format(0, 'second');
  } else if (minutes < 60) {
    text = formatter.format(-minutes, 'minute');
  } else if (hours < 24) {
    text = formatter.format(-hours, 'hour');
  } else if (days < 7) {
    text = formatter.format(-days, 'day');
  } else if (days < 30) {
    text = formatter.format(-Math.floor(days / 7), 'week');
  } else if (days < 365) {
    text = formatter.format(-Math.floor(days / 30), 'month');
  } else {
    text = formatter.format(-Math.floor(days / 365), 'year');
  }
  // zh 的 CLDR 相对时间没有数字与单位间空格（"6分钟前"），补成 "6 分钟前"，与 "${n} 分钟" 资源串一致
  return cachedRelativeLocale.startsWith('zh') ? text.replace(/(\d+)(?=[^\d\s])/g, '$1 ') : text;
}

export class PlayTimeManager {
  private static instance: PlayTimeManager | null = null;
  private dataPreferences: preferences.Preferences | null = null;
  private records: Record<string, GamePlayStats> = {};
  private activeSession: ActivePlaySession | null = null;
  private checkpointTimerId: number = -1;
  private initialized: boolean = false;
  private legacySeedComplete: boolean = false;

  private constructor() {}

  static getInstance(): PlayTimeManager {
    if (!PlayTimeManager.instance) {
      PlayTimeManager.instance = new PlayTimeManager();
    }
    return PlayTimeManager.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }
    try {
      this.dataPreferences = await preferences.getPreferences(context, PREFERENCES_NAME);
      const json = this.dataPreferences.getSync(KEY_PLAY_STATS, '{}') as string;
      this.legacySeedComplete = this.dataPreferences.getSync(KEY_LEGACY_SEED_COMPLETE, false) as boolean;
      const parsed = JSON.parse(json) as Record<string, GamePlayStats>;
      this.records = this.sanitizeRecords(parsed);
      this.initialized = true;
      hilog.info(DOMAIN, TAG, 'Loaded %{public}d play stat record(s)', Object.keys(this.records).length);
    } catch (err) {
      this.records = {};
      this.initialized = true;
      hilog.error(DOMAIN, TAG, 'Failed to load play stats: %{public}s', (err as Error).message);
    }
  }

  /** 一次性迁移：把最近列表持久化的最后游玩时间/启动次数种入独立统计 */
  seedLegacyRecords(records: LegacyPlayRecord[]): void {
    if (this.legacySeedComplete) {
      return;
    }
    for (const legacy of records) {
      if (!legacy.path || (legacy.lastPlayed <= 0 && legacy.playCount <= 0)) {
        continue;
      }
      if (this.findRecordKeyByPath(legacy.path)) {
        continue;
      }
      const key = makePlayStatsKey('', legacy.path);
      this.records[key] = {
        statsKey: key,
        romPath: legacy.path,
        totalPlayTimeMs: 0,
        lastPlayed: Math.max(0, legacy.lastPlayed),
        playCount: Math.max(0, legacy.playCount),
      };
    }
    this.legacySeedComplete = true;
    this.persist();
  }

  /** 先按 titleId key 查，再按 path key 回落，最后按 romPath 字段兜底 */
  getStats(titleId: string, romPath: string): GamePlayStats | null {
    const titleKey = makePlayStatsKey(titleId, '');
    if (titleKey && this.records[titleKey]) {
      return this.copyStats(this.records[titleKey]);
    }
    const pathKey = makePlayStatsKey('', romPath);
    if (pathKey && this.records[pathKey]) {
      return this.copyStats(this.records[pathKey]);
    }
    const keyByPath = this.findRecordKeyByPath(romPath);
    return keyByPath ? this.copyStats(this.records[keyByPath]) : null;
  }

  /** 删除指定游戏的统计记录（title/path 两种身份都清），返回是否有记录被删 */
  resetStats(titleId: string, romPath: string): boolean {
    const titleKey = makePlayStatsKey(titleId, '');
    const pathKey = makePlayStatsKey('', romPath);
    let changed = false;
    const retained: Record<string, GamePlayStats> = {};
    for (const key of Object.keys(this.records)) {
      const record = this.records[key];
      if (key === titleKey || key === pathKey || (!!romPath && record.romPath === romPath)) {
        changed = true;
        continue;
      }
      retained[key] = record;
    }
    if (changed) {
      this.records = retained;
      this.persist();
    }
    return changed;
  }

  /** 成功启动模拟器后创建会话并开始首个计时段；重复调用会先结算旧会话 */
  startSession(titleId: string, romPath: string): void {
    const statsKey = makePlayStatsKey(titleId, romPath);
    if (!statsKey || !romPath) {
      return;
    }
    if (this.activeSession) {
      this.finishSession();
    }

    const stats = this.adoptStableIdentity(statsKey, romPath);
    stats.playCount += 1;
    stats.lastPlayed = Date.now();
    stats.romPath = romPath;
    this.records[statsKey] = stats;
    this.activeSession = {
      statsKey,
      romPath,
      running: true,
      segmentStartedAt: this.getMonotonicTime(),
    };
    this.startCheckpointTimer();
    this.persist();
  }

  pauseSession(): void {
    if (!this.activeSession || !this.activeSession.running) {
      return;
    }
    this.commitActiveSegment();
    this.activeSession.running = false;
    this.stopCheckpointTimer();
    this.persist();
  }

  resumeSession(): void {
    if (!this.activeSession || this.activeSession.running) {
      return;
    }
    this.activeSession.segmentStartedAt = this.getMonotonicTime();
    this.activeSession.running = true;
    this.startCheckpointTimer();
  }

  finishSession(): void {
    if (!this.activeSession) {
      return;
    }
    if (this.activeSession.running) {
      this.commitActiveSegment();
    }
    this.stopCheckpointTimer();
    this.activeSession = null;
    this.persist();
  }

  private checkpoint(): void {
    if (!this.activeSession || !this.activeSession.running) {
      return;
    }
    this.commitActiveSegment();
    this.persist();
  }

  private commitActiveSegment(): void {
    const session = this.activeSession;
    if (!session || !session.running) {
      return;
    }
    const now = this.getMonotonicTime();
    const elapsed = Math.max(0, now - session.segmentStartedAt);
    const stats = this.records[session.statsKey];
    if (stats && elapsed > 0) {
      stats.totalPlayTimeMs += elapsed;
    }
    session.segmentStartedAt = now;
  }

  /** 稳定身份合并：同 romPath 的 path: 记录在拿到 titleId 后并入 title: 记录（取 max） */
  private adoptStableIdentity(statsKey: string, romPath: string): GamePlayStats {
    const stable = this.records[statsKey];
    const pathKey = this.findRecordKeyByPath(romPath);
    const byPath = pathKey ? this.records[pathKey] : null;

    const merged: GamePlayStats = {
      statsKey,
      romPath,
      totalPlayTimeMs: Math.max(stable?.totalPlayTimeMs ?? 0, byPath?.totalPlayTimeMs ?? 0),
      lastPlayed: Math.max(stable?.lastPlayed ?? 0, byPath?.lastPlayed ?? 0),
      playCount: Math.max(stable?.playCount ?? 0, byPath?.playCount ?? 0),
    };
    if (pathKey && pathKey !== statsKey) {
      const retained: Record<string, GamePlayStats> = {};
      for (const key of Object.keys(this.records)) {
        if (key !== pathKey) {
          retained[key] = this.records[key];
        }
      }
      this.records = retained;
    }
    this.records[statsKey] = merged;
    return merged;
  }

  private findRecordKeyByPath(romPath: string): string {
    if (!romPath) {
      return '';
    }
    for (const key of Object.keys(this.records)) {
      if (this.records[key].romPath === romPath) {
        return key;
      }
    }
    return '';
  }

  private getMonotonicTime(): number {
    return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, false);
  }

  private startCheckpointTimer(): void {
    this.stopCheckpointTimer();
    this.checkpointTimerId = setInterval(() => this.checkpoint(), CHECKPOINT_INTERVAL_MS);
  }

  private stopCheckpointTimer(): void {
    if (this.checkpointTimerId !== -1) {
      clearInterval(this.checkpointTimerId);
      this.checkpointTimerId = -1;
    }
  }

  private persist(): void {
    if (!this.dataPreferences) {
      return;
    }
    try {
      this.dataPreferences.putSync(KEY_PLAY_STATS, JSON.stringify(this.records));
      this.dataPreferences.putSync(KEY_LEGACY_SEED_COMPLETE, this.legacySeedComplete);
      this.dataPreferences.flush().catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'Flush failed: %{public}s', err.message);
      });
      const current = AppStorage.get<number>('playStatsVersion') ?? 0;
      AppStorage.setOrCreate('playStatsVersion', current + 1);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Persist failed: %{public}s', (err as Error).message);
    }
  }

  private sanitizeRecords(data: Record<string, GamePlayStats>): Record<string, GamePlayStats> {
    const result: Record<string, GamePlayStats> = {};
    for (const key of Object.keys(data)) {
      const item = data[key];
      if (!item || typeof item.romPath !== 'string') {
        continue;
      }
      result[key] = {
        statsKey: typeof item.statsKey === 'string' ? item.statsKey : key,
        romPath: item.romPath,
        totalPlayTimeMs: Number.isFinite(item.totalPlayTimeMs) ? Math.max(0, item.totalPlayTimeMs) : 0,
        lastPlayed: Number.isFinite(item.lastPlayed) ? Math.max(0, item.lastPlayed) : 0,
        playCount: Number.isFinite(item.playCount) ? Math.max(0, Math.floor(item.playCount)) : 0,
      };
    }
    return result;
  }

  private copyStats(stats: GamePlayStats): GamePlayStats {
    return {
      statsKey: stats.statsKey,
      romPath: stats.romPath,
      totalPlayTimeMs: stats.totalPlayTimeMs,
      lastPlayed: stats.lastPlayed,
      playCount: stats.playCount,
    };
  }
}

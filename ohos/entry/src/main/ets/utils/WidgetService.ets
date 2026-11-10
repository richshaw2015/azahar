import { formBindingData, formProvider } from '@kit.FormKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { GameConfigManager } from './GameConfigManager';
import { GameInfo, GameManager } from './GameManager';
import { formatPlayTime, PlayTimeManager } from './PlayTimeManager';
import { SettingsManager } from './SettingsManager';
import { ThemeManager } from './ThemeManager';

const WIDGET_DATA_FILE: string = 'widget_data.json';
const FORM_IDS_FILE: string = 'widget_form_ids.json';
const MAX_WIDGET_GAMES: number = 3;
const MAX_COVER_SIZE: number = 512;

export interface WidgetGradient {
  gradientStart: string;
  gradientEnd: string;
}

export function getDefaultWidgetGradient(): WidgetGradient {
  const colors = ThemeManager.getInstance().getCurrentColors();
  return { gradientStart: colors.gradientStart, gradientEnd: colors.gradientEnd };
}

interface WidgetGame {
  name: string;
  path: string;
  cover: string;
  playTime: string;
}

interface WidgetData {
  games: WidgetGame[];
  gradientStart?: string;
  gradientEnd?: string;
}

interface FormIdData {
  formIds: string[];
  dimensions: Record<string, number>;
}

export interface WidgetBindingData {
  cardType: string;
  gameCount: number;
  game0Name: string;
  game0Path: string;
  game0Cover: string;
  game0PlayTime: string;
  game1Name: string;
  game1Path: string;
  game1Cover: string;
  game1PlayTime: string;
  game2Name: string;
  game2Path: string;
  game2Cover: string;
  game2PlayTime: string;
  gradientStart: string;
  gradientEnd: string;
}

export class WidgetService {
  static async refresh(
    context: common.UIAbilityContext,
    gameManager: GameManager,
    allGames?: GameInfo[],
    downloadDir: string = ''
  ): Promise<void> {
    const gameConfigManager = GameConfigManager.getInstance();
    await gameConfigManager.initialize(context);
    const settingsManager = SettingsManager.getInstance();
    if (!settingsManager.isInitialized()) {
      await settingsManager.initialize(context);
    }
    const recentGames = gameManager.getRecentGames().slice(0, MAX_WIDGET_GAMES);
    const selected: GameInfo[] = [...recentGames];
    // 最近游戏不足时从游戏库随机补充（与 nds 卡片行为一致，避免永远是列表头部几个）
    if (selected.length < MAX_WIDGET_GAMES && allGames && allGames.length > 0) {
      const selectedPaths = new Set<string>(selected.map((game: GameInfo) => game.path));
      const candidates = allGames.filter((game: GameInfo) => !selectedPaths.has(game.path));
      for (let i = candidates.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        const tmp = candidates[i];
        candidates[i] = candidates[j];
        candidates[j] = tmp;
      }
      selected.push(...candidates.slice(0, MAX_WIDGET_GAMES - selected.length));
    }
    while (selected.length > 0 && selected.length < MAX_WIDGET_GAMES) {
      selected.push(selected[0]);
    }

    const playTimeManager = PlayTimeManager.getInstance();
    const widgetGames: WidgetGame[] = selected.slice(0, MAX_WIDGET_GAMES).map((game: GameInfo): WidgetGame => {
      const stats = playTimeManager.getStats(game.titleId, game.path);
      const widgetGame: WidgetGame = {
        name: gameManager.getDisplayName(game),
        path: game.path,
        cover: '',
        playTime: stats && stats.totalPlayTimeMs > 0 ? formatPlayTime(stats.totalPlayTimeMs) : ''
      };
      return widgetGame;
    });
    for (let i = 0; i < widgetGames.length; i++) {
      widgetGames[i].cover = await WidgetService.getArtworkBase64(gameManager, selected[i], downloadDir);
    }

    const colors = ThemeManager.getInstance().getCurrentColors();
    const widgetData: WidgetData = {
      games: widgetGames,
      gradientStart: colors.gradientStart,
      gradientEnd: colors.gradientEnd
    };
    WidgetService.writeWidgetData(context.filesDir, widgetData);
    await WidgetService.updateAllForms(context.filesDir, widgetData);
  }

  static buildBindingObject(widgetData: WidgetData, dimension: number): WidgetBindingData {
    const games = widgetData.games;
    const game0 = games.length > 0 ? games[0] : null;
    const game1 = games.length > 1 ? games[1] : null;
    const game2 = games.length > 2 ? games[2] : null;
    return {
      cardType: dimension === 3 ? 'large' : 'small',
      gameCount: games.length,
      game0Name: game0 ? game0.name : '',
      game0Path: game0 ? game0.path : '',
      game0Cover: game0 ? game0.cover : '',
      game0PlayTime: game0 ? game0.playTime : '',
      game1Name: game1 ? game1.name : '',
      game1Path: game1 ? game1.path : '',
      game1Cover: game1 ? game1.cover : '',
      game1PlayTime: game1 ? game1.playTime : '',
      game2Name: game2 ? game2.name : '',
      game2Path: game2 ? game2.path : '',
      game2Cover: game2 ? game2.cover : '',
      game2PlayTime: game2 ? game2.playTime : '',
      gradientStart: widgetData.gradientStart || getDefaultWidgetGradient().gradientStart,
      gradientEnd: widgetData.gradientEnd || getDefaultWidgetGradient().gradientEnd
    };
  }

  static readWidgetData(filesDir: string): WidgetData | null {
    const filePath = `${filesDir}/${WIDGET_DATA_FILE}`;
    try {
      if (!fileIo.accessSync(filePath)) {
        return null;
      }
      const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      try {
        const stat = fileIo.statSync(filePath);
        const buffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buffer);
        return JSON.parse(new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buffer))) as WidgetData;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_error) {
      return null;
    }
  }

  static readFormIds(filesDir: string): FormIdData {
    const filePath = `${filesDir}/${FORM_IDS_FILE}`;
    try {
      if (!fileIo.accessSync(filePath)) {
        return { formIds: [], dimensions: {} };
      }
      const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      try {
        const stat = fileIo.statSync(filePath);
        const buffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buffer);
        return JSON.parse(new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buffer))) as FormIdData;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_error) {
      return { formIds: [], dimensions: {} };
    }
  }

  static writeFormIds(filesDir: string, data: FormIdData): void {
    const filePath = `${filesDir}/${FORM_IDS_FILE}`;
    try {
      const file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(data, null, 2));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      console.error(`WidgetService: write formId data failed: ${(error as Error).message}`);
    }
  }

  static removeFormIdData(data: FormIdData, formId: string): void {
    data.formIds = data.formIds.filter((id: string) => id !== formId);
    const dimensions: Record<string, number> = {};
    for (const key of Object.keys(data.dimensions)) {
      if (key !== formId) {
        dimensions[key] = data.dimensions[key];
      }
    }
    data.dimensions = dimensions;
  }

  private static writeWidgetData(filesDir: string, data: WidgetData): void {
    const filePath = `${filesDir}/${WIDGET_DATA_FILE}`;
    try {
      const file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      console.error(`WidgetService: write widget data failed: ${(error as Error).message}`);
    }
  }

  private static async updateAllForms(filesDir: string, widgetData: WidgetData): Promise<void> {
    const formIdData = WidgetService.readFormIds(filesDir);
    for (const formId of formIdData.formIds) {
      const dimension = formIdData.dimensions[formId] ?? 2;
      const binding = WidgetService.buildBindingObject(widgetData, dimension);
      try {
        await formProvider.updateForm(formId, formBindingData.createFormBindingData(binding));
      } catch (error) {
        const code = (error as Record<string, number>).code;
        if (code === 16501001 || code === 16500050) {
          WidgetService.removeFormIdData(formIdData, formId);
          WidgetService.writeFormIds(filesDir, formIdData);
        }
      }
    }
  }

  private static async getArtworkBase64(gameManager: GameManager, game: GameInfo, downloadDir: string): Promise<string> {
    const cover = await gameManager.getGameCover(game, downloadDir);
    if (cover) {
      const encodedCover = await WidgetService.encodePixelMap(cover, 'image/jpeg', 90);
      if (encodedCover) {
        return encodedCover;
      }
    }

    try {
      const icon = await gameManager.getGameIcon(game.path);
      if (!icon) {
        return '';
      }
      return await WidgetService.encodePixelMap(icon, 'image/png', 100);
    } catch (_error) {
      return '';
    }
  }

  private static async encodePixelMap(pixelMap: image.PixelMap, format: string, quality: number): Promise<string> {
    try {
      const info = pixelMap.getImageInfoSync();
      const maxDimension = Math.max(info.size.width, info.size.height);
      if (maxDimension > MAX_COVER_SIZE) {
        const scale = MAX_COVER_SIZE / maxDimension;
        await pixelMap.scale(scale, scale);
      }

      const packer = image.createImagePacker();
      try {
        const buffer = await packer.packing(pixelMap, { format, quality });
        const base64 = new util.Base64Helper();
        return `data:${format};base64,` + base64.encodeToStringSync(new Uint8Array(buffer));
      } finally {
        packer.release();
      }
    } catch (_error) {
      return '';
    }
  }
}

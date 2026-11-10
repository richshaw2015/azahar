import { AzaharKey } from '../types/AzaharNative';
import { KEY_GAMEPAD_BUTTON_MAP, KEY_GAMEPAD_COMBO } from '../types/SettingsTypes';
import { SettingsManager } from './SettingsManager';

/** 可配置物理键盘映射：一个键码可绑定多个 3DS 按键（多绑定即键盘宏触发源）。
 *  持久化为 SettingsManager 中的 JSON：{ "2042": [0, 2] }（keyCode → AzaharKey 数组）。
 *  GameView 按键事件按持有者集合计数：同一 3DS 按键被多个物理键按住时，
 *  只有最后一个持有者松开才向 core 发 key-up，避免误释放。 */

const SETTING_KEY: string = 'keyboard_key_map';
/** 旧 NB 编号 → NativeButton 迁移完成标记 */
const NB_MIGRATION_FLAG: string = 'gamepad_nb_native_v2';

/** gamepad_combo 持久化结构（与 ohos_gamepad.cpp / GamepadSettingsContent.ComboData 一致） */
interface ComboConfig {
  code?: number;
  buttons?: number[];
}

export interface PhysicalKeyBinding {
  keyCode: number;
  key: AzaharKey;
}

/** 默认映射（原 GameView 固定表）：Z/X/S/A=ABXY，Q/W/U/H=L/R/ZL/ZR，
 *  Enter=Start，右Shift=Select，方向键+IJKL=方向 */
const DEFAULT_BINDINGS: PhysicalKeyBinding[] = [
  { keyCode: 2042, key: AzaharKey.A },
  { keyCode: 2040, key: AzaharKey.B },
  { keyCode: 2035, key: AzaharKey.X },
  { keyCode: 2017, key: AzaharKey.Y },
  { keyCode: 2033, key: AzaharKey.L },
  { keyCode: 2039, key: AzaharKey.R },
  { keyCode: 2037, key: AzaharKey.ZL },
  { keyCode: 2023, key: AzaharKey.ZR },
  { keyCode: 2054, key: AzaharKey.Start },
  { keyCode: 2048, key: AzaharKey.Select },
  { keyCode: 2012, key: AzaharKey.Up },
  { keyCode: 2013, key: AzaharKey.Down },
  { keyCode: 2014, key: AzaharKey.Left },
  { keyCode: 2015, key: AzaharKey.Right },
  { keyCode: 2025, key: AzaharKey.Up },
  { keyCode: 2027, key: AzaharKey.Down },
  { keyCode: 2026, key: AzaharKey.Left },
  { keyCode: 2028, key: AzaharKey.Right }
];

/** 该 3DS 按键（NativeButton 索引，与 AzaharKey 同构）是否支持键盘绑定：
 *  数字键区全部可绑，Home/Power 无键盘绑定入口，摇杆轴不支持键盘触发 */
export function isKeyboardBindableButton(button: number): boolean {
  return (button >= AzaharKey.A && button <= AzaharKey.Select) ||
    button === AzaharKey.ZL || button === AzaharKey.ZR;
}

export class KeyboardBindingManager {
  private static instance: KeyboardBindingManager | null = null;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private map: Map<number, AzaharKey[]> = new Map();
  private loaded: boolean = false;

  static getInstance(): KeyboardBindingManager {
    if (!KeyboardBindingManager.instance) {
      KeyboardBindingManager.instance = new KeyboardBindingManager();
    }
    return KeyboardBindingManager.instance;
  }

  /** SettingsManager 已初始化后调用；重复调用安全（缓存） */
  load(): void {
    if (this.loaded) {
      return;
    }
    const raw = this.settingsManager.getString(SETTING_KEY);
    if (raw.length === 0) {
      this.applyDefaults();
    } else {
      this.parse(raw);
    }
    this.loaded = true;
  }

  /** 键码 → 3DS 按键列表（无绑定返回空数组） */
  getKeys(keyCode: number): AzaharKey[] {
    this.load();
    return this.map.get(keyCode) ?? [];
  }

  /** 3DS 按键 → 绑定的键码列表（设置页展示/宏编辑） */
  getKeyCodes(button: AzaharKey): number[] {
    this.load();
    const result: number[] = [];
    this.map.forEach((keys: AzaharKey[], code: number) => {
      if (keys.indexOf(button) >= 0) {
        result.push(code);
      }
    });
    return result;
  }

  /** 给某个 3DS 按键追加一个键码绑定；同一键码可出现在多个按键下（即宏） */
  addBinding(keyCode: number, button: AzaharKey): void {
    this.load();
    const keys = this.map.get(keyCode) ?? [];
    if (keys.indexOf(button) < 0) {
      keys.push(button);
      this.map.set(keyCode, keys);
      this.persist();
    }
  }

  /** 移除某个键码的全部绑定（其他通道抢占同一键码时清理死绑定） */
  removeKeyCode(keyCode: number): void {
    this.load();
    if (this.map.delete(keyCode)) {
      this.persist();
    }
  }

  /** 移除某个 3DS 按键下的指定键码绑定；清空后该键码不再有映射 */
  removeBinding(keyCode: number, button: AzaharKey): void {
    this.load();
    const keys = this.map.get(keyCode);
    if (!keys) {
      return;
    }
    const idx = keys.indexOf(button);
    if (idx >= 0) {
      keys.splice(idx, 1);
    }
    if (keys.length === 0) {
      this.map.delete(keyCode);
    }
    this.persist();
  }

  resetToDefaults(): void {
    this.applyDefaults();
    this.persist();
  }

  /** 组合键按键集：复用 gamepad_combo {code,buttons} 的 buttons 字段，
   *  即手柄组合键/虚拟宏按键（BUTTON_MACRO）/键盘多绑定共享的"触发源→按键集合"概念。
   *  buttons 即 Settings::NativeButton 索引（与 AzaharKey 同构，12/13 为 Debug/Gpio 不可触发） */
  getComboButtons(): AzaharKey[] {
    this.migrateLegacyNativeButtonIndexes();
    const raw = this.settingsManager.getString(KEY_GAMEPAD_COMBO);
    if (raw.length === 0) {
      return [];
    }
    try {
      const data = JSON.parse(raw) as ComboConfig;
      const buttons = data.buttons;
      if (!Array.isArray(buttons)) {
        return [];
      }
      const keys: AzaharKey[] = [];
      for (const nb of buttons) {
        if (KeyboardBindingManager.isAzaharKey(nb) && keys.indexOf(nb as AzaharKey) < 0) {
          keys.push(nb as AzaharKey);
        }
      }
      return keys;
    } catch (_e) {
      return [];
    }
  }

  /** 合法的 AzaharKey 值：0-11 直通，14=ZL/15=ZR/16=Home/17=Power；12/13 为 Debug/Gpio14 不可触发 */
  private static isAzaharKey(v: number): boolean {
    return (v >= AzaharKey.A && v <= AzaharKey.Select) ||
      (v >= AzaharKey.ZL && v <= AzaharKey.Power);
  }

  /** 旧版 ArkTS 手柄编号（Home=12/ZL=13/ZR=14）与 Settings::NativeButton
   *  （Debug=12/Gpio14=13/ZL=14/ZR=15/Home=16）错位，native 直接按 NativeButton
   *  解析导致 ZL→Gpio14 死键、ZR→ZL、Home→Debug。已持久化的
   *  gamepad_button_map/gamepad_combo 需一次性迁移；0-11 两空间一致不动。 */
  migrateLegacyNativeButtonIndexes(): void {
    if (this.settingsManager.getBoolean(NB_MIGRATION_FLAG)) {
      return;
    }
    this.migrateButtonMap();
    this.migrateComboButtons();
    this.settingsManager.setBoolean(NB_MIGRATION_FLAG, true);
  }

  private static legacyNbToNative(nb: number): number {
    switch (nb) {
      case 12: return 16;
      case 13: return 14;
      case 14: return 15;
      default: return nb;
    }
  }

  private migrateButtonMap(): void {
    const raw = this.settingsManager.getString(KEY_GAMEPAD_BUTTON_MAP);
    if (raw.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, number>;
      const remapped: Record<string, number> = {};
      for (const k of Object.keys(parsed)) {
        const nb = Number(k);
        const code = parsed[k];
        if (!Number.isInteger(nb) || nb < 0 || typeof code !== 'number') {
          continue;
        }
        remapped[`${KeyboardBindingManager.legacyNbToNative(nb)}`] = code;
      }
      this.settingsManager.setString(KEY_GAMEPAD_BUTTON_MAP, JSON.stringify(remapped));
    } catch (e) {
      console.warn(`migrate button map failed: ${(e as Error)?.message}`);
    }
  }

  private migrateComboButtons(): void {
    const raw = this.settingsManager.getString(KEY_GAMEPAD_COMBO);
    if (raw.length === 0) {
      return;
    }
    try {
      const data = JSON.parse(raw) as ComboConfig;
      if (!Array.isArray(data.buttons)) {
        return;
      }
      const buttons: number[] = [];
      for (const b of data.buttons) {
        buttons.push(KeyboardBindingManager.legacyNbToNative(b));
      }
      const migrated: ComboConfig = { code: typeof data.code === 'number' ? data.code : -1, buttons: buttons };
      this.settingsManager.setString(KEY_GAMEPAD_COMBO, JSON.stringify(migrated));
    } catch (e) {
      console.warn(`migrate combo buttons failed: ${(e as Error)?.message}`);
    }
  }

  private applyDefaults(): void {
    this.map.clear();
    for (const b of DEFAULT_BINDINGS) {
      const keys = this.map.get(b.keyCode) ?? [];
      keys.push(b.key);
      this.map.set(b.keyCode, keys);
    }
  }

  private parse(raw: string): void {
    this.map.clear();
    try {
      const obj = JSON.parse(raw) as Record<string, number[]>;
      for (const code of Object.keys(obj)) {
        const keyCode = Number(code);
        const values = obj[code];
        if (!isNaN(keyCode) && Array.isArray(values)) {
          // 过滤非法枚举值并去重（异常配置不应产生重复映射目标）
          const keys = Array.from(
            new Set(values.filter((v: number) => v >= AzaharKey.A && v <= AzaharKey.Power)));
          if (keys.length > 0) {
            this.map.set(keyCode, keys);
          }
        }
      }
    } catch (_e) {
      this.applyDefaults();
    }
    if (this.map.size === 0) {
      this.applyDefaults();
    }
  }

  private persist(): void {
    const obj: Record<string, number[]> = {};
    this.map.forEach((keys: AzaharKey[], code: number) => {
      obj[`${code}`] = keys;
    });
    this.settingsManager.setString(SETTING_KEY, JSON.stringify(obj));
  }
}

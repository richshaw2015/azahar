import { router } from '@kit.ArkUI';
import { SoundEffect, SoundEffectManager } from './SoundEffectManager';

export const GAMEPAD_A: number = 2301;
export const GAMEPAD_B: number = 2302;
export const GAMEPAD_X: number = 2304;
export const GAMEPAD_Y: number = 2305;
export const GAMEPAD_L1: number = 2307;
export const GAMEPAD_R1: number = 2308;
export const GAMEPAD_SELECT: number = 2311;
export const GAMEPAD_START: number = 2312;

// 手柄键码范围：十字键 2012–2015，其余按键 2301–2315
export function isGamepadKey(code: number): boolean {
  return (code >= 2012 && code <= 2015) || (code >= 2301 && code <= 2315);
}

export function gamepadBackHandler(): (event: KeyEvent) => void {
  return (event: KeyEvent): void => {
    if (event.type !== KeyType.Down || event.keyCode !== GAMEPAD_B) {
      return;
    }
    SoundEffectManager.getInstance().play(SoundEffect.BACK);
    router.back();
    event.stopPropagation();
  };
}

export function gamepadUIKeyHandler(onBack: () => boolean): (event: KeyEvent) => void {
  return (event: KeyEvent): void => {
    if (event.type !== KeyType.Down || event.keyCode !== GAMEPAD_B) {
      return;
    }
    SoundEffectManager.getInstance().play(SoundEffect.BACK);
    if (!onBack()) {
      router.back();
    }
    event.stopPropagation();
  };
}

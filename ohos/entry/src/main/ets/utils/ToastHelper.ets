import { promptAction } from '@kit.ArkUI';
import { ThemeManager } from './ThemeManager';
import { TEXT_ON_ACCENT, TEXT_PRIMARY } from '../types/UIConstants';

export enum ToastType {
  INFO = 'info',
  SUCCESS = 'success',
  WARNING = 'warning',
  ERROR = 'error'
}

interface RgbColor {
  red: number;
  green: number;
  blue: number;
}

class ToastVisual {
  background: string = '';
  foreground: ResourceColor = TEXT_ON_ACCENT;
}

const DEFAULT_DURATION: Record<string, number> = {
  [ToastType.INFO]: 3000,
  [ToastType.SUCCESS]: 2000,
  [ToastType.WARNING]: 4000,
  [ToastType.ERROR]: 4000
};

export function initToastHelper(uiContext: UIContext): void {
  AppStorage.setOrCreate('__toastUIContext__', uiContext as object);
}

export function showToast(message: string, type: ToastType = ToastType.INFO, duration?: number): void {
  const toastDuration = Math.min(10000, Math.max(1500, duration ?? DEFAULT_DURATION[type] ?? 2000));
  const visual = type === ToastType.INFO ? getInfoVisual() : undefined;
  const options: promptAction.ShowToastOptions = {
    message,
    duration: toastDuration,
    alignment: Alignment.Top,
    offset: { dx: 0, dy: 64 },
    backgroundColor: visual?.background ?? getBackgroundColor(type),
    backgroundBlurStyle: BlurStyle.NONE,
    textColor: visual?.foreground ?? getTextColor(type)
  };

  try {
    const uiContext = AppStorage.get<object>('__toastUIContext__') as UIContext | undefined;
    if (uiContext) {
      uiContext.getPromptAction().showToast(options);
      return;
    }
  } catch (error) {
    console.warn(`ToastHelper: showToast failed: ${(error as Error).message}`);
  }

  try {
    promptAction.showToast(options);
  } catch (_error) {
    console.warn(`ToastHelper: showToast failed: ${(_error as Error)?.message}`);
  }
}

export function showInfoToast(message: string, duration?: number): void {
  showToast(message, ToastType.INFO, duration);
}

export function showSuccessToast(message: string, duration?: number): void {
  showToast(message, ToastType.SUCCESS, duration);
}

export function showWarningToast(message: string, duration?: number): void {
  showToast(message, ToastType.WARNING, duration);
}

export function showErrorToast(message: string, duration?: number): void {
  showToast(message, ToastType.ERROR, duration);
}

function getBackgroundColor(type: ToastType): ResourceColor {
  switch (type) {
    case ToastType.SUCCESS:
      return $r('app.color.toast_success_bg');
    case ToastType.WARNING:
      return $r('app.color.toast_warning_bg');
    case ToastType.ERROR:
      return $r('app.color.toast_error_bg');
    case ToastType.INFO:
    default:
      return $r('sys.color.ohos_id_color_button_normal');
  }
}

function getTextColor(type: ToastType): ResourceColor {
  if (type === ToastType.WARNING) {
    return TEXT_PRIMARY;
  }
  return TEXT_ON_ACCENT;
}

function getInfoVisual(): ToastVisual {
  const accent = ThemeManager.getInstance().getCurrentColors().accent;
  const visual = new ToastVisual();
  const rgb = parseHexColor(accent);
  if (!rgb) {
    visual.background = accent;
    return visual;
  }

  const luminance = getLuminance(rgb);
  const scale = luminance > 0.35 ? 0.55 : 1;
  const adjusted: RgbColor = {
    red: rgb.red * scale,
    green: rgb.green * scale,
    blue: rgb.blue * scale
  };
  visual.background = `#FF${toHex(adjusted.red)}${toHex(adjusted.green)}${toHex(adjusted.blue)}`;
  visual.foreground = getLuminance(adjusted) > 0.55 ? TEXT_PRIMARY : TEXT_ON_ACCENT;
  return visual;
}

function parseHexColor(value: string): RgbColor | undefined {
  const clean = value.replace('#', '');
  if (clean.length !== 6) {
    return undefined;
  }
  return {
    red: parseInt(clean.slice(0, 2), 16),
    green: parseInt(clean.slice(2, 4), 16),
    blue: parseInt(clean.slice(4, 6), 16)
  };
}

function getLuminance(rgb: RgbColor): number {
  return (0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue) / 255;
}

function toHex(value: number): string {
  return Math.round(value).toString(16).padStart(2, '0').toUpperCase();
}

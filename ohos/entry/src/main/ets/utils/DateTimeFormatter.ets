import { I18n } from './I18nManager';

export function formatSaveStateTime(time: number): string {
  if (time <= 0) {
    return I18n.t('unknown_time');
  }
  const date = new Date(time * 1000);
  const y = date.getFullYear();
  const m = `${date.getMonth() + 1}`.padStart(2, '0');
  const d = `${date.getDate()}`.padStart(2, '0');
  const hh = `${date.getHours()}`.padStart(2, '0');
  const mm = `${date.getMinutes()}`.padStart(2, '0');
  return `${y}-${m}-${d} ${hh}:${mm}`;
}

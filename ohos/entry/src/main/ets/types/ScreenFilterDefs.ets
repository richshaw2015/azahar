import { I18n } from '../utils/I18nManager';
import { SettingsManager } from '../utils/SettingsManager';
import { AzaharNative } from './AzaharNative';
import { KEY_PP_SHADER_NAME } from './SettingsTypes';

// 内置屏幕滤镜 —— 单一事实来源。
// 存储值 = `${name} (builtin)`，与 video_core/screen_filters.h 的 SCREEN_FILTERS
// name 一一对应；labelKey 供 i18n（描述性名称，对齐 melonDS-ohos 译名），label 供
// 存储名与展示名不一致的专有名词（AA-Color）；preview 为
// rawfile/filter_previews/ 下预览图文件名（不含扩展名）。
export interface ScreenFilterDef {
  name: string;
  labelKey?: string;
  label?: string;
  preview: string;
}

export const SCREEN_FILTER_NONE_VALUE = 'None (builtin)';

// 图形设置页与滤镜预览页共用的跨页选中态 key（AppStorage）
export const SCREEN_FILTER_SELECTION_STORAGE = 'screen_filter_selection';

export const SCREEN_FILTER_DEFS: ScreenFilterDef[] = [
  { name: '2xBR', preview: '2xbr' },
  { name: 'HQ2X', preview: 'hq2x' },
  { name: 'HQ4X', preview: 'hq4x' },
  { name: 'Quilez', preview: 'quilez' },
  { name: 'LCD', preview: 'lcd' },
  { name: 'Sharp Bilinear', preview: 'sharp_bilinear' },
  { name: 'AAColor', label: 'AA-Color', preview: 'aacolor' },
  { name: 'FXAA', preview: 'fxaa' },
  { name: 'Natural Colors', labelKey: 'filter_natural', preview: 'natural' },
  { name: 'Scanlines', labelKey: 'filter_scanlines', preview: 'scanlines' },
  { name: 'FSR RCAS', labelKey: 'filter_fsr_rcas', preview: 'fsr_rcas' },
  { name: 'FSR EASU', preview: 'fsr_easu' },
  { name: 'PL2x', labelKey: 'filter_pl_2x', preview: 'pl_2x' },
  { name: 'PL Mask', labelKey: 'filter_pl_mask', preview: 'pl_mask' },
  { name: 'PL Hard', labelKey: 'filter_pl_hard', preview: 'pl_hard' },
  { name: 'Film Grain', labelKey: 'filter_filmgrain', preview: 'filmgrain' }
];

export function screenFilterValue(def: ScreenFilterDef): string {
  return `${def.name} (builtin)`;
}

export function screenFilterDisplayLabel(def: ScreenFilterDef): string {
  if (def.labelKey) {
    return I18n.t(def.labelKey);
  }
  return def.label ? def.label : def.name;
}

// 存储值 → 展示名；非内置值（用户自定义 shader 名）原样显示
export function screenFilterDisplayName(value: string): string {
  for (const def of SCREEN_FILTER_DEFS) {
    if (screenFilterValue(def) === value) {
      return screenFilterDisplayLabel(def);
    }
  }
  return value === SCREEN_FILTER_NONE_VALUE ? I18n.t('none') : value;
}

// 滤镜选项（含"无"），设置页预览网格与暂停菜单滤镜段共用的展示模型
export interface ScreenFilterItem {
  value: string;
  label: string;
  preview: string;
}

export function screenFilterItems(): ScreenFilterItem[] {
  const list: ScreenFilterItem[] = [
    { value: SCREEN_FILTER_NONE_VALUE, label: I18n.t('none'), preview: 'none' }
  ];
  for (const def of SCREEN_FILTER_DEFS) {
    list.push({
      value: screenFilterValue(def),
      label: screenFilterDisplayLabel(def),
      preview: def.preview
    });
  }
  return list;
}

// 选中即持久化并推送 native：运行中 applyConfig 置 shader_update_requested，
// 渲染线程在下一帧重建 present 着色器；暂停下切换在恢复后首帧自然生效
export function persistScreenFilter(value: string): void {
  SettingsManager.getInstance().setString(KEY_PP_SHADER_NAME, value);
  AzaharNative.applyConfig();
}

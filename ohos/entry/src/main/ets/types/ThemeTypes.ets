export interface AzaharThemeColors {
  /** 主题主色：选中描边、标题强调、瓦片选中态 */
  primary: string;
  /** 页面背景渐变（浅色） */
  gradientStart: string;
  gradientEnd: string;
  /** 亮强调色（主色浅一档，装饰点缀） */
  accent: string;
  /** 控件强调色（主色深一档，可点击/可操作元素） */
  controlAccent?: string;
}

export interface AzaharTheme {
  id: string;
  nameKey: string;
  colors: AzaharThemeColors;
  /** 深色模式下的配色变体（缺省时回落到 colors） */
  darkColors?: AzaharThemeColors;
}

/** 应用外观模式：auto=跟随系统，light=固定浅色，dark=固定深色 */
export type AzaharColorMode = 'auto' | 'light' | 'dark';

export const AZAHAR_COLOR_MODES: AzaharColorMode[] = ['auto', 'light', 'dark'];

export enum AzaharThemeId {
  Violet = 'violet',
  CobaltBlue = 'cobalt_blue',
  AquaBlue = 'aqua_blue',
  Orange = 'orange',
  LimeGreen = 'lime_green'
}

// 3DS 主机配色主题：浅色底 + 主题色点缀；orange 为首，作为默认品牌主题（logo 橙）
export const AZAHAR_THEMES: AzaharTheme[] = [
  {
    id: AzaharThemeId.Orange,
    nameKey: 'theme_orange',
    colors: {
      primary: '#C2410C',
      gradientStart: '#FFF9F2',
      gradientEnd: '#FDEBD7',
      accent: '#FDBA74',
      controlAccent: '#E8870F'
    },
    darkColors: {
      primary: '#F59E0B',
      gradientStart: '#1A120B',
      gradientEnd: '#2A1C10',
      accent: '#FDBA74',
      controlAccent: '#FBA94E'
    }
  },
  {
    id: AzaharThemeId.Violet,
    nameKey: 'theme_violet',
    colors: {
      primary: '#4C1D95',
      gradientStart: '#F8F6FE',
      gradientEnd: '#EDE8FA',
      accent: '#A78BFA',
      controlAccent: '#8B5CF6'
    },
    darkColors: {
      primary: '#A78BFA',
      gradientStart: '#150F24',
      gradientEnd: '#241638',
      accent: '#A78BFA',
      controlAccent: '#B79CFC'
    }
  },
  {
    id: AzaharThemeId.CobaltBlue,
    nameKey: 'theme_cobalt_blue',
    colors: {
      primary: '#3B55D9',
      gradientStart: '#F6F8FE',
      gradientEnd: '#E2E8FB',
      accent: '#7C93EE',
      controlAccent: '#2B3FB8'
    },
    darkColors: {
      primary: '#8FA4F2',
      gradientStart: '#11142A',
      gradientEnd: '#1C2244',
      accent: '#7C93EE',
      controlAccent: '#8FA4F2'
    }
  },
  {
    id: AzaharThemeId.AquaBlue,
    nameKey: 'theme_aqua_blue',
    colors: {
      primary: '#0097A7',
      gradientStart: '#F4FBFC',
      gradientEnd: '#DFF4F6',
      accent: '#4DD0E1',
      controlAccent: '#00838F'
    },
    darkColors: {
      primary: '#4DD0E1',
      gradientStart: '#0F1C1D',
      gradientEnd: '#16312F',
      accent: '#4DD0E1',
      controlAccent: '#67E8F9'
    }
  },

  {
    id: AzaharThemeId.LimeGreen,
    nameKey: 'theme_lime_green',
    colors: {
      primary: '#94C437',
      gradientStart: '#FAFCF4',
      gradientEnd: '#EDF5D8',
      accent: '#BFE08A',
      controlAccent: '#6F9E1F'
    },
    darkColors: {
      primary: '#B0D968',
      gradientStart: '#121710',
      gradientEnd: '#1E2816',
      accent: '#BFE08A',
      controlAccent: '#B0D968'
    }
  },
];

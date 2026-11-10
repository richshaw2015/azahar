import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AzaharConfigValue, AzaharNative } from '../types/AzaharNative';

const PREFERENCES_NAME: string = 'azahar_game_configs';
const KEY_ALL_CONFIGS: string = 'all_configs';
const DEFAULT_NUMBER: number = -1;
const DEFAULT_TOGGLE: number = -1;

export interface AzaharGameConfig {
  customName: string;
  graphicsApi: number;
  inputType: number;
  layoutId: string;
  resolutionFactor: number;
  cpuClockPercentage: number;
  frameLimit: number;
  turboLimit: number;
  useHwShader: number;
  useShaderJit: number;
  useDiskShaderCache: number;
  useVsync: number;
  useIntegerScaling: number;
  shadersAccurateMul: number;
  spirvShaderGen: number;
  asyncShaderCompilation: number;
  asyncPresentation: number;
  simulate3dsGpuTimings: number;
  delayGameRenderThreadUs: number;
  textureFilter: number;
  textureSampling: number;
  render3dWhichDisplay: number;
  monoRenderOption: number;
  filterMode: number;
  ppShaderName: string;
  render3d: number;
  factor3d: number;
  swapEyes3d: number;
  disableRightEyeRender: number;
  layoutOption: number;
  portraitLayoutOption: number;
  screenGap: number;
  swapScreen: number;
  uprightScreen: number;
  secondaryDisplayLayout: number;
  largeScreenProportion: number;
  smallScreenPosition: number;
  aspectRatio: number;
  screenTopStretch: number;
  screenBottomStretch: number;
  audioEmulation: number;
  isNew3ds: number;
  lleApplets: number;
  enableRequiredOnlineLleModules: number;
  regionValue: number;
  gamePerfHacks: number;
  useVirtualSd: number;
  asyncFsOperations: number;
  dumpTextures: number;
  customTextures: number;
  preloadTextures: number;
  asyncCustomLoading: number;
  volume: number;
}

export function defaultGameConfig(): AzaharGameConfig {
  return {
    customName: '',
    graphicsApi: DEFAULT_NUMBER,
    inputType: DEFAULT_NUMBER,
    layoutId: '',
    resolutionFactor: DEFAULT_NUMBER,
    cpuClockPercentage: DEFAULT_NUMBER,
    frameLimit: DEFAULT_NUMBER,
    turboLimit: DEFAULT_NUMBER,
    useHwShader: DEFAULT_TOGGLE,
    useShaderJit: DEFAULT_TOGGLE,
    useDiskShaderCache: DEFAULT_TOGGLE,
    useVsync: DEFAULT_TOGGLE,
    useIntegerScaling: DEFAULT_TOGGLE,
    shadersAccurateMul: DEFAULT_TOGGLE,
    spirvShaderGen: DEFAULT_TOGGLE,
    asyncShaderCompilation: DEFAULT_TOGGLE,
    asyncPresentation: DEFAULT_TOGGLE,
    simulate3dsGpuTimings: DEFAULT_TOGGLE,
    delayGameRenderThreadUs: DEFAULT_NUMBER,
    textureFilter: DEFAULT_NUMBER,
    textureSampling: DEFAULT_NUMBER,
    render3dWhichDisplay: DEFAULT_NUMBER,
    monoRenderOption: DEFAULT_NUMBER,
    filterMode: DEFAULT_TOGGLE,
    ppShaderName: '',
    render3d: DEFAULT_NUMBER,
    factor3d: DEFAULT_NUMBER,
    swapEyes3d: DEFAULT_TOGGLE,
    disableRightEyeRender: DEFAULT_TOGGLE,
    layoutOption: DEFAULT_NUMBER,
    portraitLayoutOption: DEFAULT_NUMBER,
    screenGap: DEFAULT_NUMBER,
    swapScreen: DEFAULT_TOGGLE,
    uprightScreen: DEFAULT_TOGGLE,
    secondaryDisplayLayout: DEFAULT_NUMBER,
    largeScreenProportion: DEFAULT_NUMBER,
    smallScreenPosition: DEFAULT_NUMBER,
    aspectRatio: DEFAULT_NUMBER,
    screenTopStretch: DEFAULT_TOGGLE,
    screenBottomStretch: DEFAULT_TOGGLE,
    audioEmulation: DEFAULT_NUMBER,
    isNew3ds: DEFAULT_TOGGLE,
    lleApplets: DEFAULT_TOGGLE,
    enableRequiredOnlineLleModules: DEFAULT_TOGGLE,
    regionValue: DEFAULT_NUMBER,
    gamePerfHacks: DEFAULT_TOGGLE,
    useVirtualSd: DEFAULT_TOGGLE,
    asyncFsOperations: DEFAULT_TOGGLE,
    dumpTextures: DEFAULT_TOGGLE,
    customTextures: DEFAULT_TOGGLE,
    preloadTextures: DEFAULT_TOGGLE,
    asyncCustomLoading: DEFAULT_TOGGLE,
    volume: DEFAULT_NUMBER
  };
}

export class GameConfigManager {
  private static instance: GameConfigManager | null = null;
  private prefs: preferences.Preferences | null = null;
  private initialized: boolean = false;
  private configCache: Map<string, AzaharGameConfig> = new Map<string, AzaharGameConfig>();

  static getInstance(): GameConfigManager {
    if (!GameConfigManager.instance) {
      GameConfigManager.instance = new GameConfigManager();
    }
    return GameConfigManager.instance;
  }

  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.prefs = await preferences.getPreferences(context, PREFERENCES_NAME);
    await this.loadAllConfigs();
    this.initialized = true;
  }

  getConfig(path: string): AzaharGameConfig {
    const cached = this.configCache.get(path);
    return cached ? cached : defaultGameConfig();
  }

  getDisplayName(path: string, fallback: string): string {
    const name = this.getConfig(path).customName.trim();
    return name.length > 0 ? name : fallback;
  }

  async saveConfig(path: string, config: AzaharGameConfig): Promise<void> {
    if (!path) {
      return;
    }
    this.configCache.set(path, config);
    await this.persistConfigs();
  }

  async updateConfig(path: string, updater: (config: AzaharGameConfig) => AzaharGameConfig): Promise<AzaharGameConfig> {
    // getConfig 返回缓存对象本体；先克隆再交给 updater——若原地改缓存引用，
    // 返回的还是同一对象，调用方 @State 按引用判脏不会刷新界面
    const updated = updater(this.withDefaults(this.getConfig(path)));
    await this.saveConfig(path, updated);
    return updated;
  }

  async resetConfig(path: string): Promise<void> {
    this.configCache.delete(path);
    await this.persistConfigs();
  }

  applyNativeOverrides(path: string): void {
    const config = this.getConfig(path);
    this.applyNumberOverride('graphics_api', config.graphicsApi);
    this.applyNumberOverride('input_type', config.inputType);
    this.applyNumberOverride('resolution_factor', config.resolutionFactor);
    this.applyNumberOverride('cpu_clock_percentage', config.cpuClockPercentage);
    this.applyNumberOverride('frame_limit', config.frameLimit);
    this.applyNumberOverride('turbo_limit', config.turboLimit);
    this.applyToggleOverride('use_hw_shader', config.useHwShader);
    this.applyToggleOverride('use_shader_jit', config.useShaderJit);
    this.applyToggleOverride('use_disk_shader_cache', config.useDiskShaderCache);
    this.applyToggleOverride('use_vsync', config.useVsync);
    this.applyToggleOverride('use_integer_scaling', config.useIntegerScaling);
    this.applyToggleOverride('shaders_accurate_mul', config.shadersAccurateMul);
    this.applyToggleOverride('spirv_shader_gen', config.spirvShaderGen);
    this.applyToggleOverride('async_shader_compilation', config.asyncShaderCompilation);
    this.applyToggleOverride('async_presentation', config.asyncPresentation);
    this.applyToggleOverride('simulate_3ds_gpu_timings', config.simulate3dsGpuTimings);
    this.applyNumberOverride('delay_game_render_thread_us', config.delayGameRenderThreadUs);
    this.applyNumberOverride('texture_filter', config.textureFilter);
    this.applyNumberOverride('texture_sampling', config.textureSampling);
    this.applyNumberOverride('render_3d_which_display', config.render3dWhichDisplay);
    this.applyNumberOverride('mono_render_option', config.monoRenderOption);
    this.applyToggleOverride('filter_mode', config.filterMode);
    this.applyStringOverride('pp_shader_name', config.ppShaderName);
    this.applyNumberOverride('render_3d', config.render3d);
    this.applyNumberOverride('factor_3d', config.factor3d);
    this.applyToggleOverride('swap_eyes_3d', config.swapEyes3d);
    this.applyToggleOverride('disable_right_eye_render', config.disableRightEyeRender);
    this.applyNumberOverride('layout_option', config.layoutOption);
    this.applyNumberOverride('portrait_layout_option', config.portraitLayoutOption);
    this.applyNumberOverride('screen_gap', config.screenGap);
    this.applyToggleOverride('swap_screen', config.swapScreen);
    this.applyToggleOverride('upright_screen', config.uprightScreen);
    this.applyNumberOverride('secondary_display_layout', config.secondaryDisplayLayout);
    this.applyNumberOverride('large_screen_proportion', config.largeScreenProportion);
    this.applyNumberOverride('small_screen_position', config.smallScreenPosition);
    this.applyNumberOverride('aspect_ratio', config.aspectRatio);
    this.applyToggleOverride('screen_top_stretch', config.screenTopStretch);
    this.applyToggleOverride('screen_bottom_stretch', config.screenBottomStretch);
    this.applyNumberOverride('audio_emulation', config.audioEmulation);
    this.applyToggleOverride('is_new_3ds', config.isNew3ds);
    this.applyToggleOverride('lle_applets', config.lleApplets);
    this.applyToggleOverride('enable_required_online_lle_modules', config.enableRequiredOnlineLleModules);
    this.applyNumberOverride('region_value', config.regionValue);
    this.applyToggleOverride('game_perf_hacks', config.gamePerfHacks);
    this.applyToggleOverride('use_virtual_sd', config.useVirtualSd);
    this.applyToggleOverride('async_fs_operations', config.asyncFsOperations);
    this.applyToggleOverride('dump_textures', config.dumpTextures);
    this.applyToggleOverride('custom_textures', config.customTextures);
    this.applyToggleOverride('preload_textures', config.preloadTextures);
    this.applyToggleOverride('async_custom_loading', config.asyncCustomLoading);
    this.applyNumberOverride('volume', config.volume);
    AzaharNative.applyConfig();
  }

  private applyNumberOverride(nativeKey: string, value: number): void {
    if (value !== DEFAULT_NUMBER) {
      AzaharNative.setConfig(nativeKey, value as AzaharConfigValue);
    }
  }

  private applyToggleOverride(nativeKey: string, value: number): void {
    if (value !== DEFAULT_TOGGLE) {
      AzaharNative.setConfig(nativeKey, value === 1);
    }
  }

  private applyStringOverride(nativeKey: string, value: string): void {
    if (value.length > 0) {
      AzaharNative.setConfig(nativeKey, value);
    }
  }

  private async loadAllConfigs(): Promise<void> {
    if (!this.prefs) {
      return;
    }
    try {
      const raw = await this.prefs.get(KEY_ALL_CONFIGS, '{}') as string;
      const parsed = JSON.parse(raw) as Record<string, AzaharGameConfig>;
      this.configCache.clear();
      for (const key of Object.keys(parsed)) {
        this.configCache.set(key, this.withDefaults(parsed[key]));
      }
    } catch (_error) {
      this.configCache.clear();
    }
  }

  private async persistConfigs(): Promise<void> {
    if (!this.prefs) {
      return;
    }
    const out: Record<string, AzaharGameConfig> = {};
    this.configCache.forEach((value: AzaharGameConfig, key: string) => {
      out[key] = value;
    });
    await this.prefs.put(KEY_ALL_CONFIGS, JSON.stringify(out));
    await this.prefs.flush();
  }

  private withDefaults(config: AzaharGameConfig): AzaharGameConfig {
    const defaults = defaultGameConfig();
    return {
      customName: config.customName === undefined ? defaults.customName : config.customName,
      graphicsApi: config.graphicsApi === undefined ? defaults.graphicsApi : config.graphicsApi,
      inputType: config.inputType === undefined ? defaults.inputType : config.inputType,
      layoutId: config.layoutId === undefined ? defaults.layoutId : config.layoutId,
      resolutionFactor: config.resolutionFactor === undefined ? defaults.resolutionFactor : config.resolutionFactor,
      cpuClockPercentage: config.cpuClockPercentage === undefined ? defaults.cpuClockPercentage : config.cpuClockPercentage,
      frameLimit: config.frameLimit === undefined ? defaults.frameLimit : config.frameLimit,
      turboLimit: config.turboLimit === undefined ? defaults.turboLimit : config.turboLimit,
      useHwShader: config.useHwShader === undefined ? defaults.useHwShader : config.useHwShader,
      useShaderJit: config.useShaderJit === undefined ? defaults.useShaderJit : config.useShaderJit,
      useDiskShaderCache: config.useDiskShaderCache === undefined ? defaults.useDiskShaderCache : config.useDiskShaderCache,
      useVsync: config.useVsync === undefined ? defaults.useVsync : config.useVsync,
      useIntegerScaling: config.useIntegerScaling === undefined ? defaults.useIntegerScaling : config.useIntegerScaling,
      shadersAccurateMul: config.shadersAccurateMul === undefined ? defaults.shadersAccurateMul : config.shadersAccurateMul,
      spirvShaderGen: config.spirvShaderGen === undefined ? defaults.spirvShaderGen : config.spirvShaderGen,
      asyncShaderCompilation: config.asyncShaderCompilation === undefined ? defaults.asyncShaderCompilation : config.asyncShaderCompilation,
      asyncPresentation: config.asyncPresentation === undefined ? defaults.asyncPresentation : config.asyncPresentation,
      simulate3dsGpuTimings: config.simulate3dsGpuTimings === undefined ? defaults.simulate3dsGpuTimings : config.simulate3dsGpuTimings,
      delayGameRenderThreadUs: config.delayGameRenderThreadUs === undefined ? defaults.delayGameRenderThreadUs : config.delayGameRenderThreadUs,
      textureFilter: config.textureFilter === undefined ? defaults.textureFilter : config.textureFilter,
      textureSampling: config.textureSampling === undefined ? defaults.textureSampling : config.textureSampling,
      render3dWhichDisplay: config.render3dWhichDisplay === undefined ? defaults.render3dWhichDisplay : config.render3dWhichDisplay,
      monoRenderOption: config.monoRenderOption === undefined ? defaults.monoRenderOption : config.monoRenderOption,
      filterMode: config.filterMode === undefined ? defaults.filterMode : config.filterMode,
      ppShaderName: config.ppShaderName === undefined ? defaults.ppShaderName : config.ppShaderName,
      render3d: config.render3d === undefined ? defaults.render3d : config.render3d,
      factor3d: config.factor3d === undefined ? defaults.factor3d : config.factor3d,
      swapEyes3d: config.swapEyes3d === undefined ? defaults.swapEyes3d : config.swapEyes3d,
      disableRightEyeRender: config.disableRightEyeRender === undefined ? defaults.disableRightEyeRender : config.disableRightEyeRender,
      layoutOption: config.layoutOption === undefined ? defaults.layoutOption : config.layoutOption,
      portraitLayoutOption: config.portraitLayoutOption === undefined ? defaults.portraitLayoutOption : config.portraitLayoutOption,
      screenGap: config.screenGap === undefined ? defaults.screenGap : config.screenGap,
      swapScreen: config.swapScreen === undefined ? defaults.swapScreen : config.swapScreen,
      uprightScreen: config.uprightScreen === undefined ? defaults.uprightScreen : config.uprightScreen,
      secondaryDisplayLayout: config.secondaryDisplayLayout === undefined ? defaults.secondaryDisplayLayout : config.secondaryDisplayLayout,
      largeScreenProportion: config.largeScreenProportion === undefined ? defaults.largeScreenProportion : config.largeScreenProportion,
      smallScreenPosition: config.smallScreenPosition === undefined ? defaults.smallScreenPosition : config.smallScreenPosition,
      aspectRatio: config.aspectRatio === undefined ? defaults.aspectRatio : config.aspectRatio,
      screenTopStretch: config.screenTopStretch === undefined ? defaults.screenTopStretch : config.screenTopStretch,
      screenBottomStretch: config.screenBottomStretch === undefined ? defaults.screenBottomStretch : config.screenBottomStretch,
      audioEmulation: config.audioEmulation === undefined ? defaults.audioEmulation : config.audioEmulation,
      isNew3ds: config.isNew3ds === undefined ? defaults.isNew3ds : config.isNew3ds,
      lleApplets: config.lleApplets === undefined ? defaults.lleApplets : config.lleApplets,
      enableRequiredOnlineLleModules: config.enableRequiredOnlineLleModules === undefined ? defaults.enableRequiredOnlineLleModules : config.enableRequiredOnlineLleModules,
      regionValue: config.regionValue === undefined ? defaults.regionValue : config.regionValue,
      gamePerfHacks: config.gamePerfHacks === undefined ? defaults.gamePerfHacks : config.gamePerfHacks,
      useVirtualSd: config.useVirtualSd === undefined ? defaults.useVirtualSd : config.useVirtualSd,
      asyncFsOperations: config.asyncFsOperations === undefined ? defaults.asyncFsOperations : config.asyncFsOperations,
      dumpTextures: config.dumpTextures === undefined ? defaults.dumpTextures : config.dumpTextures,
      customTextures: config.customTextures === undefined ? defaults.customTextures : config.customTextures,
      preloadTextures: config.preloadTextures === undefined ? defaults.preloadTextures : config.preloadTextures,
      asyncCustomLoading: config.asyncCustomLoading === undefined ? defaults.asyncCustomLoading : config.asyncCustomLoading,
      volume: config.volume === undefined ? defaults.volume : config.volume
    };
  }
}

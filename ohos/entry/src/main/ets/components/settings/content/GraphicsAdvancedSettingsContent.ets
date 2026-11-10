import { common } from '@kit.AbilityKit';
import { SelectSettingItem } from '../SelectSettingItem';
import { SliderSettingItem } from '../SliderSettingItem';
import { ToggleSettingItem } from '../ToggleSettingItem';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { KEY_ASYNC_CUSTOM_LOADING, KEY_ASYNC_SHADER_COMPILATION, KEY_CARDBOARD_SCREEN_SIZE, KEY_CARDBOARD_X_SHIFT, KEY_CARDBOARD_Y_SHIFT, KEY_DELAY_GAME_RENDER_THREAD_US, KEY_DISABLE_RIGHT_EYE_RENDER, KEY_DISABLE_SPIRV_OPTIMIZER, KEY_DUMP_TEXTURES, KEY_FACTOR_3D, KEY_FILTER_MODE, KEY_RENDER_3D, KEY_RENDER_3D_WHICH_DISPLAY, KEY_SHADERS_ACCURATE_MUL, KEY_SPIRV_SHADER_GEN, KEY_SWAP_EYES_3D, KEY_TEXTURE_FILTER, KEY_TEXTURE_SAMPLING, KEY_USE_DISK_SHADER_CACHE, KEY_USE_INTEGER_SCALING, KEY_USE_SKIP_DUPLICATE_FRAMES, SettingOption } from '../../../types/SettingsTypes';
import { DeviceProfile } from '../../../utils/DeviceProfile';
import { I18n } from '../../../utils/I18nManager';
import { SettingsManager } from '../../../utils/SettingsManager';
import { AzaharNative } from '../../../types/AzaharNative';
import { SoundEffectManager } from '../../../utils/SoundEffectManager';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { AzaharThemeColors } from '../../../types/ThemeTypes';

@Component
export struct GraphicsAdvancedSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  // 着色器
  @State spirvShaderGen: boolean = true;
  @State disableSpirvOptimizer: boolean = true;
  @State asyncShaderCompilation: boolean = false;
  @State diskShaderCache: boolean = true;
  @State shadersAccurateMul: boolean = false;
  // 画面缩放
  @State filterMode: boolean = true;
  @State useIntegerScaling: boolean = false;
  // 性能底层
  @State delayGameRenderThreadUs: number = 0;
  @State textureSampling: number = 0;
  @State textureFilter: number = 0;
  @State useSkipDuplicateFrames: boolean = false;
  // 画面立体
  @State render3dWhichDisplay: number = 0;
  @State render3d: number = 2;
  @State factor3d: number = 0;
  @State disableRightEyeRender: boolean = false;
  @State swapEyes3d: boolean = false;
  // Cardboard VR
  @State cardboardScreenSize: number = 85;
  @State cardboardXShift: number = 0;
  @State cardboardYShift: number = 0;
  // 工具
  @State dumpTextures: boolean = false;
  @State asyncCustomLoading: boolean = true;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();
  private deviceType: string = 'phone';

  async aboutToAppear(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    await this.soundEffectManager.initialize(this.context);
    this.deviceType = DeviceProfile.getDeviceType();
    this.loadSettings();
  }

  private loadSettings(): void {
    this.spirvShaderGen = this.settingsManager.getBoolean(KEY_SPIRV_SHADER_GEN);
    this.disableSpirvOptimizer = this.settingsManager.getBoolean(KEY_DISABLE_SPIRV_OPTIMIZER);
    this.asyncShaderCompilation = this.settingsManager.getBoolean(KEY_ASYNC_SHADER_COMPILATION);
    this.diskShaderCache = this.settingsManager.getBoolean(KEY_USE_DISK_SHADER_CACHE);
    this.shadersAccurateMul = this.settingsManager.getBoolean(KEY_SHADERS_ACCURATE_MUL);
    this.filterMode = this.settingsManager.getBoolean(KEY_FILTER_MODE);
    this.useIntegerScaling = this.settingsManager.getBoolean(KEY_USE_INTEGER_SCALING);
    this.delayGameRenderThreadUs = this.settingsManager.getNumber(KEY_DELAY_GAME_RENDER_THREAD_US);
    this.textureSampling = this.settingsManager.getNumber(KEY_TEXTURE_SAMPLING);
    this.textureFilter = this.settingsManager.getNumber(KEY_TEXTURE_FILTER);
    this.useSkipDuplicateFrames = this.settingsManager.getBoolean(KEY_USE_SKIP_DUPLICATE_FRAMES);
    this.render3dWhichDisplay = this.settingsManager.getNumber(KEY_RENDER_3D_WHICH_DISPLAY);
    this.render3d = this.settingsManager.getNumber(KEY_RENDER_3D);
    this.factor3d = this.settingsManager.getNumber(KEY_FACTOR_3D);
    this.disableRightEyeRender = this.settingsManager.getBoolean(KEY_DISABLE_RIGHT_EYE_RENDER);
    this.swapEyes3d = this.settingsManager.getBoolean(KEY_SWAP_EYES_3D);
    this.cardboardScreenSize = this.settingsManager.getNumber(KEY_CARDBOARD_SCREEN_SIZE);
    this.cardboardXShift = this.settingsManager.getNumber(KEY_CARDBOARD_X_SHIFT);
    this.cardboardYShift = this.settingsManager.getNumber(KEY_CARDBOARD_Y_SHIFT);
    this.dumpTextures = this.settingsManager.getBoolean(KEY_DUMP_TEXTURES);
    this.asyncCustomLoading = this.settingsManager.getBoolean(KEY_ASYNC_CUSTOM_LOADING);
  }

  private async updateBoolean(key: string, value: boolean): Promise<void> {
    await this.settingsManager.setBoolean(key, value);
    AzaharNative.applyConfig();
  }

  private async updateNumber(key: string, value: number): Promise<void> {
    await this.settingsManager.setNumber(key, value);
    AzaharNative.applyConfig();
  }

  private options(keys: string[]): SettingOption[] {
    return keys.map((key: string, index: number): SettingOption => ({ value: index, label: I18n.t(key) }));
  }

  private valueOptions(values: number[], keys: string[]): SettingOption[] {
    return keys.map((key: string, index: number): SettingOption =>
      ({ value: values[index], label: I18n.t(key) }));
  }

  private indexOfValue(options: SettingOption[], value: number): number {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === value) {
        return i;
      }
    }
    return 0;
  }

  @Builder
  SectionHeader(title: string) {
    SettingsSectionHeader({ title })
  }

  build() {
    SettingsList({ scroller: this.scroller }) {
      // 着色器 —— 对应 Android Graphics > Renderer 中的底层项
      ListItem() {
        this.SectionHeader(I18n.t('graphics_section_shader'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_spirv_shader_gen'),
          description: I18n.t('settings_spirv_shader_gen_desc'),
          isOn: this.spirvShaderGen,
          onToggle: (value: boolean) => {
            this.spirvShaderGen = value;
            this.updateBoolean(KEY_SPIRV_SHADER_GEN, value);
          }
        })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_disable_spirv_optimizer'),
          description: I18n.t('settings_disable_spirv_optimizer_desc'),
          isOn: this.disableSpirvOptimizer,
          onToggle: (value: boolean) => {
            this.disableSpirvOptimizer = value;
            this.updateBoolean(KEY_DISABLE_SPIRV_OPTIMIZER, value);
          }
        })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_async_shader_compilation'),
          description: I18n.t('settings_async_shader_compilation_desc'),
          isOn: this.asyncShaderCompilation,
          onToggle: (value: boolean) => {
            this.asyncShaderCompilation = value;
            this.updateBoolean(KEY_ASYNC_SHADER_COMPILATION, value);
          }
        })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_disk_shader_cache'),
          description: I18n.t('settings_disk_shader_cache_desc'),
          isOn: this.diskShaderCache,
          onToggle: (value: boolean) => {
            this.diskShaderCache = value;
            this.updateBoolean(KEY_USE_DISK_SHADER_CACHE, value);
          }
        })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_accurate_mul'),
          description: I18n.t('settings_accurate_mul_desc'),
          isOn: this.shadersAccurateMul,
          onToggle: (value: boolean) => {
            this.shadersAccurateMul = value;
            this.updateBoolean(KEY_SHADERS_ACCURATE_MUL, value);
          }
        })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 性能底层 —— 对应 Android Graphics > Renderer/Advanced 的其余项
      ListItem() {
        this.SectionHeader(I18n.t('graphics_section_advanced'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_smooth_filtering'),
          description: I18n.t('settings_smooth_filtering_desc'),
          isOn: this.filterMode,
          onToggle: (value: boolean) => {
            this.filterMode = value;
            this.updateBoolean(KEY_FILTER_MODE, value);
          }
        })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_integer_scaling'),
          description: I18n.t('settings_integer_scaling_desc'),
          isOn: this.useIntegerScaling,
          onToggle: (value: boolean) => {
            this.useIntegerScaling = value;
            this.updateBoolean(KEY_USE_INTEGER_SCALING, value);
          }
        })
        }
        ListItem() {
        SliderSettingItem({
          title: I18n.t('settings_render_thread_delay'),
          description: I18n.t('settings_render_thread_delay_desc'),
          value: this.delayGameRenderThreadUs,
          min: 0,
          max: 16000,
          step: 100,
          formatValue: (value: number): string => `${value} μs`,
          onChange: (value: number) => {
            this.delayGameRenderThreadUs = value;
            this.updateNumber(KEY_DELAY_GAME_RENDER_THREAD_US, value);
          }
        })
        }
        ListItem() {
        SelectSettingItem({
          title: I18n.t('settings_texture_sampling'),
          description: I18n.t('settings_texture_sampling_desc'),
          options: this.options(['texture_sampling_game_controlled', 'texture_sampling_nearest', 'texture_sampling_linear']),
          selectedIndex: this.textureSampling,
          onSelect: (_index: number, value: string | number) => {
            this.textureSampling = value as number;
            this.updateNumber(KEY_TEXTURE_SAMPLING, value as number);
          }
        })
        }
        ListItem() {
        SelectSettingItem({
          title: I18n.t('settings_texture_filter'),
          description: I18n.t('settings_texture_filter_desc'),
          options: this.options(['none', 'texture_filter_anime4k', 'texture_filter_bicubic',
            'texture_filter_scaleforce', 'texture_filter_xbrz', 'texture_filter_mmpx']),
          selectedIndex: this.textureFilter,
          onSelect: (_index: number, value: string | number) => {
            this.textureFilter = value as number;
            this.updateNumber(KEY_TEXTURE_FILTER, value as number);
          }
        })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_skip_duplicate_frames'),
          description: I18n.t('settings_skip_duplicate_frames_desc'),
          isOn: this.useSkipDuplicateFrames,
          onToggle: (value: boolean) => {
            this.useSkipDuplicateFrames = value;
            this.updateBoolean(KEY_USE_SKIP_DUPLICATE_FRAMES, value);
          }
        })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 画面立体 —— 对应 Android Graphics > Stereoscopy
      ListItem() {
        this.SectionHeader(I18n.t('graphics_section_stereoscopy'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
        SelectSettingItem({
          title: I18n.t('settings_3d_display_target'),
          description: I18n.t('settings_3d_display_target_desc'),
          options: this.options(['off', 'all_screens', 'main_screen_only', 'secondary_screen_only']),
          selectedIndex: this.render3dWhichDisplay,
          onSelect: (_index: number, value: string | number) => {
            this.render3dWhichDisplay = value as number;
            this.updateNumber(KEY_RENDER_3D_WHICH_DISPLAY, value as number);
          }
        })
        }
        ListItem() {
        SelectSettingItem({
          title: I18n.t('settings_stereo_3d_mode'),
          description: I18n.t('settings_stereo_3d_mode_desc'),
          options: this.valueOptions([1, 2, 3, 4, 5, 6],
            ['render3d_side_by_side_half', 'render3d_side_by_side_full', 'render3d_anaglyph',
              'render3d_interlaced', 'render3d_reverse_interlaced', 'render3d_cardboard_vr']),
          selectedIndex: this.indexOfValue(this.valueOptions([1, 2, 3, 4, 5, 6],
            ['render3d_side_by_side_half', 'render3d_side_by_side_full', 'render3d_anaglyph',
              'render3d_interlaced', 'render3d_reverse_interlaced', 'render3d_cardboard_vr']), this.render3d),
          disabled: this.render3dWhichDisplay === 0,
          onSelect: (_index: number, value: string | number) => {
            this.render3d = value as number;
            this.updateNumber(KEY_RENDER_3D, value as number);
          }
        })
        }
        ListItem() {
        SliderSettingItem({
          title: I18n.t('settings_3d_depth'),
          description: I18n.t('settings_3d_depth_desc'),
          value: this.factor3d,
          min: 0,
          max: 255,
          step: 5,
          formatValue: (value: number): string => `${value}%`,
          onChange: (value: number) => {
            this.factor3d = value;
            this.updateNumber(KEY_FACTOR_3D, value);
          }
        })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_disable_right_eye_render'),
          description: I18n.t('settings_disable_right_eye_render_desc'),
          isOn: this.disableRightEyeRender,
          onToggle: (value: boolean) => {
            this.disableRightEyeRender = value;
            this.updateBoolean(KEY_DISABLE_RIGHT_EYE_RENDER, value);
          }
        })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_swap_eyes'),
          description: I18n.t('settings_swap_eyes_desc'),
          isOn: this.swapEyes3d,
          disabled: this.render3dWhichDisplay === 0,
          onToggle: (value: boolean) => {
            this.swapEyes3d = value;
            this.updateBoolean(KEY_SWAP_EYES_3D, value);
          }
        })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // Cardboard VR —— 对应 Android Graphics > Cardboard VR
      ListItem() {
        this.SectionHeader(I18n.t('graphics_section_cardboard_vr'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
        SliderSettingItem({
          title: I18n.t('settings_cardboard_screen_size'),
          description: I18n.t('settings_cardboard_screen_size_desc'),
          value: this.cardboardScreenSize,
          min: 30,
          max: 100,
          step: 1,
          disabled: this.render3d !== 6,
          formatValue: (value: number): string => `${value}%`,
          onChange: (value: number) => {
            this.cardboardScreenSize = value;
            this.updateNumber(KEY_CARDBOARD_SCREEN_SIZE, value);
          }
        })
        }
        ListItem() {
        SliderSettingItem({
          title: I18n.t('settings_cardboard_x_shift'),
          description: I18n.t('settings_cardboard_x_shift_desc'),
          value: this.cardboardXShift,
          min: -100,
          max: 100,
          step: 1,
          disabled: this.render3d !== 6,
          formatValue: (value: number): string => `${value}%`,
          onChange: (value: number) => {
            this.cardboardXShift = value;
            this.updateNumber(KEY_CARDBOARD_X_SHIFT, value);
          }
        })
        }
        ListItem() {
        SliderSettingItem({
          title: I18n.t('settings_cardboard_y_shift'),
          description: I18n.t('settings_cardboard_y_shift_desc'),
          value: this.cardboardYShift,
          min: -100,
          max: 100,
          step: 1,
          disabled: this.render3d !== 6,
          formatValue: (value: number): string => `${value}%`,
          onChange: (value: number) => {
            this.cardboardYShift = value;
            this.updateNumber(KEY_CARDBOARD_Y_SHIFT, value);
          }
        })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 工具 —— 对应 Android Graphics > Utility
      ListItem() {
        this.SectionHeader(I18n.t('graphics_section_utility'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_dump_textures'),
          description: I18n.t('settings_dump_textures_desc'),
          isOn: this.dumpTextures,
          onToggle: (value: boolean) => {
            this.dumpTextures = value;
            this.updateBoolean(KEY_DUMP_TEXTURES, value);
          }
        })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_async_custom_loading'),
          description: I18n.t('settings_async_custom_loading_desc'),
          isOn: this.asyncCustomLoading,
          onToggle: (value: boolean) => {
            this.asyncCustomLoading = value;
            this.updateBoolean(KEY_ASYNC_CUSTOM_LOADING, value);
          }
        })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())

    }
  }
}

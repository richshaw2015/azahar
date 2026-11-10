import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ButtonSettingItem } from '../ButtonSettingItem';
import { SelectSettingItem } from '../SelectSettingItem';
import { ToggleSettingItem } from '../ToggleSettingItem';
import { SettingsList, SettingsSectionHeader, settingsGroupDivider, menuGroupMargin, menuGroupPadding } from '../SettingsList';
import { KEY_CUSTOM_TEXTURES, KEY_GRAPHICS_API, KEY_IGNORE_SAFE_AREA, KEY_LOCK_GAME_BRIGHTNESS, KEY_PERFORMANCE_OVERLAY_ENABLE, KEY_PERFORMANCE_OVERLAY_POSITION, KEY_PP_SHADER_NAME, KEY_RESOLUTION_FACTOR, KEY_SCREEN_ORIENTATION, KEY_TURBO_LIMIT, KEY_USE_VSYNC, SettingOption } from '../../../types/SettingsTypes';
import { SCREEN_FILTER_NONE_VALUE, screenFilterDisplayName } from '../../../types/ScreenFilterDefs';
import { I18n } from '../../../utils/I18nManager';
import { SettingsManager } from '../../../utils/SettingsManager';
import { AzaharNative } from '../../../types/AzaharNative';
import { SoundEffectManager, SoundEffect } from '../../../utils/SoundEffectManager';
import { showErrorToast } from '../../../utils/ToastHelper';
import { listCardBgOf } from '../../../utils/ThemeSurfaces';
import { ThemeManager, THEME_COLORS_STORAGE_KEY } from '../../../utils/ThemeManager';
import { AzaharThemeColors } from '../../../types/ThemeTypes';

@Component
export struct GraphicsSettingsContent {
  @StorageProp(THEME_COLORS_STORAGE_KEY) themeColors: AzaharThemeColors =
    ThemeManager.getInstance().getCurrentColors();
  scroller?: Scroller;
  @State graphicsApi: number = 2;
  @State resolutionFactor: number = 1;
  // 与滤镜预览页共用 AppStorage key —— 子页选择后返回时本页值即时刷新
  @StorageLink('screen_filter_selection') screenFilter: string = SCREEN_FILTER_NONE_VALUE;
  @State customTextures: boolean = false;
  // 帧率控制：turbo_limit 为百分比（0=无限制）
  @State turboLimit: number = 200;
  @State useVsync: boolean = false;
  // FPS 计数器：0=隐藏，1-6=固定位置（对应 performance_overlay_position 0-5）
  @State performanceOverlaySelection: number = 0;
  @State ignoreSafeArea: boolean = false;
  @State screenOrientation: string = 'auto';
  @State lockGameBrightness: boolean = true;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private settingsManager: SettingsManager = SettingsManager.getInstance();
  private soundEffectManager: SoundEffectManager = SoundEffectManager.getInstance();

  async aboutToAppear(): Promise<void> {
    await this.settingsManager.initialize(this.context);
    await this.soundEffectManager.initialize(this.context);
    this.loadSettings();
  }

  private loadSettings(): void {
    this.graphicsApi = this.settingsManager.getNumber(KEY_GRAPHICS_API);
    // 旧配置可能残留 0（已移除的自动选项）或 5~8，钳到 1~4x
    this.resolutionFactor = Math.min(4, Math.max(1, this.settingsManager.getNumber(KEY_RESOLUTION_FACTOR)));
    // 未写过该 key 时 getString 可能返回空值 —— 归一到 None 保证入口显示一致
    const savedScreenFilter = this.settingsManager.getString(KEY_PP_SHADER_NAME);
    this.screenFilter = (typeof savedScreenFilter === 'string' && savedScreenFilter.length > 0)
      ? savedScreenFilter
      : SCREEN_FILTER_NONE_VALUE;
    this.customTextures = this.settingsManager.getBoolean(KEY_CUSTOM_TEXTURES);
    this.turboLimit = this.settingsManager.getNumber(KEY_TURBO_LIMIT);
    this.useVsync = this.settingsManager.getBoolean(KEY_USE_VSYNC);
    this.performanceOverlaySelection = this.settingsManager.getBoolean(KEY_PERFORMANCE_OVERLAY_ENABLE)
      ? Math.min(6, this.settingsManager.getNumber(KEY_PERFORMANCE_OVERLAY_POSITION) + 1) : 0;
    this.ignoreSafeArea = this.settingsManager.getBoolean(KEY_IGNORE_SAFE_AREA);
    this.screenOrientation = this.settingsManager.getString(KEY_SCREEN_ORIENTATION);
    this.lockGameBrightness = this.settingsManager.getBoolean(KEY_LOCK_GAME_BRIGHTNESS);
  }

  private async updateBoolean(key: string, value: boolean): Promise<void> {
    await this.settingsManager.setBoolean(key, value);
    AzaharNative.applyConfig();
  }

  private async updateNumber(key: string, value: number): Promise<void> {
    await this.settingsManager.setNumber(key, value);
    AzaharNative.applyConfig();
  }

  private navigateToScreenFilter(): void {
    this.soundEffectManager.play(SoundEffect.DECIDE);
    router.pushUrl({
      url: 'pages/settings/ScreenFilterSettings'
    }).catch((err: Error) => {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('open_failed_fmt', 'error', err.message));
    });
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

  // 1~4 倍（4x 已覆盖平板横屏并排 ~2.8K，更高倍率纯超采样、鸿蒙设备性能不划算）
  private resolutionOptions(): SettingOption[] {
    const options: SettingOption[] = [];
    for (let factor = 1; factor <= 4; factor++) {
      const label = factor === 1
        ? I18n.t('internal_resolution_native_fmt')
        : I18n.tf1('internal_resolution_multiple_fmt', 'factor', factor);
      options.push({ value: factor, label: label });
    }
    return options;
  }

  // 与 nds 对齐：无限制/1.5x/2x/3x/4x/8x；值映射 turbo_limit 百分比（0=无限制，原生 GetFrameLimit()==0 语义）
  private fastForwardSpeedOptions(): SettingOption[] {
    return [
      { value: 0, label: I18n.t('opt_unlimited') },
      { value: 150, label: '1.5x' },
      { value: 200, label: '2x' },
      { value: 300, label: '3x' },
      { value: 400, label: '4x' },
      { value: 800, label: '8x' }
    ];
  }

  // 与 nds 对齐：隐藏 + 六个固定位置；内部仍写 performance_overlay_enable/position 双 key
  private fpsCounterOptions(): SettingOption[] {
    return this.options(['opt_hidden', 'opt_top_left', 'opt_top_center', 'opt_top_right',
      'opt_bottom_left', 'opt_bottom_center', 'opt_bottom_right']);
  }

  private screenOrientationOptions(): SettingOption[] {
    return [
      { value: 'auto', label: I18n.t('screen_orientation_auto') },
      { value: 'portrait', label: I18n.t('screen_orientation_portrait') },
      { value: 'landscape', label: I18n.t('screen_orientation_landscape') }
    ];
  }

  private indexOfStringValue(options: SettingOption[], value: string): number {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === value) {
        return i;
      }
    }
    return 0;
  }

  private navigateToAdvanced(): void {
    this.soundEffectManager.play(SoundEffect.DECIDE);
    router.pushUrl({
      url: 'pages/settings/GraphicsAdvancedSettings'
    }).catch((err: Error) => {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('open_failed_fmt', 'error', err.message));
    });
  }

  private navigateToCamera(): void {
    this.soundEffectManager.play(SoundEffect.DECIDE);
    router.pushUrl({
      url: 'pages/settings/CameraSettings'
    }).catch((err: Error) => {
      this.soundEffectManager.play(SoundEffect.FAIL);
      showErrorToast(I18n.tf1('open_failed_fmt', 'error', err.message));
    });
  }

  @Builder
  SectionHeader(title: string) {
    SettingsSectionHeader({ title })
  }

  build() {
    SettingsList({ scroller: this.scroller }) {
      // 渲染器 —— 常用项；着色器/立体/工具等低频项收进「高级选项」子页
      ListItem() {
        this.SectionHeader(I18n.t('graphics_section_renderer'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
        SelectSettingItem({
          title: I18n.t('settings_render_api'),
          options: this.valueOptions([1, 2], ['renderer_opengl_es', 'renderer_vulkan']),
          selectedIndex: this.indexOfValue(this.valueOptions([1, 2], ['renderer_opengl_es', 'renderer_vulkan']), this.graphicsApi),
          onSelect: (_index: number, value: string | number) => {
            this.graphicsApi = value as number;
            this.updateNumber(KEY_GRAPHICS_API, value as number);
          }
        })
        }
        ListItem() {
        SelectSettingItem({
          title: I18n.t('settings_internal_resolution'),
          description: I18n.t('settings_internal_resolution_desc'),
          options: this.resolutionOptions(),
          selectedIndex: this.indexOfValue(this.resolutionOptions(), this.resolutionFactor),
          onSelect: (_index: number, value: string | number) => {
            this.resolutionFactor = value as number;
            this.updateNumber(KEY_RESOLUTION_FACTOR, value as number);
          }
        })
        }
        ListItem() {
        ButtonSettingItem({
          title: I18n.t('settings_screen_filter'),
          description: I18n.t('settings_screen_filter_desc'),
          buttonText: screenFilterDisplayName(this.screenFilter),
          showArrow: true,
          onItemClick: () => {
            this.navigateToScreenFilter();
          }
        })
        }
        ListItem() {
        ToggleSettingItem({
          title: I18n.t('settings_custom_textures'),
          description: I18n.t('settings_custom_textures_desc'),
          isOn: this.customTextures,
          onToggle: (value: boolean) => {
            this.customTextures = value;
            this.updateBoolean(KEY_CUSTOM_TEXTURES, value);
          }
        })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 帧率控制
      ListItem() {
        this.SectionHeader(I18n.t('section_framerate_control'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          SelectSettingItem({
            title: I18n.t('fast_forward_speed'),
            description: I18n.t('fast_forward_speed_desc'),
            options: this.fastForwardSpeedOptions(),
            selectedIndex: this.indexOfValue(this.fastForwardSpeedOptions(), this.turboLimit),
            onSelect: (_index: number, value: string | number) => {
              this.turboLimit = value as number;
              this.updateNumber(KEY_TURBO_LIMIT, value as number);
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_vsync'),
            description: I18n.t('settings_vsync_desc'),
            isOn: this.useVsync,
            requiresRestart: true,
            onToggle: (value: boolean) => {
              this.useVsync = value;
              this.updateBoolean(KEY_USE_VSYNC, value);
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 显示
      ListItem() {
        this.SectionHeader(I18n.t('graphics_section_display'))
      }
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_ignore_safe_area'),
            description: I18n.t('settings_ignore_safe_area_desc'),
            isOn: this.ignoreSafeArea,
            onToggle: (value: boolean) => {
              this.ignoreSafeArea = value;
              this.updateBoolean(KEY_IGNORE_SAFE_AREA, value);
            }
          })
        }
        ListItem() {
          SelectSettingItem({
            title: I18n.t('settings_screen_orientation'),
            description: I18n.t('settings_screen_orientation_desc'),
            options: this.screenOrientationOptions(),
            selectedIndex: this.indexOfStringValue(this.screenOrientationOptions(), this.screenOrientation),
            onSelect: (_index: number, value: string | number) => {
              this.screenOrientation = value as string;
              this.settingsManager.setString(KEY_SCREEN_ORIENTATION, value as string);
            }
          })
        }
        ListItem() {
          SelectSettingItem({
            title: I18n.t('fps_counter'),
            options: this.fpsCounterOptions(),
            selectedIndex: this.performanceOverlaySelection,
            onSelect: (_index: number, value: string | number) => {
              const selection = value as number;
              this.performanceOverlaySelection = selection;
              this.updateBoolean(KEY_PERFORMANCE_OVERLAY_ENABLE, selection > 0);
              if (selection > 0) {
                this.updateNumber(KEY_PERFORMANCE_OVERLAY_POSITION, selection - 1);
              }
            }
          })
        }
        ListItem() {
          ToggleSettingItem({
            title: I18n.t('settings_lock_brightness'),
            description: I18n.t('settings_lock_brightness_desc'),
            isOn: this.lockGameBrightness,
            onToggle: (value: boolean) => {
              this.lockGameBrightness = value;
              this.updateBoolean(KEY_LOCK_GAME_BRIGHTNESS, value);
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 高级选项入口 —— 着色器/立体显示/Cardboard VR/纹理工具等低频项
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ButtonSettingItem({
            title: I18n.t('graphics_section_advanced'),
            description: I18n.t('settings_graphics_advanced_desc'),
            showArrow: true,
            onItemClick: () => {
              this.navigateToAdvanced();
            }
          })
        }
      }
      .padding(menuGroupPadding())
      .backgroundColor(listCardBgOf(this.themeColors))
      .divider(settingsGroupDivider())
      .margin(menuGroupMargin())

      // 相机设置入口 —— 低频项，收在图形页底部（对齐 nds 的 DSi 相机归类）
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() {
          ButtonSettingItem({
            title: I18n.t('settings_camera'),
            description: I18n.t('settings_camera_desc'),
            showArrow: true,
            onItemClick: () => {
              this.navigateToCamera();
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
